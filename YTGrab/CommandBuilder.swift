import Foundation

/// Everything that decides what yt-dlp and ffmpeg actually get asked to do.
/// Pure functions only, so the decisions are easy to read and adjust.
enum CommandBuilder {

    // MARK: - Shared yt-dlp flags

    /// Flags every yt-dlp call needs.
    ///
    /// `--ignore-config` matters more than it looks: people who also use
    /// yt-dlp in Terminal often keep a config file with their own `-o` or
    /// `-f`, and without this flag it silently overrides the app.
    static func commonArguments(tools: ToolLocator.Toolchain, cookies: CookieBrowser, forceIPv4: Bool) -> [String] {
        var args = [
            "--ignore-config",
            "--no-playlist",
            "--js-runtimes", "deno:\(tools.deno.path)",
            "--remote-components", "ejs:github",
            "--cache-dir", ToolLocator.cacheDirectory.path,
            "--extractor-retries", "3",
        ]
        if let browser = cookies.ytdlpName {
            args += ["--cookies-from-browser", browser]
        }
        if forceIPv4 {
            args.append("--force-ipv4")
        }
        return args
    }

    /// One call reads either a single video in full or a playlist's entries.
    /// `--flat-playlist` only affects playlists; `--no-playlist` (in the
    /// common flags) keeps a watch link that carries `&list=` on its video.
    static func probeArguments(url: String, tools: ToolLocator.Toolchain, cookies: CookieBrowser, forceIPv4: Bool) -> [String] {
        commonArguments(tools: tools, cookies: cookies, forceIPv4: forceIPv4) + [
            "-J",
            "--flat-playlist",
            "--playlist-items", "1:300",
            url,
        ]
    }

    // MARK: - Format selection

    /// The yt-dlp format selector for a request, tried left to right.
    ///
    /// The final alternatives are deliberately loose so a job always gets
    /// *something* rather than failing with "Requested format is not
    /// available" on an unusual video.
    static func formatSelector(for request: JobRequest) -> String {
        let cap = request.height > 0 ? "[height<=\(request.height)]" : ""

        switch request.format {
        case .audioM4A:
            return "ba[acodec^=mp4a]/ba/b"
        case .audioMP3:
            return "ba/b"
        case .original:
            return "bv*\(cap)+ba/b\(cap)/bv*+ba/b"
        case .editReady, .compact:
            break
        }

        var alternatives: [String] = []

        // YouTube already serves H.264 up to 1080p. Copying that stream is
        // lossless and takes seconds, where re-encoding VP9 takes minutes and
        // costs a generation of quality.
        if request.format == .editReady && request.preferH264Source {
            if let option = request.option {
                if option.hasAVC {
                    alternatives += [
                        "bv*[vcodec^=avc1][height=\(option.height)]+ba[acodec^=mp4a]",
                        "bv*[vcodec^=avc1][height=\(option.height)]+ba",
                    ]
                }
            } else if request.height > 0 && request.height <= 1080 {
                // Playlist entries are not probed one by one. At 1080p and
                // below YouTube nearly always has H.264, so ask for it first.
                alternatives += [
                    "bv*[vcodec^=avc1]\(cap)+ba[acodec^=mp4a]",
                    "bv*[vcodec^=avc1]\(cap)+ba",
                ]
            }
        }

        // Edit-ready output is 8-bit SDR. HDR videos on YouTube also carry an
        // SDR rendition; taking it avoids washed-out colour after conversion.
        let wantsSDR = !(request.format == .compact && request.keepHDR)
        if wantsSDR {
            alternatives.append("bv*\(cap)[dynamic_range=SDR]+ba")
        }
        alternatives += ["bv*\(cap)+ba", "b\(cap)", "bv*+ba", "b"]
        return alternatives.joined(separator: "/")
    }

    /// Format sort tweaks. Without hardware AV1 decode, VP9 sources convert
    /// several times faster at the same resolution.
    static func formatSort(for request: JobRequest, profile: SystemProfile) -> [String] {
        guard request.format.targetCodec != nil, profile.prefersVP9Sources else { return [] }
        return ["-S", "res,fps,vcodec:vp9"]
    }

    /// Lines starting with this marker carry machine-readable progress.
    static let progressMarker = "[ytg]"

