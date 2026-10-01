import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

struct ContentView: View {

    @StateObject private var inspector = LinkInspector()
    @ObservedObject private var queue = DownloadQueue.shared

    @State private var linkText = ""
    @State private var selectedHeight = 0
    @State private var showAdvanced = false
    @State private var isDropTargeted = false
    @State private var pendingInspect: Task<Void, Never>?
    @FocusState private var linkFocused: Bool

    @AppStorage(AppSettings.Key.outputFormat) private var formatRaw = OutputFormat.editReady.rawValue
    @AppStorage(AppSettings.Key.preset) private var presetRaw = Preset.high.rawValue
    @AppStorage(AppSettings.Key.engine) private var engineRaw = EncoderEngine.automatic.rawValue
    @AppStorage(AppSettings.Key.tenBit) private var tenBit = false
    @AppStorage(AppSettings.Key.keepHDR) private var keepHDR = false
    @AppStorage(AppSettings.Key.preferH264Source) private var preferH264Source = true

    private let profile = SystemProfile.current

    private var format: OutputFormat { OutputFormat(rawValue: formatRaw) ?? .editReady }
    private var preset: Preset { Preset(rawValue: presetRaw) ?? .high }
    private var engine: EncoderEngine { EncoderEngine(rawValue: engineRaw) ?? .automatic }

    /// Several links pasted at once skip the preview and go straight to the
    /// queue with the current settings.
    private var pastedLinks: [String] { LinkParser.urls(in: linkText) }

