import Foundation

/// Everything that decides what ffmpeg actually gets asked to do.
enum CommandBuilder {

    // MARK: - Download

    /// yt-dlp format selector.
    ///
    /// When the plan is a straight copy we ask YouTube for an H.264 stream
    /// first, so the copy is genuinely useful rather than leaving VP9 sitting
    /// inside an MP4 that Premiere will not open.
    static func formatSelector(height: Int, codec: OutputCodec, preferAVC: Bool) -> String {
        let cap = height == 0 ? "" : "[height<=\(height)]"

        if codec == .remux && preferAVC {
            return [
                "bv*[vcodec^=avc1]\(cap)+ba[acodec^=mp4a]",
                "bv*[vcodec^=avc1]\(cap)+ba",
                "bv*\(cap)+ba",
                "b\(cap)",
            ].joined(separator: "/")
        }
        return "bv*\(cap)+ba/b\(cap)"
    }

    static func downloadArguments(options: JobOptions, template: String, deno: URL) -> [String] {
        [
            "--no-playlist",
            "--newline",
            "--no-warnings",
            "--js-runtimes", "deno:\(deno.path)",
            "--remote-components", "ejs:github",
            "-f", formatSelector(height: options.height, codec: options.codec, preferAVC: options.preferAVC),
            "--merge-output-format", "mkv",
            "-o", template,
            options.url,
        ]
    }

    static func probeArguments(url: String, deno: URL) -> [String] {
        [
            "-J", "--no-playlist", "--no-warnings",
            "--js-runtimes", "deno:\(deno.path)",
            "--remote-components", "ejs:github",
            url,
        ]
    }

    // MARK: - Audio

    /// MP4 cannot carry Opus, which is what YouTube usually serves.
    private static func audioArguments(_ streams: MediaStreams) -> [String] {
        if streams.audioCanBeCopied {
            return ["-c:a", "copy"]
        }
        let bitrate = streams.audioChannels > 2 ? "320k" : "256k"
        return ["-c:a", "aac", "-b:a", bitrate]
    }

    // MARK: - Remux

    static func remuxArguments(source: URL, destination: URL, streams: MediaStreams) -> [String] {
        var args = [
            "-y", "-hide_banner", "-loglevel", "warning", "-stats",
            "-i", source.path,
            "-c:v", "copy",
        ]
        if streams.videoCodec == "hevc" {
            args += ["-tag:v", "hvc1"]
        }
        args += audioArguments(streams)
        args += ["-movflags", "+faststart", destination.path]
        return args
    }

    // MARK: - Encode

    static func encodeArguments(
        source: URL,
        destination: URL,
        options: JobOptions,
        streams: MediaStreams
    ) -> [String] {
        let wantsHEVC = options.codec == .hevc
        let tenBit = options.tenBit && wantsHEVC

        var args = [
            "-y", "-hide_banner", "-loglevel", "warning", "-stats",
            "-i", source.path,
        ]

        switch options.engine {
        case .hardware:
            args += ["-c:v", wantsHEVC ? "hevc_videotoolbox" : "h264_videotoolbox"]
            args += ["-q:v", String(options.preset.videoToolboxQuality)]
            if wantsHEVC {
                args += ["-profile:v", tenBit ? "main10" : "main"]
                if tenBit { args += ["-pix_fmt", "p010le"] }
            } else {
                args += ["-profile:v", "high"]
            }
            // Stops the media engine stalling on awkward 4K sources.
            args += ["-allow_sw", "1"]

        case .software:
            if wantsHEVC {
                args += ["-c:v", "libx265",
                         "-crf", String(options.preset.x265CRF),
                         "-preset", "slow",
                         "-pix_fmt", tenBit ? "yuv420p10le" : "yuv420p",
                         "-x265-params", "log-level=error"]
            } else {
                args += ["-c:v", "libx264",
                         "-crf", String(options.preset.x264CRF),
                         "-preset", "slow",
                         "-pix_fmt", "yuv420p",
                         "-profile:v", "high"]
            }
        }

        args += streams.colorFlags

        // Without the hvc1 tag, QuickTime and Premiere refuse to open the file
        // at all. This single flag is the usual reason a hand-rolled HEVC
        // export appears broken.
        args += ["-tag:v", wantsHEVC ? "hvc1" : "avc1"]

        args += audioArguments(streams)
        args += ["-movflags", "+faststart", destination.path]
        return args
    }

    /// Some older ffmpeg builds reject -q:v on VideoToolbox. Swap the
    /// constant-quality flag for a resolution-appropriate bitrate instead of
    /// failing the whole job.
    static func bitrateFallback(from arguments: [String], options: JobOptions, streams: MediaStreams) -> [String] {
        let reference: [Int: Double] = [2160: 45, 1440: 24, 1080: 12, 720: 6, 480: 3]
        let sourceHeight = streams.height > 0 ? streams.height : 1080
        let nearest = reference.keys.min { abs($0 - sourceHeight) < abs($1 - sourceHeight) } ?? 1080
        var mbps = reference[nearest] ?? 12
        if options.codec == .hevc { mbps *= 0.6 }
        mbps *= options.preset.bitrateScale

        var stripped: [String] = []
        var skipNext = false
        for argument in arguments {
            if skipNext { skipNext = false; continue }
            if argument == "-q:v" { skipNext = true; continue }
            stripped.append(argument)
        }

        let rate = String(format: "%.1fM", mbps)
        let maxRate = String(format: "%.1fM", mbps * 1.5)
        let bufSize = String(format: "%.1fM", mbps * 3)

        // Insert just before the output path, which is always the last item.
        let insertAt = max(stripped.count - 1, 0)
        stripped.insert(contentsOf: ["-b:v", rate, "-maxrate", maxRate, "-bufsize", bufSize], at: insertAt)
        return stripped
    }

    // MARK: - Naming

    static func outputURL(directory: URL, title: String, height: Int, codec: OutputCodec) -> URL {
        var base = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.count > 120 { base = String(base.prefix(120)) }
        if base.isEmpty { base = "video" }

        let stem = "\(base) \(height)p\(codec.filenameSuffix)"
        var candidate = directory.appendingPathComponent(stem + ".mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) \(counter).mp4")
            counter += 1
        }
        return candidate
    }
}
