import Foundation

/// Resolves the private toolchain shipped inside the app.
///
/// The signed bundle is never modified. On first launch the bundled tools are
/// copied to Application Support, which gives yt-dlp and Deno a writable,
/// per-user update location while preserving a known-good factory fallback.
enum ToolLocator {

    private static let toolNames = ["yt-dlp", "ffmpeg", "ffprobe", "deno"]

    static var supportDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser

        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.ytgrab.app", isDirectory: true)
            .appendingPathComponent("Tools", isDirectory: true)
    }

    private static var bundleToolsDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Tools", isDirectory: true)
    }

    /// PATH handed to every child process. yt-dlp must be able to discover the
    /// managed ffmpeg and Deno copies while merging streams and solving current
    /// YouTube JavaScript challenges.
    static var childPath: String {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return [supportDirectory.path, "/usr/bin", "/bin", inherited]
            .filter { !$0.isEmpty }
            .joined(separator: ":")
    }

    static var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = childPath
        env["NO_COLOR"] = "1"
        return env
    }

    struct Toolchain: Sendable {
        let ytdlp: URL
        let ffmpeg: URL
        let ffprobe: URL
        let deno: URL
    }

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

    /// Copies only absent tools. Updates in Application Support are retained
    /// across app updates, while removing the support folder restores the
    /// bundled versions on the next launch.
    private static func installBundledToolsIfNeeded() throws {
        let fm = FileManager.default
        guard let sourceDirectory = bundleToolsDirectory else {
            throw JobError.toolSetupFailed("The app's embedded tools folder is missing.")
        }

        do {
            try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            for name in toolNames {
                let destination = supportDirectory.appendingPathComponent(name)
                guard !fm.fileExists(atPath: destination.path) else { continue }

                let source = sourceDirectory.appendingPathComponent(name)
                guard fm.fileExists(atPath: source.path) else {
                    throw JobError.toolSetupFailed("The embedded \(name) tool is missing.")
                }

                try fm.copyItem(at: source, to: destination)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            }
        } catch let error as JobError {
            throw error
        } catch {
            throw JobError.toolSetupFailed(error.localizedDescription)
        }
    }
}