    var body: some View {
        VStack(spacing: 0) {
            linkBar
            ScrollView {
                VStack(spacing: 14) {
                    composer
                    if !queue.jobs.isEmpty {
                        DownloadsSection(queue: queue)
                    }
                }
                .padding(16)
            }
            FooterBar(queue: queue)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 600, idealHeight: 720)
        .background(Brand.panel)
        .preferredColorScheme(.dark)
        .tint(Brand.accent)
        .overlay(dropHighlight)
        .onDrop(of: [UTType.url, UTType.plainText], isTargeted: $isDropTargeted, perform: handleDrop)
        .onAppear { linkFocused = true }
        .onChange(of: linkText) { text in scheduleInspect(text) }
        .onReceive(NotificationCenter.default.publisher(for: .ytgrabFocusLink)) { _ in linkFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .ytgrabPasteLink)) { _ in pasteFromClipboard() }
    }

    // MARK: - Link bar

    private var linkBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.textFaint)
                TextField("Paste a YouTube link, or several", text: $linkText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Brand.text)
                    .focused($linkFocused)
                    .onSubmit(submit)
                if !linkText.isEmpty {
                    Button {
                        clearComposer()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Brand.textFaint)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Brand.raised)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(linkFocused ? Brand.accent.opacity(0.7) : Brand.rule, lineWidth: 1)
                    )
            )

            Button {
                pasteFromClipboard()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(QuietButtonStyle())
            .help("Paste a link from the clipboard (⇧⌘V)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Brand.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.rule).frame(height: 1) }
    }

    // MARK: - Composer

    @ViewBuilder
    private var composer: some View {
        if pastedLinks.count > 1 {
            multiLinkCard(pastedLinks)
        } else {
            switch inspector.state {
            case .idle:
                EmptyHero(paste: pasteFromClipboard)
            case .probing(let url):
                probingCard(url)
            case .video(let info):
                videoCard(info)
            case .playlist(let playlist, _):
                playlistCard(playlist)
            case .failed(let advice, let url):
                failureCard(advice, url: url)
            }
        }
    }

    private func probingCard(_ url: String) -> some View {
        Card {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Brand.raised)
                        .frame(width: 192, height: 108)
                    ProgressView().controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(LinkParser.looksLikePlaylist(url) ? "Reading playlist …" : "Reading video details …")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.text)
                    Text("Checking which qualities and formats YouTube offers for this link. This takes a few seconds.")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Cancel") { clearComposer() }
                        .buttonStyle(QuietButtonStyle())
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func failureCard(_ advice: FailureAdvice, url: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label(advice.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.warn)
                Text(advice.message)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.text.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let action = advice.action, action != .retry, let title = advice.actionTitle {
                        Button(title) {
                            AppActions.perform(action) { inspector.inspect(url) }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    if !advice.isPermanent {
                        Button("Try Again") { inspector.inspect(url) }
                            .buttonStyle(QuietButtonStyle())
                    }
                }
            }
        }
    }

    private func videoCard(_ info: VideoInfo) -> some View {
        let option = info.option(for: selectedHeight) ?? info.best
        return Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Thumbnail(url: info.thumbnail, width: 192, height: 108, corner: 10)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(info.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Brand.text)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        HStack(spacing: 6) {
                            if let uploader = info.uploader {
                                Text(uploader)
                            }
                            if let duration = info.durationLabel {
                                Text("·")
                                Text(duration)
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textMuted)

                        if let best = info.best {
                            HStack(spacing: 6) {
                                Chip(text: best.tierLabel ?? best.resolutionLabel, prominent: true)
                                Chip(text: best.resolutionLabel)
                                Chip(text: best.codecLabel)
                                if let fps = best.fps, fps >= 48 { Chip(text: "\(fps) fps") }
                                if best.isHDR { Chip(text: "HDR", symbol: "sun.max.fill") }
                            }
                            .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                }

                optionsSection(qualities: info.options, info: info, option: option)

                HStack {
                    if let option, !format.isAudioOnly, let bytes = info.estimatedBytes(for: option) {
                        Text("About \(Format.bytes(bytes)) to download")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textMuted)
                    } else if format.isAudioOnly, let bytes = info.audioBytes {
                        Text("About \(Format.bytes(bytes)) to download")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textMuted)
                    }
                    Spacer()
                    Button {
                        enqueueVideo(info)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .onChange(of: info.id) { _ in selectedHeight = 0 }
    }

    private func playlistCard(_ playlist: PlaylistInfo) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack(alignment: .bottomTrailing) {
                        Thumbnail(url: playlist.entries.first?.thumbnail, width: 192, height: 108, corner: 10)
                        Label("\(playlist.entries.count)", systemImage: "list.bullet")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.7)))
                            .padding(6)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(playlist.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Brand.text)
                            .lineLimit(2)
                        Text([playlist.uploader, "\(playlist.entries.count) videos"].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textMuted)
                        ForEach(playlist.entries.prefix(3)) { entry in
                            Text("• \(entry.title)")
                                .font(.system(size: 11))
                                .foregroundStyle(Brand.textFaint)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }

                optionsSection(qualities: Self.genericLadder, info: nil, option: nil)

                HStack {
                    Spacer()
                    Button {
                        enqueuePlaylist(playlist)
                    } label: {
                        Label("Download \(playlist.entries.count) Videos", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(playlist.entries.isEmpty)
                }
            }
        }
    }

    private func multiLinkCard(_ links: [String]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(links.count) links")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.text)
                    Text("Each one is added to the queue with the settings below.")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textMuted)
                }
                optionsSection(qualities: Self.genericLadder, info: nil, option: nil)
                HStack {
                    Spacer()
                    Button {
                        enqueueLinks(links)
                    } label: {
                        Label("Download \(links.count) Videos", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
    }

    /// Quality caps offered when there is no single probed video.
    private static let genericLadder: [FormatOption] = [2160, 1440, 1080, 720, 480, 360].map {
        FormatOption(height: $0, fps: nil, bestCodec: "", hasAVC: $0 <= 1080, hasSDR: true, isHDR: false, approxBytes: nil)
    }

    // MARK: - Options

    private func optionsSection(qualities: [FormatOption], info: VideoInfo?, option: FormatOption?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Save as")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(OutputFormat.allCases) { item in
                    FormatTile(format: item, isSelected: item == format) {
                        formatRaw = item.rawValue
                    }
                }
            }

            if !format.isAudioOnly {
                HStack(spacing: 10) {
                    Text("Quality")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Brand.textMuted)
                    Picker("Quality", selection: $selectedHeight) {
                        if let best = info?.best {
                            Text("Best available · \(best.resolutionLabel) \(best.codecLabel)").tag(0)
                        } else {
                            Text("Best available").tag(0)
                        }
                        Divider()
                        ForEach(qualities) { rung in
                            Text(qualityLabel(rung, info: info)).tag(rung.height)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360)
                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(advice(info: info, option: option).enumerated()), id: \.offset) { _, item in
                    Notice(text: item.0, tone: item.1)
                }
            }

            advancedOptions
        }
    }

    private func qualityLabel(_ rung: FormatOption, info: VideoInfo?) -> String {
        var parts = [rung.resolutionLabel]
        if let tier = rung.tierLabel { parts.append(tier) }
        if info != nil {
            parts.append(rung.codecLabel)
            if let fps = rung.fps, fps >= 48 { parts.append("\(fps) fps") }
            if rung.isHDR { parts.append("HDR") }
            if let bytes = info?.estimatedBytes(for: rung) { parts.append("~\(Format.bytes(bytes))") }
        } else {
            parts[0] = "Up to \(rung.resolutionLabel)"
        }
        return parts.joined(separator: " · ")
    }

    private var advancedOptions: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                if format.targetCodec != nil {
                    HStack(spacing: 10) {
                        Text("Encoder").frame(width: 92, alignment: .leading)
                        Picker("Encoder", selection: $engineRaw) {
                            ForEach(EncoderEngine.allCases) { item in
                                Text(item.rawValue).tag(item.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 360)
                    }
                    HStack(spacing: 10) {
                        Text("Quality target").frame(width: 92, alignment: .leading)
                        Picker("Quality target", selection: $presetRaw) {
                            ForEach(Preset.allCases) { item in
                                Text("\(item.rawValue) — \(item.detail)").tag(item.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 360)
                    }
                }
                if format == .editReady {
                    Toggle("Use YouTube's own H.264 stream when it exists (fast, no quality loss)", isOn: $preferH264Source)
                }
                if format == .compact {
                    Toggle("10-bit colour (smoother gradients)", isOn: $tenBit)
                    Toggle("Keep HDR when the video has it", isOn: $keepHDR)
                }
                if format == .original || format.isAudioOnly {
                    Text("Nothing to adjust for this format.")
                        .foregroundStyle(Brand.textFaint)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            .foregroundStyle(Brand.text)
            .padding(.top, 8)
        } label: {
            Text("Advanced")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Brand.textMuted)
        }
    }

    /// What is worth saying about the current combination, in plain words.
    private func advice(info: VideoInfo?, option: FormatOption?) -> [(String, Notice.Tone)] {
        var notes: [(String, Notice.Tone)] = []
        let codec = format.targetCodec

        if let info, info.isLive {
            notes.append(("This is a live stream. It can only be downloaded after it ends.", .warning))
        }

        switch format {
        case .audioM4A, .audioMP3:
            notes.append(("Only the audio is saved\(format == .audioM4A ? ", without re-encoding when possible" : "")." , .neutral))

        case .original:
            if let option {
                if option.codecLabel == "H.264" {
                    notes.append(("Saved exactly as YouTube serves it. Opens in every editor.", .good))
                } else {
                    notes.append(("Saved as \(option.codecLabel) in an MP4. Fine for watching, but Premiere and Final Cut may not open it. Pick Edit-ready MP4 for editing.", .warning))
                }
            } else {
                notes.append(("Saved exactly as YouTube serves it, with no conversion.", .neutral))
            }

        case .editReady, .compact:
            guard let codec else { break }
            let resolvedEngine = engine.resolved(for: codec, on: profile)
            let where_ = resolvedEngine == .hardware ? "this Mac's media engine" : "the CPU"

            if format == .editReady, preferH264Source, let option, option.hasAVC {
                notes.append(("YouTube has H.264 at \(option.resolutionLabel), so it's saved directly. No conversion, no quality loss.", .good))
            } else if format == .editReady, preferH264Source, option == nil, selectedHeight > 0, selectedHeight <= 1080 {
                notes.append(("At 1080p and below YouTube usually has H.264, which is saved without conversion.", .good))
            } else if let option {
                notes.append(("YouTube only has \(option.codecLabel) at \(option.resolutionLabel), so it's converted to \(codec.displayName) on \(where_).", .neutral))
            } else {
                notes.append(("Converted to \(codec.displayName) on \(where_) when needed.", .neutral))
            }

            if resolvedEngine == .software && !profile.hardwareEncodes(codec) {
                notes.append(("This Mac has no hardware \(codec.displayName) encoder, so conversion runs on the CPU and takes longer.", .warning))
            }
            if let option, option.isHDR {
                if format == .compact && keepHDR {
                    notes.append(("HDR is kept as 10-bit H.265.", .good))
                } else if option.hasSDR {
                    notes.append(("This video is HDR. The SDR version is used so colours look right everywhere.", .neutral))
                }
            }
        }
        return notes
    }

    // MARK: - Actions

    private func scheduleInspect(_ text: String) {
        pendingInspect?.cancel()
        let links = LinkParser.urls(in: text)
        guard links.count == 1, let link = links.first else {
            if links.isEmpty && !inspector.isProbing { inspector.reset() }
            return
        }
        guard link != inspector.currentURL else { return }
        // A short pause so typing or pasting in pieces probes once.
        pendingInspect = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            inspector.inspect(link)
        }
    }

    private func submit() {
        let links = pastedLinks
        if links.count > 1 {
            enqueueLinks(links)
            return
        }
        switch inspector.state {
        case .video(let info):
            enqueueVideo(info)
        case .playlist(let playlist, _):
            enqueuePlaylist(playlist)
        default:
            if let link = links.first {
                pendingInspect?.cancel()
                inspector.inspect(link)
            }
        }
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let links = LinkParser.urls(in: text)
        guard !links.isEmpty else { return }
        linkText = links.joined(separator: " ")
        linkFocused = true
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { appendLink(url.absoluteString) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                accepted = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    DispatchQueue.main.async { appendLink(text) }
                }
            }
        }
        return accepted
    }

    private func appendLink(_ text: String) {
        let links = LinkParser.urls(in: text)
        guard !links.isEmpty else { return }
        let existing = LinkParser.urls(in: linkText)
        linkText = (existing + links.filter { !existing.contains($0) }).joined(separator: " ")
    }

    private func clearComposer() {
        pendingInspect?.cancel()
        linkText = ""
        selectedHeight = 0
        inspector.reset()
        linkFocused = true
    }

    private func baseRequest(url: String, title: String) -> JobRequest {
        JobRequest(
            url: url,
            title: title,
            uploader: nil,
            duration: nil,
            infoJSON: nil,
            infoFetchedAt: nil,
            format: format,
            height: format.isAudioOnly ? 0 : selectedHeight,
            option: nil,
            engine: engine,
            preset: preset,
            tenBit: tenBit,
            keepHDR: keepHDR,
            preferH264Source: preferH264Source,
            outputDirectory: AppSettings.outputDirectory,
            cookies: AppSettings.cookies,
            forceIPv4: AppSettings.forceIPv4
        )
    }

    private func enqueueVideo(_ info: VideoInfo) {
        var request = baseRequest(url: info.webpageURL, title: info.title)
        request.uploader = info.uploader
        request.duration = info.duration
        request.infoJSON = info.infoJSON
        request.infoFetchedAt = info.fetchedAt
        request.option = format.isAudioOnly ? nil : (info.option(for: selectedHeight) ?? info.best)
        queue.enqueue([(request, info.thumbnail)])
        clearComposer()
    }

    private func enqueuePlaylist(_ playlist: PlaylistInfo) {
        let items = playlist.entries.map { entry -> (JobRequest, URL?) in
            var request = baseRequest(url: entry.url, title: entry.title)
            request.duration = entry.duration
            request.uploader = playlist.uploader
            return (request, entry.thumbnail)
        }
        queue.enqueue(items)
        clearComposer()
    }

    private func enqueueLinks(_ links: [String]) {
        let items = links.map { link -> (JobRequest, URL?) in
            (baseRequest(url: link, title: ""), Self.youTubeThumbnail(for: link))
        }
        queue.enqueue(items)
        clearComposer()
    }

    private static func youTubeThumbnail(for link: String) -> URL? {
        guard let components = URLComponents(string: link) else { return nil }
        var id = components.queryItems?.first { $0.name == "v" }?.value
        if id == nil, components.host?.contains("youtu.be") == true {
            id = components.path.split(separator: "/").first.map(String.init)
        }
        if id == nil, components.path.hasPrefix("/shorts/") {
            id = components.path.split(separator: "/").dropFirst().first.map(String.init)
        }
        return id.flatMap { URL(string: "https://i.ytimg.com/vi/\($0)/mqdefault.jpg") }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Brand.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .padding(6)
            .opacity(isDropTargeted ? 1 : 0)
            .allowsHitTesting(false)
    }
}

