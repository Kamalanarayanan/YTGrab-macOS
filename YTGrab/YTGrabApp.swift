import SwiftUI
import AppKit

@MainActor
private final class AppLifecycle: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install (and thin) the built-in tools while the user is still
        // pasting a link, so the first probe does not pay for it.
        DispatchQueue.global(qos: .utility).async {
            _ = try? ToolLocator.resolve()
            LinkInspector.purgeOldProbes()
        }
        checkForToolUpdates()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        checkForToolUpdates()
    }

    /// Downloads keep running with the window closed; the Dock icon brings
    /// it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !DownloadQueue.shared.hasActiveJobs
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let queue = DownloadQueue.shared
        guard queue.hasActiveJobs else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Downloads are still in progress"
        alert.informativeText = "Quitting stops \(queue.activeCount == 1 ? "the download" : "all \(queue.activeCount) downloads"). Unfinished files are discarded."
        alert.addButton(withTitle: "Keep Downloading")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }

        queue.cancelAll()
        // Give the tools a moment to exit cleanly before the app goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func checkForToolUpdates() {
        guard !DownloadQueue.shared.hasActiveJobs else { return }
        Task.detached(priority: .background) {
            _ = await ToolUpdateManager.updateIfDue()
        }
    }
}

@main
struct YTGrabApp: App {

    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var appLifecycle

    init() {
        AppSettings.registerDefaults()
    }

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            ContentView()
        }
        .defaultSize(width: 820, height: 720)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppInfo.name)") {
                    AboutWindow.show()
                }
                Button("Check for Tool Updates…") {
                    SettingsWindow.show(.tools)
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    SettingsWindow.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(replacing: .newItem) {
                Button("Paste Link") {
                    NotificationCenter.default.post(name: .ytgrabPasteLink, object: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Button("Enter Link") {
                    NotificationCenter.default.post(name: .ytgrabFocusLink, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
            }

            CommandGroup(replacing: .help) {
                Button("Troubleshooting Guide") {
                    if let url = URL(string: AppInfo.troubleshootingURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Embedded Tools & Licenses") {
                    LicenseWindow.show()
                }

                Divider()

                Button("Contact Support") {
                    if let url = URL(string: "mailto:\(AppInfo.supportEmail)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("\(AppInfo.studio) Website") {
                    NSWorkspace.shared.open(AppInfo.website)
                }
            }
        }
    }
}
