import Foundation

/// Runs a child process, streams its output line by line, and can be
/// terminated mid-flight.
///
/// Marked `@unchecked Sendable` deliberately. Every piece of mutable state in
/// here is guarded by `lock`, so the type is safe to hand across threads even
/// though the compiler cannot prove it.
final class ProcessRunner: @unchecked Sendable {

    private let lock = NSLock()
    private var current: Process?
    private var isCancelled = false

    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return isCancelled
    }

    /// Asks the running tool to stop, then forces it after a grace period.
    /// yt-dlp normally exits on SIGTERM, but a stuck network read or an
    /// ffmpeg child can ignore it, and a cancelled job must not keep writing.
    func cancel() {
        lock.lock()
        isCancelled = true
        let process = current
        lock.unlock()

        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func checkCancelled() throws {
        if cancelled { throw JobError.cancelled }
    }

    private func makeProcess(_ executable: URL, _ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ToolLocator.childEnvironment
        process.currentDirectoryURL = ToolLocator.cacheDirectory
        process.standardInput = FileHandle.nullDevice
        return process
    }

    private func launch(_ process: Process, tag: String) throws {
        lock.lock()
        current = process
        lock.unlock()
        do {
            try process.run()
        } catch {
            lock.lock()
            current = nil
            lock.unlock()
            throw JobError.toolSetupFailed("\(tag) could not be started: \(error.localizedDescription)")
        }
    }

    private func finish(_ process: Process, tag: String, tail: [String]) throws {
        lock.lock()
        current = nil
        lock.unlock()

        try checkCancelled()

        if process.terminationReason == .uncaughtSignal {
            throw JobError.processKilled(tool: tag, signal: process.terminationStatus)
        }
        if process.terminationStatus != 0 {
            throw JobError.processFailed(tool: tag, code: process.terminationStatus, detail: Self.errorLine(in: tail))
        }
    }

    /// The most useful line to show when a tool fails. yt-dlp prints
    /// "ERROR: …" but often follows it with more output, so the last line on
    /// its own is frequently not the reason.
    static func errorLine(in lines: [String]) -> String {
        if let error = lines.last(where: { $0.hasPrefix("ERROR:") }) {
            return String(error.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces)
        }
        if let error = lines.last(where: { $0.localizedCaseInsensitiveContains("error") }) {
            return error
        }
        return lines.last ?? ""
    }

    /// Blocking. Call from a background queue.
    /// `onLine` fires for every line the tool prints on stdout or stderr.
    @discardableResult
    func stream(
        _ executable: URL,
        _ arguments: [String],
        tag: String,
        onLine: (String) -> Void
    ) throws -> Int32 {
        try checkCancelled()

        let process = makeProcess(executable, arguments)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try launch(process, tag: tag)

        var buffer = Data()
        var tail: [String] = []
        let handle = pipe.fileHandleForReading

        func emit(_ data: Data) {
            guard let line = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else { return }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            tail.append(trimmed)
            if tail.count > 40 { tail.removeFirst(tail.count - 40) }
            onLine(trimmed)
        }

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)

            // Split on \n and \r both. ffmpeg and yt-dlp update progress in
            // place with carriage returns.
            while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                emit(Data(lineData))
            }
        }
        if !buffer.isEmpty { emit(buffer) }

        process.waitUntilExit()
        try finish(process, tag: tag, tail: tail)
        return process.terminationStatus
    }

    private final class Box: @unchecked Sendable {
        var data = Data()
        var timedOut = false
    }

    /// Runs a tool and hands back everything it printed to stdout.
    ///
    /// stdout and stderr are drained at the same time. Reading one to the end
    /// before touching the other deadlocks as soon as the other fills its
    /// 64 KB pipe buffer, which a verbose yt-dlp run easily does.
    func capture(_ executable: URL, _ arguments: [String], tag: String, timeout: TimeInterval? = nil) throws -> String {
        try checkCancelled()

        let process = makeProcess(executable, arguments)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try launch(process, tag: tag)

        let stdout = Box()
        let stderr = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdout.data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderr.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        var watchdog: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem {
                guard process.isRunning else { return }
                stdout.timedOut = true
                process.terminate()
            }
            watchdog = item
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        }

        group.wait()
        process.waitUntilExit()
        watchdog?.cancel()

        if stdout.timedOut && !cancelled {
            lock.lock(); current = nil; lock.unlock()
            throw JobError.timedOut(tag)
        }

        let message = String(data: stderr.data, encoding: .utf8) ?? ""
        let tail = message
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        try finish(process, tag: tag, tail: Array(tail.suffix(40)))

        return String(data: stdout.data, encoding: .utf8) ?? ""
    }
}
