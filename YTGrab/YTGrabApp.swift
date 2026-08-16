import SwiftUI
import AppKit

@MainActor
private final class AppLifecycle: NSObject, NSApplicationDelegate {
    private var didPlaceMainWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        placeMainWindow()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        placeMainWindow()
    }

    private func placeMainWindow(attempt: Int = 0) {
        guard !didPlaceMainWindow else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, !self.didPlaceMainWindow else { return }

            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
                if attempt < 20 {
                    self.placeMainWindow(attempt: attempt + 1)
                }
                return
            }

            window.setContentSize(NSSize(width: 720, height: 540))
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.didPlaceMainWindow = true
        }
    }
}

@main
struct YTGrabApp: App {

    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var appLifecycle

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 720, height: 540)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppInfo.name)") {
                    AboutWindow.show()
                }

                Button("Check for Tool Updates…") {
                    ToolUpdateWindow.show()
                }
            }

            CommandGroup(replacing: .newItem) { }

            CommandGroup(replacing: .help) {
                Button("Embedded Tools & Licenses") {
                    ToolUpdateWindow.show()
                }

                Divider()

                Button("Email \(AppInfo.studio)") {
                    if let url = URL(string: "mailto:\(AppInfo.contactEmail)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
