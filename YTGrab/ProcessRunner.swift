import Foundation

/// Runs a child process, streams its output line by line, and can be
/// terminated mid-flight.
///
/// Marked `@unchecked Sendable` deliberately. Every piece of mutable state in
/// here is guarded by `lock`, so the type is safe to hand across threads even
/// though the compiler cannot prove it. Without this the runner cannot be
/// captured by the background job closure at all.
final class ProcessRunner: @unchecked Sendable {

    private let lock = NSLock()
    private var current: Process?
    private var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        let process = current
        lock.unlock()
        process?.terminate()
    }

    private func checkCancelled() throws {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled { throw JobError.cancelled }
    }

    /// Blocking. Call from a background queue.
    /// `onLine` fires for every line the tool prints.
    @discardableResult
    func stream(
        _ executable: URL,
        _ arguments: [String],
        tag: String,
        onLine: @escaping @Sendable (String) -> Void
    ) throws -> Int32 {
        try checkCancelled()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ToolLocator.childEnvironment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        lock.lock()
        current = process
        lock.unlock()

        try process.run()

        var buffer = Data()
        var lastLine = ""
        let handle = pipe.fileHandleForReading

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)

            // Split on \n and \r both. ffmpeg updates its progress line in
            // place with carriage returns, so newline-only splitting would
            // hold the whole run back until the process exits.
            while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                lastLine = trimmed
                onLine(trimmed)
            }
        }

        if !buffer.isEmpty, let tail = String(data: buffer, encoding: .utf8) {
            let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lastLine = trimmed
                onLine(trimmed)
            }
        }

        process.waitUntilExit()

        lock.lock()
        current = nil
        lock.unlock()

        try checkCancelled()

        if process.terminationStatus != 0 {
            throw JobError.processFailed(
                tool: tag,
                code: process.terminationStatus,
                detail: lastLine
            )
        }
        return process.terminationStatus
    }

    /// Runs a tool and hands back everything it printed to stdout.
    func capture(_ executable: URL, _ arguments: [String], tag: String) throws -> String {
        try checkCancelled()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ToolLocator.childEnvironment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        lock.lock()
        current = process
        lock.unlock()

        try process.run()

        // Read before waiting. A full format dump from yt-dlp is large enough
        // to fill the pipe buffer, and the child would block forever if we
        // waited on exit first.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        lock.lock()
        current = nil
        lock.unlock()

        try checkCancelled()

        if process.terminationStatus != 0 {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let lastLine = message.split(separator: "\n").last.map(String.init) ?? "failed"
            throw JobError.processFailed(tool: tag, code: process.terminationStatus, detail: lastLine)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