// MARK: - Empty state

private struct EmptyHero: View {
    let paste: () -> Void

    var body: some View {
        Card {
            VStack(spacing: 14) {
                Image(systemName: "arrow.down.to.line.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Brand.accentFill)
                    .padding(.top, 10)
                Text("Paste a link to get started")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Brand.text)
                Text("YTGrab checks what the video offers, then saves an MP4 that opens in every editor, or just the audio.")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
                Button(action: paste) {
                    Label("Paste Link", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(PrimaryButtonStyle(large: true))

                HStack(spacing: 18) {
                    hint("hand.draw", "Drag links onto the window")
                    hint("list.bullet", "Playlists and several links work too")
                    hint("bolt", "Uses this Mac's media engine")
                }
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11))
            .foregroundStyle(Brand.textFaint)
    }
}

// MARK: - Downloads

private struct DownloadsSection: View {
    @ObservedObject var queue: DownloadQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Downloads")
                if queue.activeCount > 0 {
                    Text("\(queue.activeCount) in progress")
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.textMuted)
                }
                Spacer()
                if queue.hasFinishedJobs {
                    Button("Clear Finished") { queue.clearFinished() }
                        .buttonStyle(QuietButtonStyle())
                }
            }
            .padding(.horizontal, 4)

            VStack(spacing: 8) {
                ForEach(queue.jobs) { job in
                    JobRow(job: job, queue: queue)
                }
            }
        }
    }
}

