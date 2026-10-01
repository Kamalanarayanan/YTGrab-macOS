import SwiftUI
import AppKit

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, youtube, tools, mac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .youtube: return "YouTube Access"
        case .tools:   return "Download Engine"
        case .mac:     return "This Mac"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .youtube: return "person.badge.key"
        case .tools:   return "shippingbox"
        case .mac:     return "cpu"
        }
    }
}

@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject private var router = SettingsRouter.shared

    var body: some View {
        TabView(selection: $router.tab) {
            GeneralPane()
                .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.symbol) }
                .tag(SettingsTab.general)
            YouTubePane()
                .tabItem { Label(SettingsTab.youtube.title, systemImage: SettingsTab.youtube.symbol) }
                .tag(SettingsTab.youtube)
            ToolsPane()
                .tabItem { Label(SettingsTab.tools.title, systemImage: SettingsTab.tools.symbol) }
                .tag(SettingsTab.tools)
            MacPane()
                .tabItem { Label(SettingsTab.mac.title, systemImage: SettingsTab.mac.symbol) }
                .tag(SettingsTab.mac)
        }
        .frame(width: 560)
        .padding(20)
        .tint(Brand.accent)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @AppStorage(AppSettings.Key.outputDirectory) private var storedDirectory = ""
    @AppStorage(AppSettings.Key.maxConcurrentJobs) private var maxJobs = 1
    @AppStorage(AppSettings.Key.notifyWhenDone) private var notify = true
    @AppStorage(AppSettings.Key.revealWhenDone) private var reveal = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Save downloads to") {
                    HStack {
                        Text(displayPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose …") {
                            if let folder = AppActions.chooseFolder() { storedDirectory = folder.path }
                        }
                    }
                }
                Stepper(value: $maxJobs, in: 1...4) {
                    LabeledContent("Downloads at a time", value: "\(maxJobs)")
                }
                Text("Recommended for this Mac: \(SystemProfile.current.recommendedConcurrentJobs). More than that makes each conversion slower.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Notify me when a download finishes in the background", isOn: $notify)
                Toggle("Show each finished file in Finder", isOn: $reveal)
            }
        }
        .formStyle(.grouped)
    }

    private var displayPath: String {
        let path = storedDirectory.isEmpty ? AppSettings.defaultOutputDirectory.path : storedDirectory
        return (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - YouTube access

private struct YouTubePane: View {
    @AppStorage(AppSettings.Key.cookies) private var cookiesRaw = CookieBrowser.none.rawValue
    @AppStorage(AppSettings.Key.forceIPv4) private var forceIPv4 = false

    var body: some View {
        Form {
            Section {
                Picker("Use sign-in from", selection: $cookiesRaw) {
                    ForEach(CookieBrowser.allCases) { browser in
                        Text(browser.title).tag(browser.rawValue)
                    }
                }
                Text("Turn this on if YouTube says “Sign in to confirm you’re not a bot”, or for age-restricted and members-only videos. YTGrab reads that browser’s YouTube cookies for each download; nothing is stored or sent anywhere else.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if cookiesRaw == CookieBrowser.safari.rawValue {
                    Text("Safari keeps its cookies in a protected folder. Give YTGrab Full Disk Access in System Settings › Privacy & Security for this to work.")
                        .font(.caption)
                        .foregroundStyle(Brand.warn)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy & Security") {
                        AppActions.perform(.openPrivacySettings) {}
                    }
                } else if cookiesRaw != CookieBrowser.none.rawValue {
                    Text("macOS may ask once for permission to read the browser’s keychain entry. Choose Always Allow.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Browser sign-in")
            }

            Section {
                Toggle("Force IPv4", isOn: $forceIPv4)
                Text("Helps on networks where YouTube blocks or throttles IPv6.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Network")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Download engine

@MainActor
private final class ToolsModel: ObservableObject {
    @Published var versions = "Reading built-in tools …"
    @Published var status = ""
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
        status = "Checking official releases and verifying downloads …"
        Task {
            do {
                let result = try await Task.detached { try await ToolUpdateManager.update() }.value
                versions = result.after.summary
                status = result.changed
                    ? "Updated. New downloads use the new version."
                    : "Everything is already up to date."
                AppSettings.lastToolCheck = Date()
            } catch {
                status = error.localizedDescription
            }
            isBusy = false
        }
    }

    func repair() {
        isBusy = true
        status = "Reinstalling built-in tools from the app …"
        Task {
            do {
                try await Task.detached { try ToolLocator.reinstallFromBundle() }.value
                status = "Repaired. If downloads still fail, run Check for Updates."
                load()
            } catch {
                status = error.localizedDescription
            }
            isBusy = false
        }
    }
}

private struct ToolsPane: View {
    @StateObject private var model = ToolsModel()
    @AppStorage(AppSettings.Key.autoUpdateTools) private var autoUpdate = true
    @AppStorage(AppSettings.Key.updateChannel) private var channelRaw = UpdateChannel.stable.rawValue

    var body: some View {
        Form {
            Section {
                Text(model.versions)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                if !model.status.isEmpty {
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Check for Updates") { model.update() }
                        .disabled(model.isBusy)
                    Button("Repair Tools") { model.repair() }
                        .disabled(model.isBusy)
                    Spacer()
                    if model.isBusy { ProgressView().controlSize(.small) }
                }
            } header: {
                Text("Built-in tools")
            } footer: {
                Text("Everything YTGrab needs is inside the app. Nothing else to install.")
            }

            Section {
                Toggle("Keep the download engine up to date automatically", isOn: $autoUpdate)
                Picker("Update channel", selection: $channelRaw) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.title).tag(channel.rawValue)
                    }
                }
                Text("YouTube changes its site often. A current yt-dlp is the most important thing for downloads to keep working. Updates come from the official GitHub releases and are checked against their published SHA-256 before use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Updates")
            }

            Section {
                Button("Third-Party Notices …") { LicenseWindow.show() }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.load() }
    }
}

// MARK: - This Mac

private struct MacPane: View {
    private let profile = SystemProfile.current

    var body: some View {
        Form {
            Section {
                LabeledContent("Processor", value: profile.chipName)
                LabeledContent("Architecture", value: profile.architecture.displayName + (profile.isTranslated ? " (app running under Rosetta)" : ""))
                LabeledContent("Cores", value: profile.performanceCores == profile.totalCores
                               ? "\(profile.totalCores)"
                               : "\(profile.totalCores) (\(profile.performanceCores) performance)")
                LabeledContent("Memory", value: "\(profile.memoryGB) GB")
                LabeledContent("System", value: profile.macOSVersion)
            } header: {
                Text("Hardware")
            }

            Section {
                capability("H.264 hardware encoder", profile.hardwareEncodesH264)
                capability("H.265 hardware encoder", profile.hardwareEncodesHEVC)
                capability("VP9 hardware decoder", profile.hardwareDecodesVP9)
                capability("AV1 hardware decoder", profile.hardwareDecodesAV1)
                capability("Constant-quality encoding", profile.supportsConstantQuality)
            } header: {
                Text("Media engine")
            } footer: {
                Text(recommendation)
            }

            if profile.isTranslated {
                Section {
                    Text("YTGrab is running under Rosetta. In Finder, select YTGrab, choose File › Get Info and turn off “Open using Rosetta” for full speed.")
                        .foregroundStyle(Brand.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func capability(_ title: String, _ available: Bool) -> some View {
        LabeledContent(title) {
            Label(available ? "Yes" : "No", systemImage: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? Brand.ok : Color.secondary)
        }
    }

    private var recommendation: String {
        var lines: [String] = []
        if profile.hardwareEncodesHEVC {
            lines.append("Conversions run on the media engine, close to real time even for 4K.")
        } else if profile.hardwareEncodesH264 {
            lines.append("H.264 converts on the media engine. H.265 runs on the CPU here, so Edit-ready MP4 is the faster choice.")
        } else {
            lines.append("No hardware encoder was found, so conversions run on the CPU. Original is the fastest choice.")
        }
        if profile.prefersVP9Sources {
            lines.append("YTGrab picks VP9 over AV1 sources for conversion, because this Mac decodes VP9 much faster.")
        }
        return lines.joined(separator: " ")
    }
}

// MARK: - Window

enum SettingsWindow {
    private static var controller: NSWindowController?

    @MainActor
    static func show(_ tab: SettingsTab? = nil) {
        if let tab { SettingsRouter.shared.tab = tab }
        if let controller {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "YTGrab Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        let wc = NSWindowController(window: window)
        controller = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Actions shared by the window, the queue and Settings

@MainActor
enum AppActions {

    /// Performs a fix offered by FailureAdvice. `then` runs once the fix is
    /// in place, so the caller can retry.
    static func perform(_ action: FailureAdvice.Action, then: @escaping @MainActor () -> Void) {
        switch action {
        case .retry:
            then()
        case .updateTools:
            Task {
                await DownloadQueue.shared.updateTools()
                then()
            }
        case .repairTools:
            Task {
                try? await Task.detached { try ToolLocator.reinstallFromBundle() }.value
                then()
            }
        case .openYouTubeSettings:
            SettingsWindow.show(.youtube)
        case .chooseFolder:
            if chooseFolder() != nil { then() }
        case .openPrivacySettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Asks for a folder and makes it the default save location.
    @discardableResult
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = AppSettings.outputDirectory
        panel.prompt = "Save Here"
        panel.message = "Choose where YTGrab saves downloads."
        guard panel.runModal() == .OK, let picked = panel.url else { return nil }
        UserDefaults.standard.set(picked.path, forKey: AppSettings.Key.outputDirectory)
        return picked
    }
}
