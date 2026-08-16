import Foundation
import CryptoKit

struct ToolVersions: Sendable {
    let ytdlp: String
    let ffmpeg: String
    let deno: String

    var summary: String {
        "yt-dlp \(ytdlp) · FFmpeg \(ffmpeg) · Deno \(deno)"
    }
}

struct ToolUpdateResult: Sendable {
    let before: ToolVersions
    let after: ToolVersions
    var changed: Bool { before.ytdlp != after.ytdlp || before.deno != after.deno }
}

/// Updates the fast-moving network-facing tools without touching the signed
/// app bundle. FFmpeg remains pinned to the tested app release because changing
/// encoders underneath the app can alter output behavior.
enum ToolUpdateManager {

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let digest: String?
        }

        let tag_name: String
        let assets: [Asset]
    }

    private struct DownloadSpec {
        let url: URL
        let sha256: String
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static func versions() throws -> ToolVersions {
        let tools = try ToolLocator.resolve()
        return ToolVersions(
            ytdlp: try firstLine(tools.ytdlp, ["--version"]),
            ffmpeg: parseFFmpegVersion(try firstLine(tools.ffmpeg, ["-version"])),
            deno: parseDenoVersion(try firstLine(tools.deno, ["--version"]))
        )
    }

    static func update() async throws -> ToolUpdateResult {
        let tools = try ToolLocator.resolve()
        let before = try versions()

        let ytdlpRelease = try await release(owner: "yt-dlp", repository: "yt-dlp")
        let ytdlp = try spec(named: "yt-dlp_macos", in: ytdlpRelease)

        let denoRelease = try await release(owner: "denoland", repository: "deno")
        let denoArchive = try spec(named: "deno-aarch64-apple-darwin.zip", in: denoRelease)

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("YTGrab-Update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let newYtdlp = staging.appendingPathComponent("yt-dlp")
        try await download(ytdlp, to: newYtdlp)

        let denoZip = staging.appendingPathComponent("deno.zip")
        try await download(denoArchive, to: denoZip)
        let extractedDeno = staging.appendingPathComponent("deno")
        try extractDeno(from: denoZip, to: extractedDeno)

        try prepareAndValidate(newYtdlp, arguments: ["--version"], expectedPrefix: ytdlpRelease.tag_name)
        try prepareAndValidate(
            extractedDeno,
            arguments: ["--version"],
            expectedPrefix: denoRelease.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        )

        try replace(tools.ytdlp, with: newYtdlp)
        try replace(tools.deno, with: extractedDeno)

        return ToolUpdateResult(before: before, after: try versions())
    }

    private static func release(owner: String, repository: String) async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("YTGrab/\(AppInfo.shortVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        try requireSuccess(response)
        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw JobError.updateFailed("The release information was not understood.")
        }
    }

    private static func spec(named name: String, in release: GitHubRelease) throws -> DownloadSpec {
        guard let asset = release.assets.first(where: { $0.name == name }),
              let digest = asset.digest,
              digest.hasPrefix("sha256:") else {
            throw JobError.updateFailed("The \(name) release has no verified SHA-256 digest.")
        }
        return DownloadSpec(url: asset.browser_download_url, sha256: String(digest.dropFirst(7)))
    }

    private static func download(_ spec: DownloadSpec, to destination: URL) async throws {
        let (temporary, response) = try await session.download(from: spec.url)
        try requireSuccess(response)

        let digest = try sha256(of: temporary)
        guard digest.caseInsensitiveCompare(spec.sha256) == .orderedSame else {
            throw JobError.updateFailed("A downloaded file did not match its published checksum.")
        }
        try FileManager.default.copyItem(at: temporary, to: destination)
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw JobError.updateFailed("The update server returned HTTP \(code).")
        }
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Deno's official archive contains one file. Foundation has no public ZIP
    /// extraction API on macOS, so use the system unzip tool with fixed paths
    /// and no shell.
    private static func extractDeno(from archive: URL, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", archive.path, "deno", "-d", directory.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destination.path) else {
            throw JobError.updateFailed("The Deno archive could not be unpacked.")
        }
    }

    private static func prepareAndValidate(
        _ executable: URL,
        arguments: [String],
        expectedPrefix: String
    ) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try adHocSign(executable)
        let output = try firstLine(executable, arguments)
        guard output.contains(expectedPrefix) else {
            throw JobError.updateFailed("The downloaded tool reported an unexpected version.")
        }
    }

    /// Release archives do not preserve a usable macOS code signature in all
    /// cases. The checksum is verified first, then the exact verified bytes are
    /// signed locally so Gatekeeper and system media services accept them.
    private static func adHocSign(_ executable: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--timestamp=none", executable.path]
        process.standardOutput = Pipe()
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "codesign failed"
            throw JobError.updateFailed(detail)
        }
    }

    private static func replace(_ destination: URL, with source: URL) throws {
        let fm = FileManager.default
        let replacement = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).new")
        try? fm.removeItem(at: replacement)
        try fm.copyItem(at: source, to: replacement)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replacement.path)

        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: replacement)
        } else {
            try fm.moveItem(at: replacement, to: destination)
        }
    }

    private static func firstLine(_ executable: URL, _ arguments: [String]) throws -> String {
        let runner = ProcessRunner()
        let output = try runner.capture(executable, arguments, tag: executable.lastPathComponent)
        return output.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? "unknown"
    }

    private static func parseFFmpegVersion(_ line: String) -> String {
        let parts = line.split(separator: " ")
        guard let index = parts.firstIndex(of: "version"), parts.indices.contains(index + 1) else {
            return line
        }
        return String(parts[index + 1]).split(separator: "-").first.map(String.init) ?? line
    }

    private static func parseDenoVersion(_ line: String) -> String {
        let parts = line.split(separator: " ")
        return parts.count > 1 ? String(parts[1]) : line
    }
}
