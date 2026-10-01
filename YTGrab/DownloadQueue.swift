import Foundation
import AppKit
import UserNotifications

@MainActor
final class DownloadJob: ObservableObject, Identifiable {

    enum State: Equatable {
        case waiting
        case running
        case finished(URL)
        case failed(FailureAdvice)
        case cancelled
    }

    let id = UUID()
    @Published var request: JobRequest
    let thumbnail: URL?

    @Published var state: State = .waiting
    @Published var progress: JobReporter.Progress?
    @Published var log: [String] = []
    @Published var notice: String?

    fileprivate var runner: ProcessRunner?
    fileprivate var autoRepaired = false
    fileprivate var autoUpdated = false

    init(request: JobRequest, thumbnail: URL?) {
        self.request = request
        self.thumbnail = thumbnail
    }

    var title: String { request.title }

    var isActive: Bool {
        switch state {
        case .waiting, .running: return true
        default:                 return false
        }
    }

    var outputURL: URL? {
        if case .finished(let url) = state { return url }
        return nil
    }

    fileprivate func appendLog(_ line: String) {
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}

/// Runs downloads one or more at a time and keeps the Mac awake while it
/// does. Shared, so jobs keep running when the window is closed.
@MainActor
final class DownloadQueue: ObservableObject {

    static let shared = DownloadQueue()

    @Published private(set) var jobs: [DownloadJob] = []
    @Published private(set) var toolStatus: String?

    private var activity: NSObjectProtocol?
    private var updateTask: Task<Bool, Never>?

    var activeCount: Int { jobs.filter(\.isActive).count }
    var hasActiveJobs: Bool { activeCount > 0 }
    var hasFinishedJobs: Bool { jobs.contains { !$0.isActive } }

    // MARK: - Queue management

    func enqueue(_ items: [(JobRequest, URL?)]) {
        guard !items.isEmpty else { return }
        for (request, thumbnail) in items {
            jobs.insert(DownloadJob(request: request, thumbnail: thumbnail), at: 0)
        }
        if AppSettings.notifyWhenDone {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        pump()
    }

    func cancel(_ job: DownloadJob) {
        switch job.state {
        case .waiting:
            job.state = .cancelled
            refresh()
        case .running:
            job.runner?.cancel()
        default:
            break
        }
    }

    func cancelAll() {
        for job in jobs where job.isActive { cancel(job) }
    }

    func retry(_ job: DownloadJob) {
        guard !job.isActive else { return }
        // Pick up a fix made in Settings since the failure, such as
        // turning on browser cookies.
        job.request.cookies = AppSettings.cookies
        job.request.forceIPv4 = AppSettings.forceIPv4
        job.state = .waiting
        job.progress = nil
        job.notice = nil
        pump()
    }

    func remove(_ job: DownloadJob) {
        if job.isActive { cancel(job) }
        jobs.removeAll { $0.id == job.id }
        refresh()
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
        refresh()
    }

    /// Starts waiting jobs, oldest first, up to the concurrency limit.
    func pump() {
        let limit = AppSettings.maxConcurrentJobs
        var running = jobs.filter { $0.state == .running }.count
        for job in jobs.reversed() where job.state == .waiting && running < limit {
            start(job)
            running += 1
        }
        refresh()
    }

    // MARK: - Running one job

    private func start(_ job: DownloadJob) {
        job.state = .running
        job.log.removeAll()
        job.progress = nil

        let runner = ProcessRunner()
        job.runner = runner

        let reporter = JobReporter { event in
            DispatchQueue.main.async {
                switch event {
                case .progress(let progress): job.progress = progress
                case .log(let line):          job.appendLog(line)
                case .title(let title):       job.request.title = title
                }
            }
        }

        let request = job.request
        DispatchQueue.global(qos: .userInitiated).async {
            let pipeline = JobPipeline(request: request, runner: runner, reporter: reporter)
            let result = Result { try pipeline.run() }
            DispatchQueue.main.async {
                self.complete(job, result: result, cancelled: runner.cancelled)
            }
        }
    }

    private func complete(_ job: DownloadJob, result: Result<URL, Error>, cancelled: Bool) {
        job.runner = nil

        switch result {
        case .success(let url):
            job.state = .finished(url)
            job.progress = nil
            notifyFinished(job, url: url)
            if AppSettings.revealWhenDone {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }

        case .failure(let error):
            if cancelled {
                job.state = .cancelled
                job.progress = nil
                break
            }
            let advice = FailureAdvice.explain(error, log: job.log)
            job.appendLog("Error: \(error.localizedDescription)")

            // Two failures have a fix the app can apply on its own, once.
            if advice.action == .repairTools && !job.autoRepaired {
                job.autoRepaired = true
                job.notice = "Repairing built-in tools and trying again …"
                job.state = .waiting
                DispatchQueue.global(qos: .userInitiated).async {
                    try? ToolLocator.reinstallFromBundle()
                    DispatchQueue.main.async { self.pump() }
                }
                return
            }
            if advice.action == .updateTools && !job.autoUpdated {
                job.autoUpdated = true
                job.notice = "Updating the download engine and trying again …"
                job.state = .waiting
                Task {
                    let changed = await self.updateTools()
                    if changed {
                        self.pump()
                    } else {
                        job.notice = nil
                        job.state = .failed(advice)
                        self.refresh()
                    }
                }
                refresh()
                return
            }

            job.state = .failed(advice)
            job.progress = nil
            notifyFailed(job, advice: advice)
        }
        pump()
    }

    // MARK: - Tool updates

    /// Shared, so five failing jobs trigger one update rather than five.
    @discardableResult
    func updateTools() async -> Bool {
        if let updateTask { return await updateTask.value }
        toolStatus = "Updating download engine …"
        let task = Task<Bool, Never> {
            let result = try? await Task.detached(priority: .userInitiated) {
                try await ToolUpdateManager.update()
            }.value
            return result?.changed ?? false
        }
        updateTask = task
        let changed = await task.value
        updateTask = nil
        toolStatus = nil
        return changed
    }

    // MARK: - Side effects

    private func refresh() {
        objectWillChange.send()
        let active = activeCount
        NSApp?.dockTile.badgeLabel = active > 0 ? "\(active)" : nil

        // Keeps App Nap from throttling a background download and the Mac
        // from sleeping halfway through a long conversion.
        if active > 0 && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Downloading and converting video"
            )
        } else if active == 0, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }

    private func notifyFinished(_ job: DownloadJob, url: URL) {
        guard AppSettings.notifyWhenDone, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "Download complete"
        content.body = url.lastPathComponent
        content.sound = .default
        post(content)
    }

    private func notifyFailed(_ job: DownloadJob, advice: FailureAdvice) {
        guard AppSettings.notifyWhenDone, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = advice.title
        content.body = job.title
        post(content)
    }

    private func post(_ content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
