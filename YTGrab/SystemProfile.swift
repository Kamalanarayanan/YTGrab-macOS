import Foundation
import VideoToolbox

/// What this particular Mac can do, detected once at launch.
///
/// YTGrab ships as a universal app, so the same bundle has to make good
/// choices on an M4 Max and on a 2018 Intel MacBook Air. Everything that
/// depends on the hardware — which encoder to use, whether VideoToolbox
/// understands constant-quality mode, which YouTube codec decodes fastest —
/// reads from here instead of assuming Apple Silicon.
struct SystemProfile: Sendable {

    enum Architecture: String, Sendable {
        case arm64
        case x86_64

        /// The name `ditto --arch` and `lipo` use for this slice.
        var sliceName: String { rawValue }

        var displayName: String {
            switch self {
            case .arm64:  return "Apple silicon"
            case .x86_64: return "Intel"
            }
        }
    }

    /// The CPU family of the machine, not of this process. Under Rosetta the
    /// process is x86_64 but the hardware, and therefore the tools, are arm64.
    let architecture: Architecture
    /// True when the app itself was launched under Rosetta.
    let isTranslated: Bool
    let chipName: String
    let modelIdentifier: String
    let performanceCores: Int
    let totalCores: Int
    let memoryGB: Int
    let macOSVersion: String

    let hardwareEncodesH264: Bool
    let hardwareEncodesHEVC: Bool
    let hardwareDecodesHEVC: Bool
    let hardwareDecodesVP9: Bool
    let hardwareDecodesAV1: Bool

    static let current = SystemProfile.detect()

    // MARK: - Decisions derived from the hardware

    /// VideoToolbox constant-quality (`-q:v`) only exists on Apple silicon.
    /// Intel Macs reject it, so they go straight to a bitrate target instead
    /// of failing first and retrying.
    var supportsConstantQuality: Bool { architecture == .arm64 }

    func hardwareEncodes(_ codec: VideoCodec) -> Bool {
        switch codec {
        case .h264: return hardwareEncodesH264
        case .hevc: return hardwareEncodesHEVC
        }
    }

    /// Whether ffmpeg should ask VideoToolbox to decode this source codec.
    func hardwareDecodes(ffmpegCodec name: String) -> Bool {
        switch name {
        case "h264": return true
        case "hevc": return hardwareDecodesHEVC
        case "vp9":  return hardwareDecodesVP9
        case "av1":  return hardwareDecodesAV1
        default:     return false
        }
    }

    /// AV1 is the most expensive YouTube codec to decode in software. Unless
    /// the Mac decodes it in hardware (M3 and later), a transcode is several
    /// times faster from the VP9 rendition of the same resolution.
    var prefersVP9Sources: Bool { !hardwareDecodesAV1 }

    /// Software x264/x265 presets scaled to the CPU, so an older dual-core
    /// machine is not sent to `slow` for an hour.
    func softwarePreset(for codec: VideoCodec) -> String {
        let strong = performanceCores >= 8 || (architecture == .arm64 && totalCores >= 8)
        switch codec {
        case .h264: return strong ? "slow" : "medium"
        case .hevc: return strong ? "medium" : "fast"
        }
    }

    /// Jobs that can run side by side without starving each other. Pro and
    /// Max chips carry more than one media engine.
    var recommendedConcurrentJobs: Int {
        if architecture == .arm64 && performanceCores >= 8 { return 2 }
        return 1
    }

    var summary: String {
        var parts = [chipName]
        if isTranslated { parts.append("running under Rosetta") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Detection

    private static func detect() -> SystemProfile {
        let isAppleSilicon = sysctlInt("hw.optional.arm64") == 1
        let translated = sysctlInt("sysctl.proc_translated") == 1

        let brand = sysctlString("machdep.cpu.brand_string") ?? ""
        let chip = brand.isEmpty ? (isAppleSilicon ? "Apple silicon" : "Intel") : brand
            .replacingOccurrences(of: "(R)", with: "")
            .replacingOccurrences(of: "(TM)", with: "")
            .replacingOccurrences(of: "  ", with: " ")

        let total = sysctlInt("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount
        let performance = sysctlInt("hw.perflevel0.physicalcpu") ?? total
        let memory = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "macOS \(os.majorVersion).\(os.minorVersion)"
            + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")

        let encoders = hardwareEncoders()

        // VP9 hardware decode is a supplemental decoder that has to be
        // registered before VideoToolbox will report it.
        VTRegisterSupplementalVideoDecoderIfAvailable(FourCC.vp9)

        return SystemProfile(
            architecture: isAppleSilicon ? .arm64 : .x86_64,
            isTranslated: translated,
            chipName: chip.trimmingCharacters(in: .whitespaces),
            modelIdentifier: sysctlString("hw.model") ?? "Mac",
            performanceCores: performance,
            totalCores: total,
            memoryGB: max(memory, 1),
            macOSVersion: osString,
            hardwareEncodesH264: encoders.contains(FourCC.h264),
            hardwareEncodesHEVC: encoders.contains(FourCC.hevc),
            hardwareDecodesHEVC: VTIsHardwareDecodeSupported(FourCC.hevc),
            hardwareDecodesVP9: VTIsHardwareDecodeSupported(FourCC.vp9),
            hardwareDecodesAV1: VTIsHardwareDecodeSupported(FourCC.av1)
        )
    }

    /// Codec types that have a hardware-accelerated VideoToolbox encoder.
    private static func hardwareEncoders() -> Set<CMVideoCodecType> {
        var listRef: CFArray?
        guard VTCopyVideoEncoderList(nil, &listRef) == noErr,
              let list = listRef as? [[String: Any]] else { return [] }

        var result = Set<CMVideoCodecType>()
        for encoder in list {
            let isHardware = encoder[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool ?? false
            guard isHardware,
                  let type = (encoder[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value
            else { continue }
            result.insert(type)
        }
        return result
    }

    /// Raw four-character codes, so the app does not depend on SDK constants
    /// that only exist on newer releases of macOS.
    private enum FourCC {
        static let h264: CMVideoCodecType = 0x61766331 // 'avc1'
        static let hevc: CMVideoCodecType = 0x68766331 // 'hvc1'
        static let vp9: CMVideoCodecType  = 0x76703039 // 'vp09'
        static let av1: CMVideoCodecType  = 0x61763031 // 'av01'
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            var small: Int32 = 0
            var smallSize = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &small, &smallSize, nil, 0) == 0 else { return nil }
            return Int(small)
        }
        return size == MemoryLayout<Int32>.size ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
