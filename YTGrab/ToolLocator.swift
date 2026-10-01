import Foundation
import Darwin

/// Resolves the private toolchain shipped inside the app.
///
/// The signed bundle is never modified. The bundled tools are installed to
/// Application Support, which gives yt-dlp and Deno a writable, per-user
/// update location while keeping a known-good factory copy in the app.
///
/// Installing does three things a plain file copy did not:
///
/// * **Removes the quarantine flag.** Copies of files from a downloaded DMG
///   inherit `com.apple.quarantine`. Gatekeeper then blocks or kills the
///   helper the first time the app launches it, which looks to the user like
///   "the download never starts". The user already approved the app itself.
/// * **Keeps only this Mac's architecture.** The app bundle is universal; the
///   installed copies are thinned to the native slice, which saves several
///   hundred megabytes and guarantees nothing runs under Rosetta.
/// * **Refreshes after an app update.** Without this, someone who installed
///   an early version kept its yt-dlp forever, long after YouTube broke it.
enum ToolLocator {

    static let toolNames = ["yt-dlp", "ffmpeg", "ffprobe", "deno"]

    /// Tools whose newer managed copy (from the in-app updater) should be
    /// kept over an older bundled one.
    private static let updatableTools: Set<String> = ["yt-dlp", "deno"]

