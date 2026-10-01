import Foundation

// MARK: - What the user wants out

enum VideoCodec: String, Sendable {
    case h264
    case hevc

    var displayName: String { self == .h264 ? "H.264" : "H.265" }
    var ffmpegName: String { self == .h264 ? "h264" : "hevc" }
}

/// The five things people actually come to the app for, in the order the
/// interface presents them.
enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
    case editReady = "mp4-h264"
    case compact   = "mp4-hevc"
    case original  = "original"
    case audioM4A  = "m4a"
    case audioMP3  = "mp3"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editReady: return "Edit-ready MP4"
        case .compact:   return "Compact MP4"
        case .original:  return "Original"
        case .audioM4A:  return "Audio · M4A"
        case .audioMP3:  return "Audio · MP3"
        }
    }

    var subtitle: String {
        switch self {
        case .editReady: return "H.264 · opens everywhere"
        case .compact:   return "H.265 · about half the size"
        case .original:  return "No re-encode · fastest"
        case .audioM4A:  return "AAC · best for Apple apps"
        case .audioMP3:  return "MP3 · plays anywhere"
        }
    }

    var symbol: String {
        switch self {
        case .editReady: return "film"
        case .compact:   return "rectangle.compress.vertical"
        case .original:  return "bolt"
        case .audioM4A:  return "waveform"
        case .audioMP3:  return "music.note"
        }
    }

    var isAudioOnly: Bool { self == .audioM4A || self == .audioMP3 }

    /// The codec a video job ends up in, when it re-encodes at all.
    var targetCodec: VideoCodec? {
        switch self {
        case .editReady: return .h264
        case .compact:   return .hevc
        default:         return nil
        }
    }

    var fileExtension: String {
        switch self {
        case .audioM4A: return "m4a"
        case .audioMP3: return "mp3"
        default:        return "mp4"
        }
    }

    var filenameSuffix: String {
        switch self {
        case .editReady: return " H264"
        case .compact:   return " H265"
        default:         return ""
        }
    }
}

/// Quality targets rather than fixed bitrates, so a static interview stays
/// small and a shaky handheld clip gets the bits it actually needs.
enum Preset: String, CaseIterable, Identifiable, Sendable {
    case archive  = "Archive"
    case high     = "High"
    case balanced = "Balanced"
    case compact  = "Small"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .archive:  return "Near-lossless, large files"
        case .high:     return "Visually identical to the source"
        case .balanced: return "Good quality, sensible size"
        case .compact:  return "Smallest files"
        }
    }

    /// VideoToolbox constant-quality value, 1 to 100 (Apple silicon only).
    var videoToolboxQuality: Int {
        switch self {
        case .archive:  return 82
        case .high:     return 70
        case .balanced: return 60
        case .compact:  return 48
        }
    }

    var x264CRF: Int {
        switch self {
        case .archive:  return 16
        case .high:     return 19
        case .balanced: return 22
        case .compact:  return 25
        }
    }

    var x265CRF: Int {
        switch self {
        case .archive:  return 18
        case .high:     return 21
        case .balanced: return 24
        case .compact:  return 28
        }
    }

    /// Scales the reference bitrate when VideoToolbox runs in bitrate mode
    /// (always on Intel, and as a fallback on Apple silicon).
    var bitrateScale: Double {
        switch self {
        case .archive:  return 1.8
        case .high:     return 1.3
        case .balanced: return 1.0
        case .compact:  return 0.65
        }
    }
}

enum EncoderEngine: String, CaseIterable, Identifiable, Sendable {
    case automatic = "Automatic"
    case hardware  = "Media engine"
    case software  = "Software (CPU)"

    var id: String { rawValue }

    /// Automatic picks the hardware encoder when this Mac has one for the
    /// codec, and the CPU encoder otherwise.
    func resolved(for codec: VideoCodec, on profile: SystemProfile) -> EncoderEngine {
        switch self {
        case .automatic:
            return profile.hardwareEncodes(codec) ? .hardware : .software
        default:
            return self
        }
    }
}

enum CookieBrowser: String, CaseIterable, Identifiable, Sendable {
    case none, safari, chrome, firefox, brave, edge, chromium, opera, vivaldi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:     return "Off"
        case .safari:   return "Safari"
        case .chrome:   return "Google Chrome"
        case .firefox:  return "Firefox"
        case .brave:    return "Brave"
        case .edge:     return "Microsoft Edge"
        case .chromium: return "Chromium"
        case .opera:    return "Opera"
        case .vivaldi:  return "Vivaldi"
        }
    }

    /// The value yt-dlp's --cookies-from-browser expects.
    var ytdlpName: String? { self == .none ? nil : rawValue }
}

// MARK: - What yt-dlp found for one resolution

/// One rung on the quality ladder, carrying the detail needed to actually
/// choose: which codec YouTube serves at that height, the frame rate, whether
/// HDR is involved, and roughly how large the download will be.
struct FormatOption: Identifiable, Hashable, Sendable {

    var height: Int
    var fps: Int?
    var bestCodec: String          // avc1, vp09, av01 and so on
    var hasAVC: Bool               // an H.264 stream exists at this height
    var hasSDR: Bool               // a non-HDR stream exists at this height
    var isHDR: Bool
    var approxBytes: Int64?

    var id: Int { height }

    var resolutionLabel: String { "\(height)p" }

    /// The shorthand people actually recognise.
    var tierLabel: String? { Self.tier(for: height) }

    static func tier(for height: Int) -> String? {
        switch height {
        case 4320...:      return "8K"
        case 2160..<4320:  return "4K"
        case 1440..<2160:  return "2K"
        case 1080..<1440:  return "Full HD"
        case 720..<1080:   return "HD"
        default:           return nil
        }
    }

