import Foundation

/// Thread-safe bridge from the background job to its @MainActor model.
/// Progress is throttled so a fast download cannot flood the main thread.
final class JobReporter: @unchecked Sendable {

    struct Progress: Sendable {
        var phase: String
        var fraction: Double?        // nil while indeterminate
        var detail: String
        var step: Int
        var steps: Int
    }

    enum Event: Sendable {
        case progress(Progress)
        case log(String)
        case title(String)
    }

    private let lock = NSLock()
    private var lastPost = Date.distantPast
    private var lastPhase = ""
    private let sink: @Sendable (Event) -> Void

    init(sink: @escaping @Sendable (Event) -> Void) {
        self.sink = sink
    }

    func log(_ line: String) {
        sink(.log(line))
    }

    func title(_ title: String) {
        sink(.title(title))
    }

    func progress(_ progress: Progress, force: Bool = false) {
        lock.lock()
        let now = Date()
        let changedPhase = progress.phase != lastPhase
        let due = force || changedPhase || now.timeIntervalSince(lastPost) >= 0.2
        if due {
            lastPost = now
            lastPhase = progress.phase
        }
        lock.unlock()
        if due { sink(.progress(progress)) }
    }
}

/// The actual work of one download, run on a background queue.
///
/// 1. yt-dlp downloads the chosen streams into a private scratch folder.
/// 2. ffprobe reports what actually arrived.
/// 3. ffmpeg copies or converts it into a temporary file.
/// 4. Only a finished file is moved into the destination folder, so a
///    cancelled or failed job never leaves a broken video behind.
final class JobPipeline {

    private(set) var request: JobRequest
    let runner: ProcessRunner
    let reporter: JobReporter
    let profile: SystemProfile = .current

    init(request: JobRequest, runner: ProcessRunner, reporter: JobReporter) {
        self.request = request
        self.runner = runner
        self.reporter = reporter
    }

    private var steps: Int { 2 }

    func run() throws -> URL {
        let tools = try ToolLocator.resolve()
        let fm = FileManager.default

        try fm.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)

