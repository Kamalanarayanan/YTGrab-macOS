import SwiftUI

// MARK: - Containers

struct Card<Content: View>: View {
    var title: String?
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                SectionLabel(title)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Brand.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Brand.rule.opacity(0.6), lineWidth: 1)
                )
        )
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(Brand.textFaint)
    }
}

// MARK: - Small pieces

struct Chip: View {
    let text: String
    var symbol: String?
    var prominent = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            }
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(prominent ? Brand.text : Brand.textMuted)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Group {
                if prominent {
                    Capsule().fill(Brand.accentFill)
                } else {
                    Capsule().fill(Brand.raised)
                }
            }
        )
    }
}

struct Notice: View {
    enum Tone { case good, warning, neutral, bad }

    let text: String
    let tone: Tone

    private var colour: Color {
        switch tone {
        case .good:    return Brand.ok
        case .warning: return Brand.warn
        case .neutral: return Brand.textMuted
        case .bad:     return Brand.bad
        }
    }

    private var symbol: String {
        switch tone {
        case .good:    return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .neutral: return "info.circle.fill"
        case .bad:     return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(colour)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Brand.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Fixed-size thumbnail with a neutral placeholder while it loads.
struct Thumbnail: View {
    let url: URL?
    var width: CGFloat
    var height: CGFloat
    var corner: CGFloat = 8

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Brand.raised)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    private var placeholder: some View {
        Image(systemName: "play.rectangle")
            .font(.system(size: min(width, height) * 0.32))
            .foregroundStyle(Brand.textFaint)
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .foregroundStyle(Brand.text.opacity(isEnabled ? 1 : 0.5))
            .padding(.horizontal, large ? 22 : 14)
            .padding(.vertical, large ? 10 : 7)
            .background(
                Group {
                    if isEnabled {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Brand.accentFill)
                            .shadow(color: Brand.accentHalo, radius: configuration.isPressed ? 4 : 10, y: 2)
                    } else {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Brand.accentDeep.opacity(0.35))
                    }
                }
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Brand.text.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Brand.raised.opacity(configuration.isPressed ? 1 : 0.8))
            )
            .contentShape(Rectangle())
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = Brand.textMuted
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Brand.raised))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A selectable tile for one output format.
struct FormatTile: View {
    let format: OutputFormat
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: format.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Brand.accentBright : Brand.textMuted)
                Text(format.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.text)
                    .lineLimit(1)
                Text(format.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Brand.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Brand.accent.opacity(0.12) : Brand.raised.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? Brand.accent : Brand.rule, lineWidth: isSelected ? 1.5 : 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(format.title), \(format.subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Thin progress bar that also handles the indeterminate state.
struct SlimProgress: View {
    let fraction: Double?

    var body: some View {
        if let fraction {
            ProgressView(value: max(0, min(fraction, 1)))
                .progressViewStyle(.linear)
                .tint(Brand.accent)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(Brand.accent)
        }
    }
}
