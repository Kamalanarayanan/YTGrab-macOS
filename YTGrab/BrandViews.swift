import SwiftUI
import AppKit

// MARK: - About

/// Keeps the studio mark and ownership details in one compact, dedicated panel.
struct AboutView: View {

    var body: some View {
        VStack(spacing: 8) {
            studioMark
                .frame(width: 82, height: 82)
                .shadow(color: Brand.accentHalo, radius: 16, y: 3)
                .padding(.top, 18)

            Text(AppInfo.name)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Brand.text)

            Text("A \(AppInfo.studio) product")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .textCase(.uppercase)
                .foregroundStyle(Brand.textMuted)

            Text("Version \(AppInfo.shortVersion) (\(AppInfo.build))")
                .font(.system(size: 11))
                .foregroundStyle(Brand.text.opacity(0.85))

            Link(AppInfo.contactEmail, destination: URL(string: "mailto:\(AppInfo.contactEmail)")!)
                .font(.system(size: 11))
                .foregroundStyle(Brand.accentBright)

            Text(AppInfo.copyright)
                .font(.system(size: 10))
                .foregroundStyle(Brand.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .frame(width: 320)
        .background(Brand.surface)
        .preferredColorScheme(.dark)
    }

    private var studioMark: some View {
        Group {
            Image("CRITLogo")
                .resizable()
                .interpolation(.high)
        }
    }
}

// MARK: - Window plumbing

/// A plain NSWindow rather than a SwiftUI Window scene, so the About panel
/// behaves like every other About panel: floats, no tab bar, not restored on
/// relaunch.
enum AboutWindow {

    private static var controller: NSWindowController?

    static func show() {
        if let controller {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: AboutView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "About \(AppInfo.name)"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(Brand.surface)
        window.isReleasedWhenClosed = false
        window.center()

        let wc = NSWindowController(window: window)
        controller = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#Preview("About") {
    AboutView()
}
