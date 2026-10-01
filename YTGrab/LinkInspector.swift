import Foundation

/// Finds video links in whatever the user pasted or dropped.
enum LinkParser {

    /// Every http(s) link in the text, with a scheme added to bare
    /// "youtu.be/…" or "youtube.com/…" links.
    static func urls(in text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines)
            .compactMap(normalize)
            .reduce(into: [String]()) { result, url in
                if !result.contains(url) { result.append(url) }
            }
    }

    static func normalize(_ raw: String) -> String? {
        var candidate = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"'<>()[]"))
        guard !candidate.isEmpty else { return nil }

        let lower = candidate.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            let knownHosts = ["youtube.com", "youtu.be", "www.youtube.com", "m.youtube.com", "music.youtube.com"]
            guard knownHosts.contains(where: { lower.hasPrefix($0) }) else { return nil }
            candidate = "https://" + candidate
        }

        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, host.contains(".") else { return nil }
        return candidate
    }

    static func isYouTube(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host == "youtu.be" || host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com")
    }

    /// Cheap check used to word the loading state; the probe decides for real.
    static func looksLikePlaylist(_ url: String) -> Bool {
        guard let components = URLComponents(string: url) else { return false }
        let hasList = components.queryItems?.contains { $0.name == "list" } ?? false
        let hasVideo = components.queryItems?.contains { $0.name == "v" } ?? false
        return (hasList && !hasVideo) || components.path.hasPrefix("/playlist")
    }
}

/// Reads what a link actually offers before anything is downloaded.
@MainActor
final class LinkInspector: ObservableObject {

    enum State {
        case idle
        case probing(String)
        case video(VideoInfo)
        case playlist(PlaylistInfo, url: String)
        case failed(FailureAdvice, url: String)
    }

    @Published private(set) var state: State = .idle

    private var runner: ProcessRunner?
    private var generation = 0

    var video: VideoInfo? {
        if case .video(let info) = state { return info }
        return nil
    }

    var isProbing: Bool {
        if case .probing = state { return true }
        return false
    }

    var currentURL: String? {
        switch state {
        case .idle:                    return nil
        case .probing(let url):        return url
        case .video(let info):         return info.webpageURL
        case .playlist(_, let url):    return url
        case .failed(_, let url):      return url
        }
    }

    func reset() {
        runner?.cancel()
        runner = nil
        generation += 1
        state = .idle
    }

