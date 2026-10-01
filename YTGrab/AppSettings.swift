import Foundation

/// UserDefaults keys and typed accessors, readable from any thread.
/// Views bind to the same keys with @AppStorage.
enum AppSettings {

    enum Key {
        static let outputDirectory = "outputDirectory"
        static let outputFormat = "outputFormat"
        static let preset = "preset"
        static let engine = "encoderEngine"
        static let tenBit = "tenBit"
        static let keepHDR = "keepHDR"
        static let preferH264Source = "preferH264Source"
        static let cookies = "cookiesBrowser"
        static let forceIPv4 = "forceIPv4"
        static let autoUpdateTools = "autoUpdateTools"
        static let updateChannel = "updateChannel"
        static let lastToolCheck = "lastToolCheck"
        static let maxConcurrentJobs = "maxConcurrentJobs"
        static let notifyWhenDone = "notifyWhenDone"
        static let revealWhenDone = "revealWhenDone"
        static let watchClipboard = "watchClipboard"
    }

    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.outputFormat: OutputFormat.editReady.rawValue,
            Key.preset: Preset.high.rawValue,
            Key.engine: EncoderEngine.automatic.rawValue,
            Key.tenBit: false,
            Key.keepHDR: false,
            Key.preferH264Source: true,
            Key.cookies: CookieBrowser.none.rawValue,
            Key.forceIPv4: false,
            Key.autoUpdateTools: true,
            Key.updateChannel: UpdateChannel.stable.rawValue,
            Key.maxConcurrentJobs: SystemProfile.current.recommendedConcurrentJobs,
            Key.notifyWhenDone: true,
            Key.revealWhenDone: false,
            Key.watchClipboard: true,
        ])
    }

    static var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    static var outputDirectory: URL {
        let stored = defaults.string(forKey: Key.outputDirectory) ?? ""
        return stored.isEmpty ? defaultOutputDirectory : URL(fileURLWithPath: stored, isDirectory: true)
    }

    static var cookies: CookieBrowser {
        CookieBrowser(rawValue: defaults.string(forKey: Key.cookies) ?? "") ?? .none
    }

    static var forceIPv4: Bool { defaults.bool(forKey: Key.forceIPv4) }
    static var autoUpdateTools: Bool { defaults.bool(forKey: Key.autoUpdateTools) }

    static var updateChannel: UpdateChannel {
        UpdateChannel(rawValue: defaults.string(forKey: Key.updateChannel) ?? "") ?? .stable
    }

    static var lastToolCheck: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: Key.lastToolCheck)) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: Key.lastToolCheck) }
    }

    static var maxConcurrentJobs: Int { min(max(defaults.integer(forKey: Key.maxConcurrentJobs), 1), 4) }
    static var notifyWhenDone: Bool { defaults.bool(forKey: Key.notifyWhenDone) }
    static var revealWhenDone: Bool { defaults.bool(forKey: Key.revealWhenDone) }
}