    var codecLabel: String { Self.codecLabel(bestCodec) }

    static func codecLabel(_ raw: String) -> String {
        let key = raw.lowercased()
        if key.hasPrefix("avc") || key.hasPrefix("h264") { return "H.264" }
        if key.hasPrefix("vp9") || key.hasPrefix("vp09") { return "VP9" }
        if key.hasPrefix("av01") || key.hasPrefix("av1") { return "AV1" }
        if key.hasPrefix("hev") || key.hasPrefix("hvc")  { return "H.265" }
        return raw.isEmpty ? "unknown" : raw
    }
}

struct VideoInfo: Sendable {
    var id: String
    var title: String
    var uploader: String?
    var duration: Int?               // seconds
    var thumbnail: URL?
    var webpageURL: String
    var isLive: Bool
    var options: [FormatOption]      // descending by height
    var audioBytes: Int64?           // the best audio-only stream
    var infoJSON: URL?               // yt-dlp's dump, reused for the download
    var fetchedAt: Date

    var maxHeight: Int { options.first?.height ?? 0 }
    var maxAVCHeight: Int { options.filter(\.hasAVC).map(\.height).max() ?? 0 }
    var best: FormatOption? { options.first }

    func option(for height: Int) -> FormatOption? {
        height == 0 ? best : options.first { $0.height == height }
    }

    /// Video plus audio, which is what actually lands on disk.
    func estimatedBytes(for option: FormatOption?) -> Int64? {
        guard let video = option?.approxBytes else { return nil }
        return video + (audioBytes ?? 0)
    }

    var durationLabel: String? { Format.duration(duration) }
}

struct PlaylistInfo: Sendable {
    struct Entry: Sendable, Identifiable {
        var id: String
        var url: String
        var title: String
        var duration: Int?
        var thumbnail: URL?
    }

    var title: String
    var uploader: String?
    var entries: [Entry]
}

// MARK: - Job description

/// Everything a download needs, captured when the user presses Download so
/// later changes in the interface cannot affect a job that is already queued.
struct JobRequest: Sendable {
    var url: String
    var title: String
    var uploader: String?
    var duration: Int?
    var infoJSON: URL?
    var infoFetchedAt: Date?
    var format: OutputFormat
    var height: Int                  // 0 means best available
    var option: FormatOption?        // the probed rung, when known
    var engine: EncoderEngine
    var preset: Preset
    var tenBit: Bool
    var keepHDR: Bool
    var preferH264Source: Bool
    var outputDirectory: URL
    var cookies: CookieBrowser
    var forceIPv4: Bool
}

// MARK: - What ffprobe tells us about the file on disk

struct MediaStreams: Sendable {
    var videoCodec: String = ""
    var height: Int = 0
    var fps: Int = 0
    var pixelFormat: String = ""
    var audioCodec: String = ""
    var audioChannels: Int = 2
    var duration: Double = 0
    var colorPrimaries: String?
    var colorTransfer: String?
    var colorSpace: String?
    var colorRange: String?

    var hasVideo: Bool { !videoCodec.isEmpty }
    var hasAudio: Bool { !audioCodec.isEmpty }

    var isTenBit: Bool { pixelFormat.contains("10") || pixelFormat.contains("12") }

    /// PQ (HDR10) or HLG transfer.
    var isHDR: Bool {
        colorTransfer == "smpte2084" || colorTransfer == "arib-std-b67"
    }

    /// Colour tags carried through so the file does not shift on import.
    var colorFlags: [String] {
        var flags: [String] = []
        func add(_ flag: String, _ value: String?) {
            guard let value, !value.isEmpty, value != "unknown", value != "unspecified" else { return }
            flags += [flag, value]
        }
        add("-color_primaries", colorPrimaries)
        add("-color_trc", colorTransfer)
        add("-colorspace", colorSpace)
        add("-color_range", colorRange)
        return flags
    }
}

// MARK: - Errors

enum JobError: LocalizedError, Sendable {
    case missingTools([String])
    case unsupportedArchitecture(String)
    case toolSetupFailed(String)
    case updateFailed(String)
    case processFailed(tool: String, code: Int32, detail: String)
    case processKilled(tool: String, signal: Int32)
    case timedOut(String)
    case noOutputFile
    case notEnoughSpace(needed: Int64, available: Int64)
    case badURL(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingTools(let names):
            return "The app's embedded tools are unavailable: \(names.joined(separator: ", ")). Reinstall YTGrab to restore them."
        case .unsupportedArchitecture(let detail):
            return detail
        case .toolSetupFailed(let detail):
            return "YTGrab could not prepare its embedded tools. \(detail)"
        case .updateFailed(let detail):
            return "The tool update failed. \(detail)"
        case .processFailed(let tool, let code, let detail):
            return detail.isEmpty ? "\(tool) stopped with code \(code)." : detail
        case .processKilled(let tool, let signal):
            return "\(tool) was stopped by macOS (signal \(signal))."
        case .timedOut(let tool):
            return "\(tool) did not respond in time."
        case .noOutputFile:
            return "The download finished but no file appeared."
        case .notEnoughSpace(let needed, let available):
            return "Not enough free space. This needs about \(Format.bytes(needed)), but only \(Format.bytes(available)) is free."
        case .badURL(let detail):
            return detail
        case .cancelled:
            return "Cancelled."
        }
    }
}

// MARK: - Formatting helpers

enum Format {
    static func duration(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func eta(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s left" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s left" }
        return "\(total / 3600)h \((total % 3600) / 60)m left"
    }
}
