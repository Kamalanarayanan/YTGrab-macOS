import Foundation
import Combine

@MainActor
final class DownloadEngine: ObservableObject {

    @Published var logLines: [String] = []
    @Published var progress: Double = 0
    @Published var isBusy = false
    @Published var isProbing = false
    @Published var info: VideoInfo?
    @Published var statusText = "Paste a link and press Check."
    @Published var lastOutputFile: URL?

    var options: [FormatOption] { info?.options ?? [] }
    var videoTitle: String { info?.title ?? "video" }

    private var runner: ProcessRunner?
    private let work = DispatchQueue(label: "studio.crit.ytgrab.job", qos: .userInitiated)

    // MARK: - Log

    private func log(_ text: String) {
        // Progress lines overwrite the previous one instead of piling up.
        let isProgress = text.hasPrefix("frame=") || text.contains("[download]")
        if isProgress, let last = logLines.last,
           last.hasPrefix("frame=") || last.contains("[download]") {
            logLines[logLines.count - 1] = text
        } else {
            logLines.append(text)
        }
        if logLines.count > 400 {
            logLines.removeFirst(logLines.count - 400)
        }
        updateProgress(from: text)
    }

    private func updateProgress(from line: String) {
        guard let range = line.range(of: #"\[download\]\s+([0-9.]+)%"#, options: .regularExpression)
        else { return }
        let digits = line[range].filter { $0.isNumber || $0 == "." }
        if let value = Double(digits) { progress = value }
    }

    private nonisolated func post(_ text: String) {
        Task { @MainActor in self.log(text) }
    }

    // MARK: - Probe

    /// Asks yt-dlp what this particular video actually has, rather than
    /// assuming a fixed ladder. Every rung comes back with its codec, frame
    /// rate, HDR flag and approximate size.
    func check(url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isProbing = true
        info = nil
        logLines.removeAll()
        statusText = "Reading available formats ..."
        log("Reading available formats ...")

        work.async { [weak self] in
            guard let self else { return }
            do {
                let tools = try ToolLocator.resolve()
                let runner = ProcessRunner()
                let json = try runner.capture(
                    tools.ytdlp,
                    CommandBuilder.probeArguments(url: trimmed, deno: tools.deno),
                    tag: "yt-dlp"
                )
                let parsed = try Self.parseVideoInfo(json)

                Task { @MainActor in
                    self.info = parsed
                    self.isProbing = false
                    self.statusText = parsed.title
                    self.describe(parsed)
                }
            } catch {
                Task { @MainActor in
                    self.isProbing = false
                    self.statusText = "Could not read that link."
                    self.log("Error: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Says out loud what was found, including the part that trips people up:
    /// above 1080p YouTube only serves VP9 or AV1, so there is no H.264 stream
    /// to copy and a 4K grab always means transcoding.
    private func describe(_ info: VideoInfo) {
        guard let best = info.best else {
            log("No video streams found for that link.")
            return
        }

        var headline = "Detected \(best.resolutionLabel)"
        if let tier = best.tierLabel { headline += " (\(tier))" }
        headline += " \(best.codecLabel)"
        if let fps = best.fps { headline += " at \(fps)fps" }
        if best.isHDR { headline += ", HDR" }
        if let duration = info.durationLabel { headline += ", \(duration) long" }
        log(headline)

        let ladder = info.options.map(\.resolutionLabel).joined(separator: ", ")
        log("Available: \(ladder)")

        if info.maxAVCHeight == 0 {
            log("No H.264 stream on this one, so Keep original would leave VP9 or AV1 inside an MP4.")
        } else if info.maxAVCHeight < info.maxHeight {
            log("H.264 stops at \(info.maxAVCHeight)p. Anything above that has to be transcoded.")
        } else {
            log("H.264 goes all the way to \(info.maxAVCHeight)p, so a lossless copy is possible.")
        }
    }

    private nonisolated static func parseVideoInfo(_ json: String) throws -> VideoInfo {
        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JobError.badURL("yt-dlp could not read that URL.")
        }

        let title = root["title"] as? String ?? "video"
        let uploader = root["uploader"] as? String
        let duration = (root["duration"] as? NSNumber)?.intValue

        // Collect every video-bearing format, then fold them down to one entry
        // per height keeping the most useful facts from each.
        var byHeight: [Int: FormatOption] = [:]

        for format in (root["formats"] as? [[String: Any]] ?? []) {
            guard let height = format["height"] as? Int, height > 0 else { continue }
            let vcodec = (format["vcodec"] as? String ?? "none").lowercased()
            guard vcodec != "none", !vcodec.isEmpty else { continue }

            let fps = (format["fps"] as? NSNumber)?.intValue
            let isAVC = vcodec.hasPrefix("avc1") || vcodec.hasPrefix("h264")

            let dynamicRange = (format["dynamic_range"] as? String ?? "").uppercased()
            let isHDR = dynamicRange.contains("HDR")

            let bytes = (format["filesize"] as? NSNumber)?.int64Value
                ?? (format["filesize_approx"] as? NSNumber)?.int64Value

            var entry = byHeight[height] ?? FormatOption(
                height: height,
                fps: fps,
                bestCodec: vcodec,
                hasAVC: false,
                isHDR: false,
                approxBytes: nil
            )

            entry.hasAVC = entry.hasAVC || isAVC
            entry.isHDR = entry.isHDR || isHDR
            entry.fps = max(entry.fps ?? 0, fps ?? 0) == 0 ? nil : max(entry.fps ?? 0, fps ?? 0)

            // Prefer reporting H.264 at a height when it exists, since that is
            // the stream a copy would actually take.
            if isAVC || entry.bestCodec.isEmpty {
                entry.bestCodec = vcodec
            }

            // Keep the largest size seen, which is the closest thing to what a
            // best-quality pull will actually download.
            if let bytes, bytes > (entry.approxBytes ?? 0) {
                entry.approxBytes = bytes
            }

            byHeight[height] = entry
        }

        let sorted = byHeight.values.sorted { $0.height > $1.height }
        return VideoInfo(title: title, uploader: uploader, duration: duration, options: sorted)
    }

    // MARK: - Run

    func start(options: JobOptions) {
        isBusy = true
        progress = 0
        lastOutputFile = nil
        logLines.removeAll()

        let runner = ProcessRunner()
        self.runner = runner

        work.async { [weak self] in
            guard let self else { return }
            var scratch: URL?
            do {
                let result = try self.execute(options: options, runner: runner, scratch: &scratch)
                Task { @MainActor in
                    self.lastOutputFile = result
                    self.isBusy = false
                }
            } catch {
                Task { @MainActor in
                    self.log(error.localizedDescription)
                    self.isBusy = false
                    self.progress = 0
                }
            }
            if let scratch {
                try? FileManager.default.removeItem(at: scratch)
            }
        }
    }

    func cancel() {
        runner?.cancel()
    }

    // MARK: - The actual job

    private nonisolated func execute(
        options: JobOptions,
        runner: ProcessRunner,
        scratch: inout URL?
    ) throws -> URL {

        let tools = try ToolLocator.resolve()
        let fm = FileManager.default

        // Hidden scratch folder inside the output directory, so the temp file
        // lands on the same volume and the final write stays local.
        let temp = options.outputDirectory.appendingPathComponent(".ytgrab_tmp")
        try? fm.createDirectory(at: temp, withIntermediateDirectories: true)
        scratch = temp

        let label = options.height == 0 ? "best available" : "\(options.height)p"
        post("Fetching \(label) ...")

        let template = temp.appendingPathComponent("source.%(ext)s").path
        try runner.stream(
            tools.ytdlp,
            CommandBuilder.downloadArguments(options: options, template: template, deno: tools.deno),
            tag: "yt-dlp",
            onLine: { [weak self] in self?.post($0) }
        )

        let contents = (try? fm.contentsOfDirectory(atPath: temp.path)) ?? []
        guard let name = contents.first(where: { $0.hasPrefix("source.") }) else {
            throw JobError.noOutputFile
        }
        let source = temp.appendingPathComponent(name)

        let streams = try probeFile(tools.ffprobe, source, runner: runner)
        var got = "Got \(streams.height)p \(streams.videoCodec)"
        if streams.fps > 0 { got += " at \(streams.fps)fps" }
        got += ", audio \(streams.audioCodec.isEmpty ? "none" : streams.audioCodec)"
        post(got)

        let destination = CommandBuilder.outputURL(
            directory: options.outputDirectory,
            title: options.title,
            height: streams.height,
            codec: options.codec
        )

        if options.codec == .remux {
            if streams.videoCodec != "h264" && streams.videoCodec != "hevc" {
                post("Heads up: \(streams.videoCodec) is being copied into MP4 as-is. Premiere and QuickTime may refuse it. Pick H.264 or H.265 if you need to edit.")
            }
            post("Remuxing, no re-encode ...")
            try runner.stream(
                tools.ffmpeg,
                CommandBuilder.remuxArguments(source: source, destination: destination, streams: streams),
                tag: "ffmpeg",
                onLine: { [weak self] in self?.post($0) }
            )
        } else {
            let engineName = options.engine == .hardware ? "media engine" : "software, slower but tighter"
            let codecName = options.codec == .hevc ? "H.265" : "H.264"
            post("Encoding to \(codecName) via \(engineName) ...")

            let arguments = CommandBuilder.encodeArguments(
                source: source, destination: destination, options: options, streams: streams
            )
            do {
                try runner.stream(tools.ffmpeg, arguments, tag: "ffmpeg",
                                  onLine: { [weak self] in self?.post($0) })
            } catch JobError.cancelled {
                throw JobError.cancelled
            } catch {
                guard options.engine == .hardware, arguments.contains("-q:v") else { throw error }
                post("Constant-quality mode refused, falling back to bitrate mode ...")
                let fallback = CommandBuilder.bitrateFallback(
                    from: arguments, options: options, streams: streams
                )
                try runner.stream(tools.ffmpeg, fallback, tag: "ffmpeg",
                                  onLine: { [weak self] in self?.post($0) })
            }
        }

        let attributes = try? fm.attributesOfItem(atPath: destination.path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let megabytes = Double(bytes) / 1_048_576
        post(String(format: "Done. %@  (%.0f MB)", destination.lastPathComponent, megabytes))
        return destination
    }

    private nonisolated func probeFile(
        _ ffprobe: URL, _ file: URL, runner: ProcessRunner
    ) throws -> MediaStreams {
        let json = try runner.capture(
            ffprobe,
            ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", file.path],
            tag: "ffprobe"
        )

        var result = MediaStreams()
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]] else {
            return result
        }

        for stream in streams {
            let type = stream["codec_type"] as? String
            if type == "video", result.height == 0 {
                result.videoCodec = stream["codec_name"] as? String ?? "?"
                result.height = stream["height"] as? Int ?? 0
                result.fps = Self.parseRate(stream["r_frame_rate"] as? String)
                result.colorPrimaries = stream["color_primaries"] as? String
                result.colorTransfer = stream["color_transfer"] as? String
                result.colorSpace = stream["color_space"] as? String
                result.colorRange = stream["color_range"] as? String
            } else if type == "audio", result.audioCodec.isEmpty {
                result.audioCodec = stream["codec_name"] as? String ?? ""
                result.audioChannels = stream["channels"] as? Int ?? 2
            }
        }
        return result
    }

    /// ffprobe reports frame rate as a fraction such as 30000/1001.
    private nonisolated static func parseRate(_ raw: String?) -> Int {
        guard let raw else { return 0 }
        let parts = raw.split(separator: "/")
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              denominator > 0 else { return 0 }
        return Int((numerator / denominator).rounded())
    }
}