    private static let installLock = NSLock()

    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.ytgrab.app", isDirectory: true)
    }

    static var supportDirectory: URL {
        applicationSupport.appendingPathComponent("Tools", isDirectory: true)
    }

    /// yt-dlp's player cache and the probe dumps live here.
    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.ytgrab.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var bundleToolsDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Tools", isDirectory: true)
    }

    private static var manifestURL: URL {
        supportDirectory.appendingPathComponent("manifest.json")
    }

    /// PATH handed to every child process. yt-dlp must be able to discover the
    /// managed ffmpeg and Deno copies while merging streams and solving
    /// YouTube's JavaScript challenges, and must never pick up a different
    /// ffmpeg from Homebrew first.
    static var childPath: String {
        [supportDirectory.path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
    }

    static var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = childPath
        env["NO_COLOR"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        // Deno would otherwise try to write its cache into the home folder.
        env["DENO_DIR"] = cacheDirectory.appendingPathComponent("deno", isDirectory: true).path
        env["DENO_NO_UPDATE_CHECK"] = "1"
        // A user's own yt-dlp setup must not leak into the app.
        env.removeValue(forKey: "YTDLP_CONFIG")
        env.removeValue(forKey: "PYTHONPATH")
        env.removeValue(forKey: "PYTHONHOME")
        return env
    }

    struct Toolchain: Sendable {
        let ytdlp: URL
        let ffmpeg: URL
        let ffprobe: URL
        let deno: URL
    }

    // MARK: - Manifest

    /// What is installed in Application Support and which app build put it
    /// there.
    struct Manifest: Codable {
        var appBuild: String
        var architecture: String
        var versions: [String: String]
    }

    static func readManifest() -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    static func writeManifest(_ manifest: Manifest) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    /// Records a version after the updater replaced a tool.
    static func recordVersion(_ version: String, for tool: String) {
        installLock.lock(); defer { installLock.unlock() }
        var manifest = readManifest() ?? Manifest(appBuild: currentBuild, architecture: architecture, versions: [:])
        manifest.versions[tool] = version
        writeManifest(manifest)
    }

    static func installedVersions() -> [String: String] {
        readManifest()?.versions ?? [:]
    }

    /// Versions of the copies inside the app bundle, written by
    /// Scripts/fetch-tools.sh at build time.
    static func bundledVersions() -> [String: String] {
        guard let url = bundleToolsDirectory?.appendingPathComponent("versions.json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object
    }

    private static var currentBuild: String { "\(AppInfo.shortVersion) (\(AppInfo.build))" }
    private static var architecture: String { SystemProfile.current.architecture.sliceName }

    // MARK: - Resolve

    static func resolve() throws -> Toolchain {
        try installBundledToolsIfNeeded()

        var missing: [String] = []
        func executable(_ name: String) -> URL? {
            let candidate = supportDirectory.appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
                missing.append(name)
                return nil
            }
            return candidate
        }

        let ytdlp = executable("yt-dlp")
        let ffmpeg = executable("ffmpeg")
        let ffprobe = executable("ffprobe")
        let deno = executable("deno")

        guard let ytdlp, let ffmpeg, let ffprobe, let deno, missing.isEmpty else {
            throw JobError.missingTools(missing)
        }
        return Toolchain(ytdlp: ytdlp, ffmpeg: ffmpeg, ffprobe: ffprobe, deno: deno)
    }

    /// Deletes the managed copies and installs fresh ones from the app. Used
    /// by Repair Tools and as the fix for a helper macOS refused to run.
    static func reinstallFromBundle() throws {
        installLock.lock()
        try? FileManager.default.removeItem(at: supportDirectory)
        installLock.unlock()
        try installBundledToolsIfNeeded()
    }

    private static func installBundledToolsIfNeeded() throws {
        installLock.lock(); defer { installLock.unlock() }

        let fm = FileManager.default
        let manifest = readManifest()
        let sameBuild = manifest?.appBuild == currentBuild && manifest?.architecture == architecture
        let allPresent = toolNames.allSatisfy {
            fm.isExecutableFile(atPath: supportDirectory.appendingPathComponent($0).path)
        }
        if sameBuild && allPresent { return }

        guard let sourceDirectory = bundleToolsDirectory else {
            throw JobError.toolSetupFailed("The app's embedded tools folder is missing.")
        }

        let bundled = bundledVersions()
        var versions = (manifest?.architecture == architecture ? manifest?.versions : nil) ?? [:]

        do {
            try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

            for name in toolNames {
                let source = sourceDirectory.appendingPathComponent(name)
                let destination = supportDirectory.appendingPathComponent(name)
                guard fm.fileExists(atPath: source.path) else {
                    throw JobError.toolSetupFailed("The embedded \(name) tool is missing from the app.")
                }

                let present = fm.isExecutableFile(atPath: destination.path) && manifest?.architecture == architecture
                if present && updatableTools.contains(name),
                   let installed = versions[name], let shipped = bundled[name],
                   compareVersions(installed, shipped) != .orderedAscending {
                    // The updater already installed something at least as new.
                    continue
                }

                try install(source, to: destination)
                if let shipped = bundled[name] { versions[name] = shipped }
            }
        } catch let error as JobError {
            throw error
        } catch {
            throw JobError.toolSetupFailed(error.localizedDescription)
        }

        writeManifest(Manifest(appBuild: currentBuild, architecture: architecture, versions: versions))
    }

    // MARK: - Installing one executable

    /// Copies an executable into place: thinned to this Mac's architecture,
    /// without quarantine, executable, and swapped in atomically so a job
    /// that is starting never sees half a file.
    static func install(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let arch = SystemProfile.current.architecture
        let slices = MachO.architectures(of: source)

        if !slices.isEmpty && !slices.contains(arch.sliceName) {
            throw JobError.unsupportedArchitecture(
                "\(source.lastPathComponent) in this copy of YTGrab is built for \(slices.sorted().joined(separator: ", ")) only, "
                + "but this Mac is \(arch.displayName). Download the universal build of YTGrab."
            )
        }

        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).installing")
        try? fm.removeItem(at: staging)

        var copied = false
        if slices.count > 1 {
            // ditto thins a universal binary and can drop quarantine in one go.
            copied = runQuietly("/usr/bin/ditto", ["--noqtn", "--arch", arch.sliceName, source.path, staging.path])
                && fm.fileExists(atPath: staging.path)
        }
        if !copied {
            try? fm.removeItem(at: staging)
            try fm.copyItem(at: source, to: staging)
        }

        removeQuarantine(staging)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)

        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
        removeQuarantine(destination)
    }

    static func removeQuarantine(_ url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return removexattr(path, "com.apple.quarantine", 0)
        }
    }

    @discardableResult
    static func runQuietly(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationReason == .exit && process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Versions

    /// Compares "2026.08.19", "2026.08.19.232816" or "2.9.7" numerically.
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func parts(_ value: String) -> [Int] {
            value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        }
        let a = parts(lhs), b = parts(rhs)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

// MARK: - Mach-O header

/// Reads which CPU architectures an executable contains, without needing
/// `lipo` (which is only installed with Xcode).
enum MachO {
    private static let cpuTypeX86_64: UInt32 = 0x0100_0007
    private static let cpuTypeARM64: UInt32 = 0x0100_000C

    static func architectures(of url: URL) -> Set<String> {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096), header.count >= 8 else { return [] }

        func uint32(_ offset: Int, bigEndian: Bool) -> UInt32 {
            guard offset + 4 <= header.count else { return 0 }
            let bytes = header[header.startIndex + offset ..< header.startIndex + offset + 4]
            let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return bigEndian ? value : value.byteSwapped
        }

        func name(_ cpu: UInt32) -> String? {
            switch cpu {
            case cpuTypeARM64:  return "arm64"
            case cpuTypeX86_64: return "x86_64"
            default:            return nil
            }
        }

        let magic = uint32(0, bigEndian: true)
        switch magic {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            // Universal: big-endian fat header, 20 or 32 bytes per slice.
            let count = Int(uint32(4, bigEndian: true))
            let stride = magic == 0xCAFE_BABF ? 32 : 20
            guard count > 0 && count < 16 else { return [] }
            var result = Set<String>()
            for index in 0..<count {
                if let arch = name(uint32(8 + index * stride, bigEndian: true)) { result.insert(arch) }
            }
            return result
        case 0xCFFA_EDFE:
            // Thin 64-bit, little-endian on disk.
            return name(uint32(4, bigEndian: false)).map { [$0] } ?? []
        default:
            return []
        }
    }
}