        // A scratch folder on the same volume as the destination (so the
        // final move is a rename), outside anything the user can see or that
        // iCloud would try to sync.
        let scratch: URL
        if let replacement = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                         appropriateFor: request.outputDirectory, create: true) {
            scratch = replacement
        } else {
            scratch = fm.temporaryDirectory.appendingPathComponent("YTGrab-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: scratch) }

        try checkFreeSpace(at: scratch)

        let source = try download(tools: tools, into: scratch)
        adoptDownloadedInfo(in: scratch)
        let streams = try probe(tools.ffprobe, source)

        var summary = streams.hasVideo ? "Got \(streams.height)p \(streams.videoCodec)" : "Got audio"
        if streams.fps > 0 { summary += " at \(streams.fps)fps" }
        if streams.isHDR { summary += ", HDR" }
        summary += streams.hasAudio ? ", audio \(streams.audioCodec)" : ", no audio"
        reporter.log(summary)

        let staged = scratch.appendingPathComponent("output").appendingPathExtension(request.format.fileExtension)
        try convert(source: source, to: staged, streams: streams, tools: tools)

        let destination = CommandBuilder.uniqueURL(
            directory: request.outputDirectory,
            stem: CommandBuilder.outputName(request: request, height: streams.height),
            ext: request.format.fileExtension
        )
        try fm.moveItem(at: staged, to: destination)

        let bytes = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        reporter.log("Saved \(destination.lastPathComponent) (\(Format.bytes(bytes)))")
        return destination
    }

    // MARK: - Space

    private func checkFreeSpace(at url: URL) throws {
        guard let expected = expectedBytes() else { return }
        // Source plus output, with a margin for the conversion.
        let needed = Int64(Double(expected) * (request.format == .original ? 2.1 : 2.4))
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage, available > 0 else { return }
        if available < needed {
            throw JobError.notEnoughSpace(needed: needed, available: available)
        }
    }

    private func expectedBytes() -> Int64? {
        guard let option = request.option, let bytes = option.approxBytes else { return nil }
        return bytes
    }

    // MARK: - Download

    private func download(tools: ToolLocator.Toolchain, into scratch: URL) throws -> URL {
        let template = scratch.appendingPathComponent("source.%(ext)s").path

        // A fresh probe already solved YouTube's challenges; reusing it saves
        // the whole extraction round trip. Stream URLs expire after a few
        // hours, so an old probe is not reused.
        let infoIsFresh = request.infoJSON.map { FileManager.default.fileExists(atPath: $0.path) } == true
            && Date().timeIntervalSince(request.infoFetchedAt ?? .distantPast) < 2 * 3600

        struct Attempt { var useInfo: Bool; var selector: String? }
        var attempts: [Attempt] = []
        if infoIsFresh { attempts.append(Attempt(useInfo: true, selector: nil)) }
        attempts.append(Attempt(useInfo: false, selector: nil))
        if !request.format.isAudioOnly {
            attempts.append(Attempt(useInfo: false, selector: request.height > 0 ? "bv*[height<=\(request.height)]+ba/b" : "bv*+ba/b"))
        }

        var lastError: Error?
        for (index, attempt) in attempts.enumerated() {
            if index > 0 {
                reporter.log("Retrying with a fresh request …")
                clearPartials(in: scratch)
            }
            let parser = DownloadProgressParser(reporter: reporter, steps: steps, isAudioOnly: request.format.isAudioOnly)
            parser.begin()
            let args = CommandBuilder.downloadArguments(
                request: request, tools: tools, profile: profile,
                template: template, useInfoJSON: attempt.useInfo, selector: attempt.selector
            )
            var collected: [String] = []
            do {
                try runner.stream(tools.ytdlp, args, tag: "yt-dlp") { line in
                    if parser.consume(line) { return }
                    collected.append(line)
                    reporter.log(line)
                }
                guard let file = downloadedFile(in: scratch) else { throw JobError.noOutputFile }
                return file
            } catch JobError.cancelled {
                throw JobError.cancelled
            } catch {
                lastError = error
                let advice = FailureAdvice.explain(error, log: collected)
                if advice.isPermanent || advice.action == .openYouTubeSettings { throw error }
            }
        }
        throw lastError ?? JobError.noOutputFile
    }

    /// Links added without a preview have no title yet; yt-dlp wrote its
    /// metadata next to the download, so take the title from there.
    private func adoptDownloadedInfo(in scratch: URL) {
        guard request.title.isEmpty else { return }
        let file = scratch.appendingPathComponent("source.info.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            request.title = "video"
            return
        }
        request.title = root["title"] as? String ?? "video"
        request.uploader = (root["uploader"] as? String) ?? (root["channel"] as? String)
        if request.duration == nil { request.duration = (root["duration"] as? NSNumber)?.intValue }
        reporter.title(request.title)
    }

    private func downloadedFile(in scratch: URL) -> URL? {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: scratch.path)) ?? []
        let ignored = [".part", ".ytdl", ".json", ".temp", ".tmp"]
        let candidates = names
            .filter { $0.hasPrefix("source.") && !ignored.contains(where: $0.hasSuffix) && !$0.contains(".part-") }
            .map { scratch.appendingPathComponent($0) }
        // After a merge only the merged file remains; otherwise take the
        // largest finished file.
        return candidates.max { lhs, rhs in
            let a = (try? fm.attributesOfItem(atPath: lhs.path)[.size] as? NSNumber)?.int64Value ?? 0
            let b = (try? fm.attributesOfItem(atPath: rhs.path)[.size] as? NSNumber)?.int64Value ?? 0
            return a < b
        }
    }

    private func clearPartials(in scratch: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: scratch.path)) ?? [] where name.hasPrefix("source.") {
            try? fm.removeItem(at: scratch.appendingPathComponent(name))
        }
    }

    // MARK: - Probe

    private func probe(_ ffprobe: URL, _ file: URL) throws -> MediaStreams {
        let json = try runner.capture(
            ffprobe,
            ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", file.path],
            tag: "ffprobe",
            timeout: 120
        )

        var result = MediaStreams()
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return result
        }

        if let format = root["format"] as? [String: Any],
           let duration = Double(format["duration"] as? String ?? "") {
            result.duration = duration
        }

        for stream in root["streams"] as? [[String: Any]] ?? [] {
            let type = stream["codec_type"] as? String
            let disposition = stream["disposition"] as? [String: Any]
            let isCoverArt = (disposition?["attached_pic"] as? Int) == 1
            if type == "video", !isCoverArt, !result.hasVideo {
                result.videoCodec = stream["codec_name"] as? String ?? "unknown"
                result.height = stream["height"] as? Int ?? 0
                result.fps = Self.parseRate(stream["avg_frame_rate"] as? String)
                if result.fps == 0 { result.fps = Self.parseRate(stream["r_frame_rate"] as? String) }
                result.pixelFormat = stream["pix_fmt"] as? String ?? ""
                result.colorPrimaries = stream["color_primaries"] as? String
                result.colorTransfer = stream["color_transfer"] as? String
                result.colorSpace = stream["color_space"] as? String
                result.colorRange = stream["color_range"] as? String
            } else if type == "audio", !result.hasAudio {
                result.audioCodec = stream["codec_name"] as? String ?? "unknown"
                result.audioChannels = stream["channels"] as? Int ?? 2
            }
        }
        if result.duration == 0, let seconds = request.duration { result.duration = Double(seconds) }
        return result
    }

    /// ffprobe reports frame rate as a fraction such as 30000/1001.
    private static func parseRate(_ raw: String?) -> Int {
        guard let raw else { return 0 }
        let parts = raw.split(separator: "/")
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              denominator > 0 else { return 0 }
        return Int((numerator / denominator).rounded())
    }

    // MARK: - Convert

    private func convert(source: URL, to staged: URL, streams: MediaStreams, tools: ToolLocator.Toolchain) throws {
        if request.format.isAudioOnly {
            guard streams.hasAudio else { throw JobError.badURL("This video has no audio track.") }
            let args = CommandBuilder.audioOnlyArguments(source: source, destination: staged, streams: streams, request: request)
            try runFFmpeg(tools.ffmpeg, args, phase: "Saving audio", streams: streams)
            return
        }

        guard streams.hasVideo else { throw JobError.badURL("YouTube returned no video stream for this link.") }

        // Copy whenever the stream already is what was asked for: H.264 for
        // edit-ready, HEVC for compact, anything for original.
        let codec = request.format.targetCodec
        let alreadyThere: Bool = {
            guard let codec else { return true }
            if streams.videoCodec != codec.ffmpegName { return false }
            if codec == .h264 { return !streams.isTenBit }
            return true
        }()

        if alreadyThere {
            if request.format == .original && !["h264", "hevc"].contains(streams.videoCodec) {
                reporter.log("Heads up: \(streams.videoCodec.uppercased()) is copied as-is. Premiere and Final Cut may not open it; choose Edit-ready MP4 for editing.")
            }
            let args = CommandBuilder.copyArguments(source: source, destination: staged, streams: streams, request: request)
            try runFFmpeg(tools.ffmpeg, args, phase: "Saving (no re-encode)", streams: streams)
            return
        }

        guard let codec else { return }
        let attempts = CommandBuilder.encodeAttempts(codec: codec, request: request, streams: streams, profile: profile)
        var lastError: Error?
        for (index, attempt) in attempts.enumerated() {
            if index > 0 { reporter.log("Retrying with the \(attempt.label) …") }
            let args = CommandBuilder.encodeArguments(
                source: source, destination: staged, codec: codec, attempt: attempt,
                request: request, streams: streams, profile: profile
            )
            do {
                try runFFmpeg(tools.ffmpeg, args, phase: "Converting to \(codec.displayName)", streams: streams, engineLabel: attempt.label)
                return
            } catch JobError.cancelled {
                throw JobError.cancelled
            } catch {
                lastError = error
                reporter.log("The \(attempt.label) failed: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: staged)
            }
        }
        throw lastError ?? JobError.noOutputFile
    }

    private func runFFmpeg(_ ffmpeg: URL, _ args: [String], phase: String, streams: MediaStreams, engineLabel: String? = nil) throws {
        let label = engineLabel.map { "\(phase) · \($0)" } ?? phase
        reporter.log(label + " …")
        let parser = FFmpegProgressParser(reporter: reporter, phase: phase, duration: streams.duration, step: steps, steps: steps)
        parser.begin()
        try runner.stream(ffmpeg, args, tag: "ffmpeg") { line in
            if parser.consume(line) { return }
            reporter.log(line)
        }
    }
}

