import SwiftUI
import AppKit

/// Third-party notices for everything embedded in the app.
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
        var sections = names.compactMap { name -> String? in
            guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
                  let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return contents
        }
        // The build manifest written by Scripts/fetch-tools.sh: exact
        // versions, sources and checksums of the embedded binaries.
        if let manifest = Bundle.main.resourceURL?.appendingPathComponent("Tools/README.txt"),
           let contents = try? String(contentsOf: manifest, encoding: .utf8) {
            sections.append(contents)
        }
        let text = sections.joined(separator: "\n\n────────────────────────────────────────\n\n")

        let hosting = NSHostingController(rootView: LicenseView(text: text))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Third-Party Notices"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.backgroundColor = NSColor(Brand.surface)
        window.isReleasedWhenClosed = false
        window.center()
        let wc = NSWindowController(window: window)
        controller = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
