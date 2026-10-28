import SwiftUI

/// Actions live here; passive information belongs in ReaderStatusBar.
struct ReaderToolbar: View {
    @Bindable var reader: ReaderState
    @FocusState private var reviewFocused: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controls(compact: false)
            controls(compact: true)
            controls(compact: true, minimal: true)
        }
        .buttonStyle(.bordered)
        .menuStyle(.borderedButton)
        .controlSize(.regular)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
        .onChange(of: reader.showChanges) { if !reader.showChanges { reviewFocused = true } }
    }

    private func controls(compact: Bool, minimal: Bool = false) -> some View {
        HStack(spacing: 8) {
            Button { reader.showOutline.toggle() } label: {
                Image(systemName: "sidebar.left").frame(width: 18, height: 20)
            }
            .fixedSize()
            .tint(reader.showOutline ? .accentColor : .secondary)
            .help("Toggle outline (⌥⌘O)")
            .accessibilityLabel("Outline sidebar")
            .accessibilityValue(reader.showOutline ? "Shown" : "Hidden")

            if !minimal {
            Menu {
                ForEach(reader.rendered?.headings ?? []) { heading in
                    Button(String(repeating: "  ", count: max(0, heading.level - 1)) + heading.title) {
                        reader.navigate(to: heading.id)
                    }
                }
            } label: {
                if compact {
                    Image(systemName: "list.bullet.indent").frame(width: 18, height: 20)
                } else {
                    Label("Outline", systemImage: "list.bullet.indent")
                }
            }
            .accessibilityLabel("Jump to heading")
            .disabled(reader.rendered?.headings.isEmpty ?? true)
            .help("Jump to a heading")
            .fixedSize()

            }

            Button { reader.showDiscussions.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text("Discussions")
                    if let count = reader.rendered?.discussions?.threads.count, count > 0 {
                        Text(count.formatted()).font(.caption.weight(.semibold)).monospacedDigit()
                    }
                }
            }
            .fixedSize().tint(reader.showDiscussions ? .accentColor : .secondary)
            .accessibilityLabel("Discussions")
            .help("Show or hide discussions stored in this Markdown file")

            Spacer(minLength: 8)

            if reader.isStreamingPreview {
                Button { reader.streamPaused.toggle() } label: {
                    Label(reader.streamPaused ? "Resume" : "Pause",
                          systemImage: reader.streamPaused ? "play.fill" : "pause.fill")
                }
                .help(reader.streamPaused
                      ? "Resume following the editor and show its latest text"
                      : "Hold this preview while you edit or switch documents")
                .accessibilityLabel(reader.streamPaused ? "Resume live preview" : "Pause live preview")
                .fixedSize()
                toolSeparator
            } else if reader.fileURL != nil {
                Button { reader.showChanges.toggle() } label: {
                    HStack(spacing: 6) {
                        if !compact { Image(systemName: "text.badge.checkmark") }
                        Text(compact ? "Changes" : "Review Changes")
                        if reader.changes.count > 0 {
                            Text(reader.changes.count > 99 ? "99+" : reader.changes.count.formatted())
                                .font(.caption.weight(.semibold)).monospacedDigit()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
                .help("Review saved changes (⇧⌘R)")
                .accessibilityLabel("Review changes")
                .accessibilityValue("\(reader.changes.count) unreviewed changes, panel \(reader.showChanges ? String(localized: "shown") : String(localized: "hidden"))")
                .tint(reader.showChanges ? .accentColor : .secondary)
                .focusable().focused($reviewFocused)
                .onKeyPress(.space, phases: .down) { _ in reader.showChanges.toggle(); return .handled }
                .fixedSize()
                toolSeparator
            }

            Button {
                if let speech = reader.existingSpeech, speech.showPlayer { speech.close() }
                else { reader.speech.showPlayer = true }
            } label: {
                if compact { Image(systemName: "headphones").frame(width: 18, height: 20) }
                else { Label("Read Aloud", systemImage: "headphones") }
            }
            .fixedSize().tint(reader.existingSpeech?.showPlayer == true ? .accentColor : .secondary)
            .disabled(reader.rendered?.speech?.segments.isEmpty ?? true)
            .accessibilityLabel("Read Aloud controls").help("Show or hide Read Aloud controls")

            Button { reader.showFind.toggle() } label: {
                Image(systemName: "magnifyingglass").frame(width: 18, height: 20)
            }
            .fixedSize()
            .tint(reader.showFind ? .accentColor : .secondary)
            .help("Find in document (⌘F)")
            .accessibilityLabel("Find in document")
            .accessibilityValue(reader.showFind ? "Shown" : "Hidden")

            if !minimal {
            Button { reader.wide.toggle() } label: {
                Image(systemName: "arrow.left.and.right").frame(width: 18, height: 20)
            }
            .fixedSize()
            .tint(reader.wide ? .accentColor : .secondary)
            .help(reader.wide ? "Use comfortable reading width" : "Use full window width")
            .accessibilityLabel("Reading width")
            .accessibilityValue(reader.wide ? "Full width" : "Comfortable width")

            }

            Menu {
                Toggle("Full Width", isOn: $reader.wide)
                Picker("Document Language", selection: $reader.documentLanguageOverride) {
                    Text("Automatic").tag(Optional<String>.none)
                    ForEach(DocumentLanguage.menuCodes.sorted(by: { DocumentLanguage.displayName($0).localizedStandardCompare(DocumentLanguage.displayName($1)) == .orderedAscending }), id: \.self) { code in
                        Text(DocumentLanguage.displayName(code)).tag(Optional(code))
                    }
                }
                .help("For this document only. Automatic detects its language on this Mac when enough text is available; choose a language to control pronunciation. Interface language is separate.")
                #if MARGINED_APP_STORE
                Button("Allow Image Folder…") { reader.allowImageFolder() }
                #endif
                Toggle("Load Remote Images", isOn: $reader.loadRemoteImages)
                    .help("For this document only. HTTPS image hosts can see your IP address and that you opened their image. Off each time a document is opened.")
                Divider()
                Button("Zoom In") { reader.changeZoom(by: 0.1) }
                Button("Zoom Out") { reader.changeZoom(by: -0.1) }
                Button("Actual Size") { reader.zoom = 1 }
                if let url = reader.fileURL {
                    Divider()
                    Button(reader.fileUpdatesPaused ? "Resume Updates" : "Pause Updates") {
                        reader.setFileUpdatesPaused(!reader.fileUpdatesPaused)
                    }
                    Divider()
                    Toggle("Save Checkmarks Automatically", isOn: $reader.checklistMode)
                        .disabled(reader.checklistSaving || reader.rendered?.checkboxCount == 0)
                        .help("For this document only. Each checkbox change is saved immediately; Undo is available.")
                    Divider()
                    Button("Reload") { reader.reload() }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 18, height: 20) }
            .help("Reading options").accessibilityLabel("Reading options")
            .fixedSize()
        }
    }

    private var toolSeparator: some View {
        Divider().frame(height: 18).padding(.horizontal, 2).accessibilityHidden(true)
    }
}

struct ReaderStatusBar: View {
    var reader: ReaderState

    var body: some View {
        HStack(spacing: 12) {
            if reader.playbackHolding {
                Label(reader.existingSpeech?.session.status == .playing ? "Reading aloud" : reader.hasPendingFileUpdate ? "Newer version waiting" : "Reading paused", systemImage: "headphones")
            } else if reader.isStreamingPreview {
                Label(streamStatus, systemImage: streamSymbol)
                    .help(reader.streamPaused
                          ? "This preview is held. Resume to show the latest streamed text."
                          : "Follows the editor publishing to the Marked-compatible channel. Source names are supplied by the editor.")
            } else if reader.fileURL != nil {
                Label(reader.fileUpdatesPaused ? (reader.hasPendingFileUpdate ? "Newer version waiting" : "Updates paused") : reader.checklistMode ? (reader.checklistSaving ? "Saving checkbox…" : (reader.checklistError == nil ? "Checkmarks saved" : "Checkbox not saved")) : (reader.errorMessage == nil ? "Automatic updates" : "Refresh failed"),
                      systemImage: reader.fileUpdatesPaused ? "pause.circle" : reader.errorMessage == nil && reader.checklistError == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                    .help(reader.fileUpdatesPaused ? "Resume Updates to show the latest saved version. Checkmarks cannot save while a newer version is waiting." : "Saved file changes appear automatically. Use Review Changes to compare with the last version you marked reviewed.")
            } else {
                Text("Snapshot preview").help("This preview does not receive live updates.")
            }
            Spacer(minLength: 8)
            if let rendered = reader.rendered {
                Text("\(rendered.wordCount) words").monospacedDigit().fixedSize()
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.bar)
    }

    private var streamStatus: String {
        let source = reader.streamSourceName ?? String(localized: "Live stream")
        if reader.streamPaused { return String(localized: "\(source) · Paused") }
        if reader.streamError != nil { return String(localized: "Live preview unavailable") }
        return reader.streamIsReceiving ? String(localized: "\(source) · Live") : String(localized: "Waiting for a live stream")
    }

    private var streamSymbol: String {
        if reader.streamPaused { return "pause.circle" }
        return reader.streamError == nil ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle"
    }
}