// MARK: - Progress parsing

/// Reads yt-dlp's `--progress-template` lines.
final class DownloadProgressParser {
    private let reporter: JobReporter
    private let steps: Int
    private let isAudioOnly: Bool
    private var partIndex = 0
    private var lastStatus = ""
    private var lastKind = ""

    init(reporter: JobReporter, steps: Int, isAudioOnly: Bool) {
        self.reporter = reporter
        self.steps = steps
        self.isAudioOnly = isAudioOnly
    }

    func begin() {
        reporter.progress(.init(phase: "Starting download", fraction: nil, detail: "Contacting YouTube …", step: 1, steps: steps), force: true)
    }

    /// Returns true when the line was progress and should not be logged.
    func consume(_ line: String) -> Bool {
        if line.hasPrefix("[Merger]") || line.hasPrefix("[VideoConvertor]") || line.hasPrefix("[FixupM3u8]") {
            reporter.progress(.init(phase: "Merging video and audio", fraction: nil, detail: "", step: 1, steps: steps), force: true)
            return false
        }
        guard line.hasPrefix(CommandBuilder.progressMarker) else { return false }

        let fields = line.dropFirst(CommandBuilder.progressMarker.count)
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: "|")
        guard fields.count >= 7 else { return true }

        func number(_ value: String) -> Double? {
            value == "NA" || value == "None" ? nil : Double(value)
        }

