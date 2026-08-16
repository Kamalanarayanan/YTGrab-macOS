import Foundation

// MARK: - Quality presets

/// Quality targets rather than fixed bitrates, so a static interview stays
/// small and a shaky handheld clip gets the bits it actually needs.
enum Preset: String, CaseIterable, Identifiable, Sendable {
    case archive  = "Archive (near-lossless)"
    case high     = "High"
    case balanced = "Balanced"
    case compact  = "Compact"

    var id: String { rawValue }

    /// VideoToolbox constant-quality value, 1 to 100.
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

    /// Used only when a build of ffmpeg refuses constant-quality mode on
    /// VideoToolbox and we have to fall back to a bitrate target.
    var bitrateScale: Double {
        switch self {
        case .archive:  return 1.8
        case .high:     return 1.3
        case .balanced: return 1.0
        case .compact:  return 0.65
        }
    }
}

// MARK: - Output

enum OutputCodec: String, CaseIterable, Identifiable, Sendable {
    case hevc  = "H.265 / HEVC"
    case avc   = "H.264"
    case remux = "Keep original"

    var id: String { rawValue }
    var isTranscode: Bool { self != .remux }

    var filenameSuffix: String {
        switch self {
        case .hevc:  return " H265"
        case .avc:   return " H264"
        case .remux: return ""
        }
    }
}

enum EncoderEngine: String, CaseIterable, Identifiable, Sendable {
    case hardware = "Media engine (fast)"
    case software = "Software (smaller files)"

    var id: String { rawValue }
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
    var isHDR: Bool
    var approxBytes: Int64?

    var id: Int { height }

    var resolutionLabel: String {
        height == 0 ? "Best available" : "\(height)p"
    }

    /// The shorthand people actually recognise.
    var tierLabel: String? {
        switch height {
        case 4320: return "8K"
        case 2160: return "4K"
        case 1440: return "2K"
        case 1080: return "Full HD"
        case 720:  return "HD"
        default:   return nil
        }
    }

    var codecLabel: String {
        let key = bestCodec.lowercased()
        if key.hasPrefix("avc1") || key.hasPrefix("h264") { return "H.264" }
        if key.hasPrefix("vp9") || key.hasPrefix("vp09")  { return "VP9" }
        if key.hasPrefix("av01") || key.hasPrefix("av1")  { return "AV1" }
        if key.hasPrefix("hev") || key.hasPrefix("hvc")   { return "H.265" }
        return bestCodec.isEmpty ? "unknown" : bestCodec
    }

    var sizeLabel: String? {
        guard let bytes = approxBytes, bytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = bytes > 1_000_000_000 ? [.useGB] : [.useMB]
        return formatter.string(fromByteCount: bytes)
    }

    /// One-line summary for the picker.
    var summary: String {
        var parts: [String] = [resolutionLabel]
        if let tier = tierLabel { parts.append(tier) }
        parts.append(codecLabel)
        if let fps, fps >= 48 { parts.append("\(fps)fps") }
        if isHDR { parts.append("HDR") }
        if let size = sizeLabel { parts.append("~\(size)") }
        return parts.joined(separator: "  ·  ")
    }

    /// Whether Keep original at this rung produces a file that edits cleanly,
    /// or one Premiere is likely to refuse.
    var copiesCleanly: Bool { hasAVC }
}

struct VideoInfo: Sendable {
    var title: String
    var uploader: String?
    var duration: Int?               // seconds
    var options: [FormatOption]      // descending by height

    var maxHeight: Int { options.first?.height ?? 0 }
    var maxAVCHeight: Int { options.filter(\.hasAVC).map(\.height).max() ?? 0 }
    var best: FormatOption? { options.first }

    var durationLabel: String? {
        guard let duration, duration > 0 else { return nil }
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        let seconds = duration % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Job description

struct JobOptions: Sendable {
    var url: String
    var title: String
    var height: Int            // 0 means whatever the best available is
    var codec: OutputCodec
    var engine: EncoderEngine
    var preset: Preset
    var tenBit: Bool
    var preferAVC: Bool
    var outputDirectory: URL
}

// MARK: - What ffprobe tells us about the file on disk

struct MediaStreams: Sendable {
    var videoCodec: String = "?"
    var height: Int = 0
    var fps: Int = 0
    var audioCodec: String = ""
    var audioChannels: Int = 2
    var colorPrimaries: String?
    var colorTransfer: String?
    var colorSpace: String?
    var colorRange: String?

    /// Only AAC and MP3 survive a straight copy into an MP4 container.
    /// YouTube normally serves Opus, which does not.
    var audioCanBeCopied: Bool {
        audioCodec == "aac" || audioCodec == "mp3"
    }

    /// Colour tags carried through so the file does not shift on import.
    var colorFlags: [String] {
        var flags: [String] = []
        func add(_ flag: String, _ value: String?) {
            guard let value, !value.isEmpty, value != "unknown" else { return }
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
    case toolSetupFailed(String)
    case updateFailed(String)
    case processFailed(tool: String, code: Int32, detail: String)
    case noOutputFile
    case badURL(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingTools(let names):
            return "The app's embedded tools are unavailable: \(names.joined(separator: ", ")). Reinstall YTGrab to restore them."
        case .toolSetupFailed(let detail):
            return "YTGrab could not prepare its embedded tools. \(detail)"
        case .updateFailed(let detail):
            return "The tool update failed. \(detail)"
        case .processFailed(let tool, let code, let detail):
            return "\(tool) exited with \(code)\n\(detail)"
        case .noOutputFile:
            return "Download finished but no file appeared."
        case .badURL(let detail):
            return detail
        case .cancelled:
            return "Cancelled."
        }
    }
}
