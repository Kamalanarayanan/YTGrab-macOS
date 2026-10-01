import SwiftUI
import AppKit

// MARK: - About

/// The CRIT Studio panel: who made the app and how to reach the studio.
struct AboutView: View {

    private struct Contact: Identifiable {
        let label: String
        let email: String
        var id: String { email }
    }

    private let contacts = [
        Contact(label: "Support", email: AppInfo.supportEmail),
        Contact(label: "Say hello", email: AppInfo.helloEmail),
        Contact(label: "Licensing", email: AppInfo.licensingEmail),
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image("CRITLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 76, height: 76)
                    .shadow(color: Brand.accentHalo, radius: 16, y: 3)
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)

                Text(AppInfo.studio)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(Brand.text)

                Text("Designed and built by \(AppInfo.author)")
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.textMuted)
                    .multilineTextAlignment(.center)

                Text("\(AppInfo.name) \(AppInfo.shortVersion) (\(AppInfo.build))")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Brand.textFaint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Brand.raised))
                    .padding(.top, 2)
            }
            .padding(.top, 26)
            .padding(.bottom, 20)

            Rectangle().fill(Brand.rule).frame(height: 1)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                ForEach(contacts) { contact in
                    GridRow {
                        Text(contact.label)
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textMuted)
                            .gridColumnAlignment(.trailing)
                        Link(contact.email, destination: URL(string: "mailto:\(contact.email)")!)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Brand.accentBright)
                            .help("Email \(contact.email)")
                    }
                }
            }
            .padding(.vertical, 18)

            Rectangle().fill(Brand.rule).frame(height: 1)

            HStack(spacing: 5) {
                Link(AppInfo.websiteName, destination: AppInfo.website)
                    .foregroundStyle(Brand.text.opacity(0.85))
                Text("·")
                Text(AppInfo.copyright)
            }
            .font(.system(size: 11))
            .foregroundStyle(Brand.textMuted)
            .padding(.vertical, 14)
        }
        .frame(width: 340)
        .background(Brand.surface)
        .preferredColorScheme(.dark)
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