    static func downloadArguments(
        request: JobRequest,
        tools: ToolLocator.Toolchain,
        profile: SystemProfile,
        template: String,
        useInfoJSON: Bool,
        selector: String? = nil
    ) -> [String] {
        var args = commonArguments(tools: tools, cookies: request.cookies, forceIPv4: request.forceIPv4)
        args += [
            "--newline",
            "--progress-delta", "0.4",
            "--progress-template",
            "download:\(progressMarker) %(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(info.vcodec)s",
            "--concurrent-fragments", "4",
            "--retries", "10",
            "--fragment-retries", "10",
            "--no-mtime",
            "-f", selector ?? formatSelector(for: request),
        ]
        args += formatSort(for: request, profile: profile)
        if !request.format.isAudioOnly {
            args += ["--merge-output-format", "mkv"]
        }
        args += ["-o", template]
        if request.title.isEmpty {
            // Links queued without a preview learn their title from this.
            args.append("--write-info-json")
        }

        if useInfoJSON, let json = request.infoJSON {
            args += ["--load-info-json", json.path]
        } else {
            args.append(request.url)
        }
        return args
    }

    // MARK: - ffmpeg

    private static func ffmpegPrelude() -> [String] {
        ["-y", "-hide_banner", "-nostdin", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]
    }

    /// MP4 cannot carry Opus, which is what YouTube usually serves.
    static func audioArguments(_ streams: MediaStreams) -> [String] {
        guard streams.hasAudio else { return [] }
        if streams.audioCodec == "aac" || streams.audioCodec == "mp3" {
            return ["-c:a", "copy"]
        }
        let bitrate = streams.audioChannels > 2 ? "384k" : "256k"
        return ["-c:a", "aac", "-b:a", bitrate]
    }

    private static func metadataArguments(_ request: JobRequest) -> [String] {
        var args = ["-metadata", "title=\(request.title)"]
        if let uploader = request.uploader, !uploader.isEmpty {
            args += ["-metadata", "artist=\(uploader)"]
        }
        args += ["-metadata", "comment=\(request.url)"]
        return args
    }

