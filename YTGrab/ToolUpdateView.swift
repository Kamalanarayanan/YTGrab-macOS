import SwiftUI
import AppKit

@MainActor
private final class ToolUpdateModel: ObservableObject {
    @Published var versions = "Reading embedded tools…"
    @Published var status = "YTGrab includes everything required. No separate installation is needed."
    @Published var isBusy = false

    func load() {
        Task {
            do {
                versions = try await Task.detached { try ToolUpdateManager.versions().summary }.value
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func update() {
        isBusy = true
        status = "Checking official releases and verifying downloads…"
        Task {
            do {
                let result = try await Task.detached { try await ToolUpdateManager.update() }.value
                versions = result.after.summary
                status = result.changed
                    ? "Updated successfully. New downloads will use the updated tools."
                    : "Everything is already current."
            } catch {
                status = error.localizedDescription
            }
            isBusy = false
        }
    }
}

struct ToolUpdateView: View {
    @StateObject private var model = ToolUpdateModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Brand.accentFill)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Embedded Tools")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Brand.text)
                    Text("Self-contained and managed by YTGrab")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textMuted)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(model.versions)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Brand.text)
                    .textSelection(.enabled)
                Text(model.status)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Brand.raised))

            HStack {
                Button("Third-Party Notices") {
                    LicenseWindow.show()
                }
                .buttonStyle(.bordered)

                Spacer()

                if model.isBusy {
                    ProgressView().controlSize(.small)
                }

                Button("Check for Updates") {
                    model.update()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }
        }
        .padding(22)
        .frame(width: 500)
        .background(Brand.surface)
        .preferredColorScheme(.dark)
        .onAppear { model.load() }
    }
}

private struct LicenseView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Brand.text.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
        }
        .frame(width: 680, height: 520)
        .background(Brand.panel)
        .preferredColorScheme(.dark)
    }
}

enum ToolUpdateWindow {
    private static var controller: NSWindowController?

    @MainActor
    static func show() {
        if let controller {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        controller = makeWindow(title: "YTGrab Embedded Tools", root: ToolUpdateView())
        controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum LicenseWindow {
    private static var controller: NSWindowController?

    @MainActor
    static func show() {
        if let controller {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let names = [
            "Third-Party-Notices", "yt-dlp-License", "Deno-License",
            "FFmpeg-GPL-3.0", "FFmpeg-Build-README",
        ]
        let text = names.compactMap { name -> String? in
            guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
                  let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return contents
        }.joined(separator: "\n\n────────────────────────────────────────\n\n")

        controller = makeWindow(title: "Third-Party Notices", root: LicenseView(text: text))
        controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private func makeWindow<Content: View>(title: String, root: Content) -> NSWindowController {
    let hosting = NSHostingController(rootView: root)
    let window = NSWindow(contentViewController: hosting)
    window.title = title
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.backgroundColor = NSColor(Brand.surface)
    window.isReleasedWhenClosed = false
    window.center()
    return NSWindowController(window: window)
}
