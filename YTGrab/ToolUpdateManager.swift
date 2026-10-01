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

enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case stable
    case nightly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stable:  return "Stable"
        case .nightly: return "Nightly (fastest YouTube fixes)"
        }
    }

    var repository: (owner: String, name: String) {
        switch self {
        case .stable:  return ("yt-dlp", "yt-dlp")
        case .nightly: return ("yt-dlp", "yt-dlp-nightly-builds")
        }
    }
}

/// Updates the fast-moving network-facing tools without touching the signed
/// app bundle. FFmpeg remains pinned to the tested app release because changing
/// encoders underneath the app can alter output behaviour.
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
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Reads versions by launching each tool. Cheap for FFmpeg and Deno, a
    /// second or two for yt-dlp.
    static func versions() throws -> ToolVersions {
        let tools = try ToolLocator.resolve()
        let ytdlp = try firstLine(tools.ytdlp, ["--version"])
        let deno = parseDenoVersion(try firstLine(tools.deno, ["--version"]))
        ToolLocator.recordVersion(ytdlp, for: "yt-dlp")
        ToolLocator.recordVersion(deno, for: "deno")
        return ToolVersions(
            ytdlp: ytdlp,
            ffmpeg: parseFFmpegVersion(try firstLine(tools.ffmpeg, ["-version"])),
            deno: deno
        )
    }

    /// How old the installed yt-dlp is, from its date-based version number.
    static func ytdlpAgeInDays() -> Int? {
        guard let version = ToolLocator.installedVersions()["yt-dlp"] else { return nil }
        let parts = version.split(separator: ".").prefix(3).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]; components.month = parts[1]; components.day = parts[2]
        guard let date = Calendar(identifier: .gregorian).date(from: components) else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day
    }

    static func update(channel: UpdateChannel = AppSettings.updateChannel) async throws -> ToolUpdateResult {
        let tools = try ToolLocator.resolve()
        let before = try versions()

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("YTGrab-Update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        // yt-dlp: universal executable, published with a SHA-256 digest.
        let repo = channel.repository
        let ytdlpRelease = try await release(owner: repo.owner, repository: repo.name)
        if normalized(ytdlpRelease.tag_name) != normalized(before.ytdlp) {
            let ytdlp = try spec(named: "yt-dlp_macos", in: ytdlpRelease)
            let newYtdlp = staging.appendingPathComponent("yt-dlp")
            try await download(ytdlp, to: newYtdlp)
            try prepareAndValidate(newYtdlp, arguments: ["--version"], expectedPrefix: normalized(ytdlpRelease.tag_name))
            try ToolLocator.install(newYtdlp, to: tools.ytdlp)
            ToolLocator.recordVersion(normalized(ytdlpRelease.tag_name), for: "yt-dlp")
        }

        // Deno: one archive per architecture.
        let denoRelease = try await release(owner: "denoland", repository: "deno")
        let denoVersion = normalized(denoRelease.tag_name)
        if ToolLocator.compareVersions(denoVersion, before.deno) == .orderedDescending {
            let assetName = SystemProfile.current.architecture == .arm64
                ? "deno-aarch64-apple-darwin.zip"
                : "deno-x86_64-apple-darwin.zip"
            let denoArchive = try spec(named: assetName, in: denoRelease)
            let denoZip = staging.appendingPathComponent("deno.zip")
            try await download(denoArchive, to: denoZip)
            let extractedDeno = staging.appendingPathComponent("deno")
            try extractDeno(from: denoZip, to: extractedDeno)
            try prepareAndValidate(extractedDeno, arguments: ["--version"], expectedPrefix: denoVersion)
            try ToolLocator.install(extractedDeno, to: tools.deno)
            ToolLocator.recordVersion(denoVersion, for: "deno")
        }

        return ToolUpdateResult(before: before, after: try versions())
    }

    /// Checks at most once a day, in the background, if the user allows it.
    /// YouTube changes often and a stale yt-dlp is the single most common
    /// reason downloads stop working, so this is on by default.
    static func updateIfDue() async -> ToolUpdateResult? {
        guard AppSettings.autoUpdateTools else { return nil }
        let last = AppSettings.lastToolCheck
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return nil }
        AppSettings.lastToolCheck = Date()
        return try? await update()
    }

    private static func normalized(_ tag: String) -> String {
        tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
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
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code == 403 || code == 429 {
                throw JobError.updateFailed("GitHub is rate-limiting update checks right now. Try again in an hour.")
            }
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

    /// Deno's official archive contains one file. ditto ships with every Mac
    /// and unpacks it without a shell.
    private static func extractDeno(from archive: URL, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent().appendingPathComponent("deno-unpacked")
        guard ToolLocator.runQuietly("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path]) else {
            throw JobError.updateFailed("The Deno archive could not be unpacked.")
        }
        let unpacked = directory.appendingPathComponent("deno")
        guard FileManager.default.fileExists(atPath: unpacked.path) else {
            throw JobError.updateFailed("The Deno archive did not contain the expected file.")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: unpacked, to: destination)
    }

    private static func prepareAndValidate(
        _ executable: URL,
        arguments: [String],
        expectedPrefix: String
    ) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        ToolLocator.removeQuarantine(executable)
        try signIfNeeded(executable)
        let output = try firstLine(executable, arguments)
        guard output.contains(expectedPrefix) || parseDenoVersion(output).contains(expectedPrefix) else {
            throw JobError.updateFailed("The downloaded tool reported an unexpected version.")
        }
    }

    /// Apple silicon refuses to run code without a valid signature. Upstream
    /// binaries are normally signed already (Deno with its Developer ID), so
    /// only an invalid or missing signature is replaced with a local ad-hoc
    /// one over the checksum-verified bytes.
    private static func signIfNeeded(_ executable: URL) throws {
        if ToolLocator.runQuietly("/usr/bin/codesign", ["--verify", executable.path]) { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--timestamp=none", executable.path]
        process.standardOutput = FileHandle.nullDevice
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

    private static func firstLine(_ executable: URL, _ arguments: [String]) throws -> String {
        let runner = ProcessRunner()
        let output = try runner.capture(executable, arguments, tag: executable.lastPathComponent, timeout: 60)
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