    /// Video stays untouched; only the container and, if needed, the audio
    /// change.
    static func copyArguments(source: URL, destination: URL, streams: MediaStreams, request: JobRequest) -> [String] {
        var args = ffmpegPrelude() + ["-i", source.path, "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "copy"]
        if streams.videoCodec == "hevc" {
            args += ["-tag:v", "hvc1"]
        }
        args += audioArguments(streams)
        args += metadataArguments(request)
        args += ["-movflags", "+faststart", destination.path]
        return args
    }

    static func audioOnlyArguments(source: URL, destination: URL, streams: MediaStreams, request: JobRequest) -> [String] {
        var args = ffmpegPrelude() + ["-i", source.path, "-vn", "-map", "0:a:0"]
        switch request.format {
        case .audioMP3:
            args += streams.audioCodec == "mp3"
                ? ["-c:a", "copy"]
                : ["-c:a", "libmp3lame", "-q:a", "0"]
        default:
            args += streams.audioCodec == "aac"
                ? ["-c:a", "copy"]
                : ["-c:a", "aac", "-b:a", streams.audioChannels > 2 ? "384k" : "256k"]
            args += ["-movflags", "+faststart"]
        }
        args += metadataArguments(request)
        args.append(destination.path)
        return args
    }

    /// One way of running the encode. The engine tries these in order, so a
    /// Mac whose ffmpeg or hardware refuses one approach falls through to the
    /// next instead of failing the job.
    struct EncodeAttempt: Equatable {
        var engine: EncoderEngine            // .hardware or .software
        var hardwareDecode: Bool
        var constantQuality: Bool            // VideoToolbox -q:v

        var label: String {
            switch engine {
            case .software: return "software encoder"
            default:        return constantQuality ? "media engine" : "media engine (bitrate mode)"
            }
        }
    }

    static func encodeAttempts(codec: VideoCodec, request: JobRequest, streams: MediaStreams, profile: SystemProfile) -> [EncodeAttempt] {
        let engine = request.engine.resolved(for: codec, on: profile)
        let decode = profile.hardwareDecodes(ffmpegCodec: streams.videoCodec)
        var attempts: [EncodeAttempt] = []

        if engine == .hardware {
            let quality = profile.supportsConstantQuality
            attempts.append(EncodeAttempt(engine: .hardware, hardwareDecode: decode, constantQuality: quality))
            if decode {
                attempts.append(EncodeAttempt(engine: .hardware, hardwareDecode: false, constantQuality: quality))
            }
            if quality {
                attempts.append(EncodeAttempt(engine: .hardware, hardwareDecode: false, constantQuality: false))
            }
        }
        // The CPU encoder is the last resort for every Mac, including ones
        // whose VideoToolbox is unavailable (virtual machines, for example).
        attempts.append(EncodeAttempt(engine: .software, hardwareDecode: false, constantQuality: false))
        if engine == .software && decode {
            attempts.insert(EncodeAttempt(engine: .software, hardwareDecode: true, constantQuality: false), at: 0)
        }

        var unique: [EncodeAttempt] = []
        for attempt in attempts where !unique.contains(attempt) { unique.append(attempt) }
        return unique
    }

    static func encodeArguments(
        source: URL,
        destination: URL,
        codec: VideoCodec,
        attempt: EncodeAttempt,
        request: JobRequest,
        streams: MediaStreams,
        profile: SystemProfile
    ) -> [String] {
        let wantsHEVC = codec == .hevc
        // HDR only survives in 10-bit HEVC. Edit-ready H.264 is always 8-bit.
        let keepHDR = wantsHEVC && request.keepHDR && streams.isHDR
        let tenBit = wantsHEVC && (request.tenBit || keepHDR)

        var args = ffmpegPrelude()
        if attempt.hardwareDecode {
            args += ["-hwaccel", "videotoolbox"]
        }
        args += ["-i", source.path, "-map", "0:v:0", "-map", "0:a:0?"]

        switch attempt.engine {
        case .software:
            if wantsHEVC {
                args += ["-c:v", "libx265",
                         "-crf", String(request.preset.x265CRF),
                         "-preset", profile.softwarePreset(for: .hevc),
                         "-pix_fmt", tenBit ? "yuv420p10le" : "yuv420p",
                         "-x265-params", "log-level=error"]
            } else {
                args += ["-c:v", "libx264",
                         "-crf", String(request.preset.x264CRF),
                         "-preset", profile.softwarePreset(for: .h264),
                         "-pix_fmt", "yuv420p",
                         "-profile:v", "high"]
            }

        default:
            args += ["-c:v", wantsHEVC ? "hevc_videotoolbox" : "h264_videotoolbox"]
            if attempt.constantQuality {
                args += ["-q:v", String(request.preset.videoToolboxQuality)]
            } else {
                args += bitrateArguments(codec: codec, preset: request.preset, height: streams.height, fps: streams.fps)
            }
            if wantsHEVC {
                args += ["-profile:v", tenBit ? "main10" : "main",
                         "-pix_fmt", tenBit ? "p010le" : "nv12"]
            } else {
                args += ["-profile:v", "high", "-pix_fmt", "nv12"]
            }
            // Lets VideoToolbox fall back to Apple's software encoder on
            // Intel Macs without an HEVC block, instead of erroring out.
            args += ["-allow_sw", "1"]
        }

        // Carry the source colour tags through, except HDR tags on an SDR
        // output, where they would make players apply the wrong curve.
        if !streams.isHDR || keepHDR {
            args += streams.colorFlags
        } else {
            args += ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        }

        // Without the hvc1 tag, QuickTime and Premiere refuse to open HEVC
        // files at all.
        args += ["-tag:v", wantsHEVC ? "hvc1" : "avc1"]
        args += audioArguments(streams)
        args += metadataArguments(request)
        args += ["-movflags", "+faststart", destination.path]
        return args
    }

    /// Bitrate targets for VideoToolbox when constant quality is unavailable.
    static func bitrateArguments(codec: VideoCodec, preset: Preset, height: Int, fps: Int) -> [String] {
        let reference: [Int: Double] = [4320: 120, 2160: 45, 1440: 24, 1080: 12, 720: 6, 480: 3, 360: 1.5]
        let sourceHeight = height > 0 ? height : 1080
        let nearest = reference.keys.min { abs($0 - sourceHeight) < abs($1 - sourceHeight) } ?? 1080
        var mbps = reference[nearest] ?? 12
        if fps >= 48 { mbps *= 1.5 }
        if codec == .hevc { mbps *= 0.6 }
        mbps *= preset.bitrateScale

        return [
            "-b:v", String(format: "%.1fM", mbps),
            "-maxrate", String(format: "%.1fM", mbps * 1.5),
            "-bufsize", String(format: "%.1fM", mbps * 3),
        ]
    }

    // MARK: - Naming

    /// macOS allows 255 bytes per file name, not 255 characters. A 120
    /// character Tamil, Hindi or Japanese title is well over that, so the
    /// limit is applied to the UTF-8 byte count, on character boundaries.
    static func sanitizedTitle(_ title: String, maxBytes: Int = 180) -> String {
        var cleaned = title.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) { return " " }
            switch scalar {
            case "/", ":", "\\": return "-"
            default: return String(scalar)
            }
        }.joined()

        cleaned = cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // A leading dot would hide the file in Finder.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }

        var result = ""
        var used = 0
        for character in cleaned {
            let size = String(character).utf8.count
            if used + size > maxBytes { break }
            result.append(character)
            used += size
        }
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "video" : result
    }

    static func outputName(request: JobRequest, height: Int) -> String {
        let base = sanitizedTitle(request.title)
        if request.format.isAudioOnly {
            return base
        }
        let heightPart = height > 0 ? " \(height)p" : ""
        return "\(base)\(heightPart)\(request.format.filenameSuffix)"
    }

    /// The first free name in the folder: "Title.mp4", "Title 2.mp4", …
    static func uniqueURL(directory: URL, stem: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(stem).appendingPathExtension(ext)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) \(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }
}