    func inspect(_ url: String) {
        runner?.cancel()
        generation += 1
        let token = generation
        let runner = ProcessRunner()
        self.runner = runner
        state = .probing(url)

        let cookies = AppSettings.cookies
        let forceIPv4 = AppSettings.forceIPv4

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<State, Error> = Result {
                let tools = try ToolLocator.resolve()
                let json = try runner.capture(
                    tools.ytdlp,
                    CommandBuilder.probeArguments(url: url, tools: tools, cookies: cookies, forceIPv4: forceIPv4),
                    tag: "yt-dlp",
                    timeout: 120
                )
                return try Self.parse(json, url: url)
            }

            DispatchQueue.main.async {
                guard token == self.generation else { return }
                self.runner = nil
                switch outcome {
                case .success(let state):
                    self.state = state
                case .failure(JobError.cancelled):
                    self.state = .idle
                case .failure(let error):
                    self.state = .failed(FailureAdvice.explain(error), url: url)
                }
            }
        }
    }

    // MARK: - Parsing yt-dlp's JSON

    nonisolated static func parse(_ json: String, url: String) throws -> State {
        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JobError.badURL("YouTube returned nothing readable for that link.")
        }

        if (root["_type"] as? String) == "playlist" {
            return .playlist(parsePlaylist(root), url: url)
        }

        // Keep the dump so the download can skip a second extraction.
        let probes = ToolLocator.cacheDirectory.appendingPathComponent("probes", isDirectory: true)
        try? FileManager.default.createDirectory(at: probes, withIntermediateDirectories: true)
        let file = probes.appendingPathComponent("\(UUID().uuidString).json")
        let saved = (try? data.write(to: file)) != nil

        var info = parseVideo(root, url: url)
        info.infoJSON = saved ? file : nil
        if info.options.isEmpty {
            throw JobError.badURL(info.isLive
                ? "This is a live stream. Try again after it ends."
                : "No video formats found for that link.")
        }
        return .video(info)
    }

    nonisolated static func parseVideo(_ root: [String: Any], url: String) -> VideoInfo {
        let duration = (root["duration"] as? NSNumber)?.intValue
        let liveStatus = root["live_status"] as? String ?? ""
        let isLive = (root["is_live"] as? Bool ?? false) || liveStatus == "is_live" || liveStatus == "is_upcoming"

        var byHeight: [Int: FormatOption] = [:]
        var audioBytes: Int64?

        func size(_ format: [String: Any]) -> Int64? {
            if let bytes = (format["filesize"] as? NSNumber)?.int64Value, bytes > 0 { return bytes }
            if let bytes = (format["filesize_approx"] as? NSNumber)?.int64Value, bytes > 0 { return bytes }
            if let tbr = (format["tbr"] as? NSNumber)?.doubleValue, let duration, duration > 0 {
                return Int64(tbr * 125 * Double(duration))
            }
            return nil
        }

        for format in root["formats"] as? [[String: Any]] ?? [] {
            if format["has_drm"] as? Bool == true { continue }
            if (format["protocol"] as? String) == "mhtml" { continue }

            let vcodec = (format["vcodec"] as? String ?? "none").lowercased()
            let acodec = (format["acodec"] as? String ?? "none").lowercased()

            if vcodec == "none" {
                if acodec != "none", let bytes = size(format), bytes > (audioBytes ?? 0) {
                    audioBytes = bytes
                }
                continue
            }

            guard let height = (format["height"] as? NSNumber)?.intValue, height > 0 else { continue }

            let fps = (format["fps"] as? NSNumber)?.doubleValue.rounded()
            let isAVC = vcodec.hasPrefix("avc1") || vcodec.hasPrefix("h264")
            let range = (format["dynamic_range"] as? String ?? "SDR").uppercased()
            let isHDR = range.contains("HDR") || range == "HLG" || range == "DV"

            var entry = byHeight[height] ?? FormatOption(
                height: height, fps: nil, bestCodec: vcodec,
                hasAVC: false, hasSDR: false, isHDR: false, approxBytes: nil
            )
            entry.hasAVC = entry.hasAVC || isAVC
            entry.hasSDR = entry.hasSDR || !isHDR
            entry.isHDR = entry.isHDR || isHDR
            if let fps, Int(fps) > (entry.fps ?? 0) { entry.fps = Int(fps) }

            // Report the most capable codec at this height, which is what a
            // best-quality download takes: AV1 over VP9 over H.264.
            if codecRank(vcodec) > codecRank(entry.bestCodec) { entry.bestCodec = vcodec }

            if let bytes = size(format), bytes > (entry.approxBytes ?? 0) {
                entry.approxBytes = bytes
            }
            byHeight[height] = entry
        }

        var thumbnail = (root["thumbnail"] as? String).flatMap(URL.init(string:))
        if thumbnail == nil, let id = root["id"] as? String, LinkParser.isYouTube(url) {
            thumbnail = URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        }

        return VideoInfo(
            id: root["id"] as? String ?? UUID().uuidString,
            title: root["title"] as? String ?? "video",
            uploader: (root["uploader"] as? String) ?? (root["channel"] as? String),
            duration: duration,
            thumbnail: thumbnail,
            webpageURL: (root["webpage_url"] as? String) ?? url,
            isLive: isLive,
            options: byHeight.values.sorted { $0.height > $1.height },
            audioBytes: audioBytes,
            infoJSON: nil,
            fetchedAt: Date()
        )
    }

    nonisolated private static func codecRank(_ codec: String) -> Int {
        let key = codec.lowercased()
        if key.hasPrefix("av01") { return 3 }
        if key.hasPrefix("vp09") || key.hasPrefix("vp9") { return 2 }
        if key.hasPrefix("avc") { return 1 }
        return 0
    }

    nonisolated static func parsePlaylist(_ root: [String: Any]) -> PlaylistInfo {
        let entries: [PlaylistInfo.Entry] = (root["entries"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            let title = entry["title"] as? String ?? "video"
            if title == "[Private video]" || title == "[Deleted video]" { return nil }
            let url = (entry["url"] as? String).flatMap { $0.hasPrefix("http") ? $0 : nil }
                ?? "https://www.youtube.com/watch?v=\(id)"
            let thumbs = entry["thumbnails"] as? [[String: Any]]
            let thumb = (thumbs?.last?["url"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")
            return PlaylistInfo.Entry(
                id: id, url: url, title: title,
                duration: (entry["duration"] as? NSNumber)?.intValue,
                thumbnail: thumb
            )
        }
        return PlaylistInfo(
            title: root["title"] as? String ?? "Playlist",
            uploader: (root["uploader"] as? String) ?? (root["channel"] as? String),
            entries: entries
        )
    }

    /// Probe dumps older than a day are useless (their stream URLs expired).
    nonisolated static func purgeOldProbes() {
        let fm = FileManager.default
        let probes = ToolLocator.cacheDirectory.appendingPathComponent("probes", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: probes, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(date) > 86_400 { try? fm.removeItem(at: file) }
        }
    }
}
