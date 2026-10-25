import SwiftUI

/// One rendered history per expanded conversation. Editable state stays in the
/// native composer; this view only renders immutable, saved messages.
struct DiscussionHistoryView: View {
    let documentID: UUID
    let thread: DiscussionThread
    let fileURL: URL?
    let appearance: DocumentAppearance
    let loadRemoteImages: Bool
    let zoom: Double
    let imageGeneration: Int
    let documentLanguage: String?
    let isCurrent: @MainActor () -> Bool
    let imageFailed: @MainActor (String) -> Void
    let openFile: @MainActor (URL) -> Void
    var playback: DiscussionHistoryPlayback? = nil
    @Environment(\.sizeCategory) private var sizeCategory

    private struct Identity: Hashable { let document: UUID; let thread: String }
    private var fontSize: Double {
        #if os(iOS)
        Double(MobileWebTypography.fontSize(category: sizeCategory.uiCategory, zoom: zoom))
        #else
        16 * (zoom.isFinite ? min(3, max(0.5, zoom)) : 1)
        #endif
    }

    var body: some View {
        DiscussionHistoryContent(thread: thread, appearance: appearance,
            loadRemoteImages: loadRemoteImages, documentLanguage: documentLanguage,
            fontSize: fontSize, imageGeneration: imageGeneration,
            scope: DiscussionHistoryScope(fileURL: fileURL, isCurrent: isCurrent,
                imageFailed: imageFailed, openFile: openFile), playback: playback)
            .id(Identity(document: documentID, thread: thread.id))
    }
}

/// A projection of the existing document's playback owner, never a second player.
@MainActor
struct DiscussionHistoryPlayback {
    let session: SpeechSession?
    let options: SpeechOptions
    let conversationID: String?
    let enabled: Bool
    let pendingVersion: Bool
    let preparing: Bool
    let read: @MainActor (SpeechDocument) -> Void
    let toggle: @MainActor () -> Void
    let stop: @MainActor () -> Void
    let resumeDocument: @MainActor () -> Void
    let showLatest: @MainActor () -> Void
}

@MainActor
struct DiscussionHistoryScope {
    let fileURL: URL?
    let isCurrent: @MainActor () -> Bool
    let imageFailed: @MainActor (String) -> Void
    let openFile: @MainActor (URL) -> Void
}

private struct DiscussionHistoryContent: View {
    let thread: DiscussionThread
    let appearance: DocumentAppearance
    let loadRemoteImages: Bool
    let documentLanguage: String?
    let fontSize: Double
    let imageGeneration: Int
    let scope: DiscussionHistoryScope
    let playback: DiscussionHistoryPlayback?
    @State private var prepared: Prepared?
    @State private var error: String?
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    private struct RenderKey: Equatable {
        let thread: DiscussionThread
        let appearance: DocumentAppearance
        let remote: Bool
        let language: String?
        let locale: String
        let timeZone: String
        let speechOptions: SpeechOptions?
    }
    private struct Prepared {
        let key: RenderKey
        let output: RenderedMarkdown
    }
    private var renderKey: RenderKey {
        .init(thread: thread, appearance: appearance, remote: loadRemoteImages,
              language: documentLanguage, locale: locale.identifier, timeZone: timeZone.identifier,
              speechOptions: playback?.options)
    }
    private var ownsConversation: Bool { playback?.conversationID == thread.id }
    private var highlight: DiscussionSpeechHighlight {
        guard ownsConversation, let session = playback?.session, session.isActive,
              let prepared, prepared.key == renderKey, let speech = prepared.output.speech,
              session.document?.fingerprint == speech.fingerprint,
              session.document?.options == speech.options else { return .inactive }
        return .init(elementID: session.currentSegment?.elementID, follow: session.followReading)
    }
    private var controlHeight: CGFloat {
        #if os(iOS)
        44
        #else
        24
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let playback { controls(playback) }
            VStack(alignment: .leading, spacing: 8) {
                if let error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).textSelection(.enabled) }
                if let prepared {
                    DiscussionHistoryWebView(html: prepared.output.html, fontSize: fontSize,
                        imageGeneration: imageGeneration, scope: scope, speech: highlight)
                } else { ProgressView("Reading discussions…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.frame(height: 240)
        }
        .task(id: renderKey) {
            let key = renderKey
            do {
                let output = try await MarkdownRenderer.shared.renderDiscussion(thread,
                    loadRemoteImages: loadRemoteImages, appearance: appearance,
                    documentLanguage: documentLanguage, prepareSpeech: playback != nil,
                    speechOptions: playback?.options ?? SpeechOptions(),
                    locale: locale, timeZone: timeZone, includeContext: false)
                guard !Task.isCancelled, scope.isCurrent() else { return }
                prepared = Prepared(key: key, output: output); error = nil
            } catch is CancellationError {
                // A hidden conversation or replaced document owns no callbacks.
            } catch {
                guard !Task.isCancelled, scope.isCurrent() else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func controls(_ playback: DiscussionHistoryPlayback) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if ownsConversation, playback.session?.isActive == true {
                Label("Reading Conversation", systemImage: "speaker.wave.2")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    transport(playback)
                    Spacer(minLength: 8)
                    if ownsConversation { resumeDocument(playback) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { transport(playback) }
                    if ownsConversation { resumeDocument(playback) }
                }
            }
            if playback.pendingVersion {
                Text("A newer saved version is waiting.").font(.caption).foregroundStyle(.secondary)
                Button("Show Latest") { if scope.isCurrent() { playback.showLatest() } }.disabled(!playback.enabled)
                    .frame(minHeight: controlHeight)
            }
        }
        .buttonStyle(.bordered)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation-playback-" + thread.id)
    }

    @ViewBuilder
    private func transport(_ playback: DiscussionHistoryPlayback) -> some View {
        if ownsConversation, playback.session?.isActive == true || playback.preparing {
            if playback.preparing, playback.session?.isActive != true {
                ProgressView().controlSize(.small).accessibilityLabel("Read Aloud")
            } else if playback.session?.status == .playing {
                Button("Pause", systemImage: "pause.fill") { if scope.isCurrent() { playback.toggle() } }
                    .accessibilityLabel("Pause Conversation").frame(minHeight: controlHeight)
            } else {
                Button("Play", systemImage: "play.fill") { if scope.isCurrent() { playback.toggle() } }
                    .accessibilityLabel("Resume Conversation").frame(minHeight: controlHeight)
            }
            Button("Stop", systemImage: "stop.fill") { if scope.isCurrent() { playback.stop() } }
                .accessibilityLabel("Stop Conversation").frame(minHeight: controlHeight)
        } else {
            Button("Read Conversation", systemImage: "speaker.wave.2") {
                guard scope.isCurrent(), let prepared, prepared.key == renderKey,
                      let speech = prepared.output.speech else { return }
                playback.read(speech)
            }
            .disabled(!playback.enabled || prepared?.key != renderKey || prepared?.output.speech?.segments.isEmpty != false)
            .frame(minHeight: controlHeight)
            .accessibilityIdentifier("read-conversation-" + thread.id)
            .accessibilityHint("Reads saved messages and authors. Unposted replies are excluded.")
        }
    }

    private func resumeDocument(_ playback: DiscussionHistoryPlayback) -> some View {
        Button("Resume Document", systemImage: "doc.text") { if scope.isCurrent() { playback.resumeDocument() } }
            .disabled(!playback.enabled).frame(minHeight: controlHeight)
    }
}
