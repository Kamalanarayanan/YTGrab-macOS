import SwiftUI

/// CRIT Studio design tokens.
///
/// Sampled directly off the app mark rather than eyeballed. The mark carries a
/// gradient, so the warm range is kept as four stops instead of one flat red:
/// deep in the shadowed leg, mid across the body, bright on the lit edge, and
/// the near-orange highlight on the folded corner.
///
/// If the mark ever changes, resample and edit only this file.
enum Brand {

    // MARK: - Warm range

    /// Body of the mark. The default accent.
    static let accent = Color(hex: 0xEA3318)

    /// Lit edge. Hover states and the top of gradients.
    static let accentBright = Color(hex: 0xF7551F)

    /// The folded-corner highlight. Small emphasis only, it goes muddy across
    /// large fills.
    static let accentGlow = Color(hex: 0xFA7937)

    /// Shadowed leg. Pressed states and disabled fills.
    static let accentDeep = Color(hex: 0xA40A02)

    /// The soft bloom the mark sits in.
    static let accentHalo = Color(hex: 0xEA3318).opacity(0.16)

    // MARK: - Surfaces

    /// The plate the mark sits on. Darkest layer: chrome, console, About panel.
    static let panel = Color(hex: 0x0E0F12)

    /// One step up. Cards and grouped rows.
    static let surface = Color(hex: 0x16171B)

    /// Two steps up. Inputs and pressed rows.
    static let raised = Color(hex: 0x211F22)

    /// Hairlines between sections.
    static let rule = Color(hex: 0x2A2A31)

    // MARK: - Text

    static let text = Color(hex: 0xF2F0EE)
    static let textMuted = Color(hex: 0x979696)
    static let textFaint = Color(hex: 0x717070)

    // MARK: - Status

    static let ok = Color(hex: 0x5FBF7A)
    static let warn = Color(hex: 0xE0A33C)
    static let bad = Color(hex: 0xE05A4C)

    // MARK: - Type

    /// The letterspaced caps used for the studio credit.
    static func credit(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }

    static let creditTracking: CGFloat = 2.2

    // MARK: - Gradients

    /// Primary buttons. Runs along the same axis as the light on the mark.
    static let accentFill = LinearGradient(
        colors: [accentBright, accent],
        startPoint: .top,
        endPoint: .bottom
    )
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Bundle facts

enum AppInfo {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "YTGrab"
    }

    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    static let studio = "CRIT Studio"
    static let author = "Kamalanarayanan"
    static let contactEmail = "kamalgeek92@gmail.com"

    static var copyright: String {
        "Copyright © 2026 \(author), \(studio). All rights reserved."
    }

    /// The short capability line under the studio credit.
    static let capabilities = "H.265 · H.264 · 4K · VideoToolbox"
}