private struct JobRow: View {
    @ObservedObject var job: DownloadJob
    let queue: DownloadQueue
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Thumbnail(url: job.thumbnail, width: 96, height: 54)
                VStack(alignment: .leading, spacing: 5) {
                    Text(job.title.isEmpty ? job.request.url : job.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    status
                }
                Spacer(minLength: 8)
                actions
            }

            if showDetails {
                details
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Brand.surface)
        )
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Link") { copy(job.request.url) }
            Button(showDetails ? "Hide Details" : "Show Details") { showDetails.toggle() }
            if let url = job.outputURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Divider()
            Button("Remove from List") { queue.remove(job) }
        }
    }

    private var formatLine: String {
        var parts = [job.request.format.title]
        if !job.request.format.isAudioOnly {
            parts.append(job.request.height > 0 ? "\(job.request.height)p" : "Best quality")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var status: some View {
        switch job.state {
        case .waiting:
            Text(job.notice ?? "Waiting · \(formatLine)")
                .font(.system(size: 12))
                .foregroundStyle(Brand.textMuted)

        case .running:
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(job.progress?.phase ?? "Starting …")
                        .foregroundStyle(Brand.text.opacity(0.9))
                    if let progress = job.progress {
                        Text("Step \(progress.step) of \(progress.steps)")
                            .foregroundStyle(Brand.textFaint)
                    }
                    Spacer()
                    if let fraction = job.progress?.fraction {
                        Text("\(Int(fraction * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(Brand.text.opacity(0.9))
                    }
                }
                .font(.system(size: 12))
                SlimProgress(fraction: job.progress?.fraction)
                if let detail = job.progress?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Brand.textMuted)
                }
            }

        case .finished(let url):
            Label("Saved · \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Brand.ok)
                .lineLimit(1)
                .truncationMode(.middle)

        case .failed(let advice):
            VStack(alignment: .leading, spacing: 6) {
                Label(advice.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.bad)
                Text(advice.message)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                if let action = advice.action, let title = advice.actionTitle {
                    Button(title) { perform(action) }
                        .buttonStyle(QuietButtonStyle())
                }
            }

        case .cancelled:
            Text("Cancelled")
                .font(.system(size: 12))
                .foregroundStyle(Brand.textMuted)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch job.state {
            case .waiting, .running:
                IconButton(symbol: "xmark", help: "Cancel") { queue.cancel(job) }
            case .finished(let url):
                IconButton(symbol: "play.fill", help: "Open", tint: Brand.text) { NSWorkspace.shared.open(url) }
                IconButton(symbol: "magnifyingglass", help: "Show in Finder", tint: Brand.text) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                IconButton(symbol: "xmark", help: "Remove from list") { queue.remove(job) }
            case .failed, .cancelled:
                IconButton(symbol: "arrow.clockwise", help: "Try again", tint: Brand.text) { queue.retry(job) }
                IconButton(symbol: "xmark", help: "Remove from list") { queue.remove(job) }
            }
            IconButton(symbol: showDetails ? "chevron.up" : "chevron.down", help: showDetails ? "Hide details" : "Show details") {
                showDetails.toggle()
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.request.url)
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("Copy Log") { copy(job.log.joined(separator: "\n")) }
                    .buttonStyle(QuietButtonStyle())
            }
            ScrollView {
                Text(job.log.isEmpty ? "No output yet." : job.log.suffix(200).joined(separator: "\n"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Brand.text.opacity(0.8))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 8).fill(Brand.panel))
        }
    }

    private func perform(_ action: FailureAdvice.Action) {
        switch action {
        case .retry:
            queue.retry(job)
        case .chooseFolder:
            if let folder = AppActions.chooseFolder() {
                job.request.outputDirectory = folder
                queue.retry(job)
            }
        case .updateTools:
            Task {
                await queue.updateTools()
                queue.retry(job)
            }
        default:
            AppActions.perform(action) { queue.retry(job) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @ObservedObject var queue: DownloadQueue
    @AppStorage(AppSettings.Key.outputDirectory) private var storedDirectory = ""
    @AppStorage(AppSettings.Key.autoUpdateTools) private var autoUpdate = true
    @State private var engineAge: Int?

    private let profile = SystemProfile.current

    var body: some View {
        HStack(spacing: 14) {
            Button {
                if let folder = AppActions.chooseFolder() { storedDirectory = folder.path }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Brand.accentBright)
                    Text(displayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)
            .help("Save downloads to … (click to change)")

            Spacer()

            if let status = queue.toolStatus {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(status)
                }
            } else if let age = engineAge, age > 45, !autoUpdate {
                Button {
                    Task { await queue.updateTools(); refreshAge() }
                } label: {
                    Label("Download engine is \(age) days old · Update", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Brand.warn)
                }
                .buttonStyle(.plain)
            }

            Button {
                SettingsWindow.show(.mac)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: profile.architecture == .arm64 ? "cpu.fill" : "cpu")
                    Text(profile.chipName)
                        .lineLimit(1)
                    if profile.hardwareEncodesH264 {
                        Image(systemName: "bolt.fill").foregroundStyle(Brand.ok)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("This Mac: \(profile.summary)")
        }
        .font(.system(size: 11))
        .foregroundStyle(Brand.textMuted)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Brand.surface)
        .overlay(alignment: .top) { Rectangle().fill(Brand.rule).frame(height: 1) }
        .onAppear(perform: refreshAge)
    }

    private var displayPath: String {
        let path = storedDirectory.isEmpty ? AppSettings.defaultOutputDirectory.path : storedDirectory
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private func refreshAge() {
        engineAge = ToolUpdateManager.ytdlpAgeInDays()
    }
}

extension Notification.Name {
    static let ytgrabFocusLink = Notification.Name("ytgrabFocusLink")
    static let ytgrabPasteLink = Notification.Name("ytgrabPasteLink")
}
