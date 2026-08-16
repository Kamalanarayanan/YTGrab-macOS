import SwiftUI
import AppKit

struct ContentView: View {

    @StateObject private var engine = DownloadEngine()

    @State private var url = ""
    @State private var selectedHeight = 0          // 0 means best available
    @State private var codec: OutputCodec = .hevc
    @State private var encoder: EncoderEngine = .hardware
    @State private var preset: Preset = .high
    @State private var tenBit = false
    @State private var preferAVC = true
    @AppStorage("outputDirectory") private var storedDirectory = ""

    private var outputDirectory: URL {
        if !storedDirectory.isEmpty {
            return URL(fileURLWithPath: storedDirectory)
        }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// The rung the user is actually on, so the interface can warn about it.
    private var chosenOption: FormatOption? {
        if selectedHeight == 0 { return engine.info?.best }
        return engine.options.first { $0.height == selectedHeight }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    detected
                    outputSection
                    destinationSection
                }
                .padding(14)
            }
            controls
            if engine.isProbing || engine.isBusy || !engine.logLines.isEmpty {
                console
            }
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 480, idealHeight: 540)
        .background(Brand.panel)
        .preferredColorScheme(.dark)
        .tint(Brand.accent)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                TextField("Paste a YouTube link", text: $url)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Brand.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Brand.raised)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Brand.rule, lineWidth: 1)
                            )
                    )
                    .onSubmit { engine.check(url: url) }

                Button {
                    engine.check(url: url)
                } label: {
                    HStack(spacing: 6) {
                        if engine.isProbing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Brand.text)
                        }
                        Text(engine.isProbing ? "Checking" : "Check")
                            .fontWeight(.semibold)
                    }
                    .frame(minWidth: 74)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 12)
                }
                .buttonStyle(.plain)
                .background(
                    Group {
                        if url.isEmpty || engine.isProbing {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Brand.accentDeep.opacity(0.4))
                        } else {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Brand.accentFill)
                        }
                    }
                )
                .foregroundStyle(Brand.text)
                .disabled(url.isEmpty || engine.isProbing || engine.isBusy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(Brand.surface)
    }

    // MARK: - Detected

    /// Reports what this specific video actually has, rather than offering a
    /// generic ladder that may not exist.
    private var detected: some View {
        Card(title: "Detected") {
            if let info = engine.info, let best = info.best {
                VStack(alignment: .leading, spacing: 12) {
                    Text(info.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Chip(text: best.tierLabel ?? best.resolutionLabel, prominent: true)
                        Chip(text: best.resolutionLabel)
                        Chip(text: best.codecLabel)
                        if let fps = best.fps, fps >= 48 { Chip(text: "\(fps)fps") }
                        if best.isHDR { Chip(text: "HDR") }
                        if let duration = info.durationLabel { Chip(text: duration) }
                    }

                    Divider().overlay(Brand.rule)

                    Picker("Quality", selection: $selectedHeight) {
                        Text("Best available  ·  \(best.resolutionLabel) \(best.codecLabel)")
                            .tag(0)
                        ForEach(engine.options) { option in
                            Text(option.summary).tag(option.height)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: engine.options) { _, list in
                        if !list.contains(where: { $0.height == selectedHeight }) {
                            selectedHeight = 0
                        }
                    }

                    if let chosen = chosenOption {
                        advice(for: chosen)
                    }
                }
            } else {
                Text(engine.isProbing
                     ? "Reading available formats ..."
                     : "Paste a link and press Check. The available resolutions, codecs and frame rates for that specific video will appear here.")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The one thing worth saying about the selected rung.
    @ViewBuilder
    private func advice(for option: FormatOption) -> some View {
        let copying = codec == .remux
        if copying && !option.copiesCleanly {
            Notice(
                text: "YouTube only serves \(option.codecLabel) at \(option.resolutionLabel). Keeping the original leaves \(option.codecLabel) inside an MP4, which Premiere will not open. Switch to H.265 or H.264 to edit this.",
                tone: .warning
            )
        } else if copying && option.copiesCleanly {
            Notice(
                text: "H.264 exists at \(option.resolutionLabel), so this copies across untouched with nothing lost.",
                tone: .good
            )
        } else if let size = option.sizeLabel {
            Notice(
                text: "Source is roughly \(size) before transcoding.",
                tone: .neutral
            )
        }
    }

    // MARK: - Output

    private var outputSection: some View {
        Card(title: "Output") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Codec", selection: $codec) {
                    ForEach(OutputCodec.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if codec.isTranscode {
                    HStack(spacing: 14) {
                        Picker("Encoder", selection: $encoder) {
                            ForEach(EncoderEngine.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)

                        HStack(spacing: 8) {
                            Text("Compression")
                                .foregroundStyle(Brand.textMuted)
                            Picker("Compression", selection: $preset) {
                                ForEach(Preset.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 118)
                        }

                        if codec == .hevc {
                            Toggle("10-bit", isOn: $tenBit)
                                .fixedSize()
                        }
                    }
                    .controlSize(.small)
                } else {
                    Toggle("Prefer H.264 source for a lossless copy", isOn: $preferAVC)
                        .fixedSize()
                }
            }
            .toggleStyle(.switch)
            .font(.system(size: 13))
            .foregroundStyle(Brand.text)
        }
    }

    // MARK: - Destination

    private var destinationSection: some View {
        Card(title: "Save to") {
            HStack(spacing: 10) {
                Text(outputDirectory.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Brand.textMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose") { chooseDirectory() }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                start()
            } label: {
                Text("Download")
                    .fontWeight(.semibold)
                    .frame(minWidth: 96)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .background(
                Group {
                    if engine.isBusy || url.isEmpty {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Brand.accentDeep.opacity(0.4))
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Brand.accentFill)
                            .shadow(color: Brand.accentHalo, radius: 10, y: 2)
                    }
                }
            )
            .foregroundStyle(Brand.text)
            .disabled(engine.isBusy || url.isEmpty)
            .keyboardShortcut(.defaultAction)

            Button("Cancel") { engine.cancel() }
                .buttonStyle(.bordered)
                .disabled(!engine.isBusy)

            Button("Show in Finder") {
                if let file = engine.lastOutputFile {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
            }
            .buttonStyle(.bordered)
            .disabled(engine.lastOutputFile == nil)

            Spacer()

            if engine.isBusy {
                ProgressView(value: engine.progress, total: 100)
                    .progressViewStyle(.linear)
                    .tint(Brand.accent)
                    .frame(width: 170)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Brand.surface)
    }

    // MARK: - Console

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(engine.logLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(colour(for: line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(12)
            }
            .onChange(of: engine.logLines.count) { _, count in
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
        .frame(height: 116)
        .background(Brand.panel)
        .overlay(alignment: .top) { Rectangle().fill(Brand.rule).frame(height: 1) }
    }

    private func colour(for line: String) -> Color {
        if line.hasPrefix("Error") || line.contains("exited with") { return Brand.bad }
        if line.hasPrefix("Heads up") || line.hasPrefix("No H.264") { return Brand.warn }
        if line.hasPrefix("Done.") { return Brand.ok }
        if line.hasPrefix("Detected") || line.hasPrefix("Available") { return Brand.accentGlow }
        if line.hasPrefix("frame=") || line.contains("[download]") { return Brand.textFaint }
        return Brand.text.opacity(0.9)
    }

    // MARK: - Actions

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let picked = panel.url {
            storedDirectory = picked.path
        }
    }

    private func start() {
        let options = JobOptions(
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            title: engine.videoTitle,
            height: selectedHeight,
            codec: codec,
            engine: encoder,
            preset: preset,
            tenBit: tenBit,
            preferAVC: preferAVC,
            outputDirectory: outputDirectory
        )
        engine.start(options: options)
    }
}

// MARK: - Pieces

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(Brand.textFaint)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Brand.surface)
        )
    }
}

private struct Chip: View {
    let text: String
    var prominent = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? Brand.text : Brand.textMuted)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
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

private struct Notice: View {
    enum Tone { case good, warning, neutral }

    let text: String
    let tone: Tone

    private var colour: Color {
        switch tone {
        case .good:    return Brand.ok
        case .warning: return Brand.warn
        case .neutral: return Brand.textMuted
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 3)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Brand.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
}