        let status = fields[0]
        let downloaded = number(fields[1]) ?? 0
        let total = number(fields[2]) ?? number(fields[3])
        let speed = number(fields[4])
        let eta = number(fields[5])
        let kind = isAudioOnly || fields[6] == "none" ? "audio" : "video"

        if kind != lastKind || (lastStatus == "finished" && status == "downloading") {
            partIndex += 1
            lastKind = kind
        }
        lastStatus = status

        var detailParts: [String] = []
        if let total, total > 0 {
            detailParts.append("\(Format.bytes(Int64(downloaded))) of \(Format.bytes(Int64(total)))")
        }
        if let speed, speed > 0 { detailParts.append(Format.speed(speed)) }
        if let eta, status == "downloading" { detailParts.append(Format.eta(eta)) }

        let phase = partIndex > 1 ? "Downloading \(kind) (part \(partIndex))" : "Downloading \(kind)"
        let fraction = total.map { $0 > 0 ? min(downloaded / $0, 1) : 0 }
        reporter.progress(.init(phase: phase, fraction: fraction, detail: detailParts.joined(separator: " · "), step: 1, steps: steps),
                          force: status == "finished")
        return true
    }
}

/// Reads ffmpeg's `-progress pipe:1` key=value output.
final class FFmpegProgressParser {
    private let reporter: JobReporter
    private let phase: String
    private let duration: Double
    private let step: Int
    private let steps: Int
    private var speed = ""
    private let started = Date()

    init(reporter: JobReporter, phase: String, duration: Double, step: Int, steps: Int) {
        self.reporter = reporter
        self.phase = phase
        self.duration = duration
        self.step = step
        self.steps = steps
    }

    func begin() {
        reporter.progress(.init(phase: phase, fraction: duration > 0 ? 0 : nil, detail: "", step: step, steps: steps), force: true)
    }

    func consume(_ line: String) -> Bool {
        guard let equals = line.firstIndex(of: "=") else { return false }
        let key = String(line[..<equals])
        // Progress keys are plain identifiers; ffmpeg's own messages start
        // with "[" or contain spaces before any "=".
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)

        switch key {
        case "speed":
            speed = value == "N/A" ? "" : value
        case "out_time_us", "out_time_ms":
            guard duration > 0, let micros = Double(value), micros >= 0 else { return true }
            let done = micros / 1_000_000
            let fraction = min(done / duration, 1)
            var detail: [String] = []
            if !speed.isEmpty { detail.append("\(speed) realtime") }
            let elapsed = Date().timeIntervalSince(started)
            if fraction > 0.02 {
                detail.append(Format.eta(elapsed / fraction - elapsed))
            }
            reporter.progress(.init(phase: phase, fraction: fraction, detail: detail.joined(separator: " · "), step: step, steps: steps))
        case "progress":
            if value == "end" {
                reporter.progress(.init(phase: phase, fraction: 1, detail: "Finishing …", step: step, steps: steps), force: true)
            }
        case "frame", "fps", "bitrate", "total_size", "out_time", "dup_frames", "drop_frames", "stream_0_0_q", "stream_0_1_q":
            break
        default:
            // Any other key=value line from -progress is still progress.
            if key.hasPrefix("stream_") || key.hasPrefix("out_") { break }
            return false
        }
        return true
    }
}
