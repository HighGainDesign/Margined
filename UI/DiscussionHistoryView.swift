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
                imageFailed: imageFailed, openFile: openFile))
            // Establish identity before the state and native coordinator exist.
            .id(Identity(document: documentID, thread: thread.id))
    }
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
    @State private var html: String?
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
    }
    private var renderKey: RenderKey {
        .init(thread: thread, appearance: appearance, remote: loadRemoteImages,
              language: documentLanguage, locale: locale.identifier, timeZone: timeZone.identifier)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).textSelection(.enabled) }
            if let html {
                DiscussionHistoryWebView(html: html, fontSize: fontSize,
                    imageGeneration: imageGeneration, scope: scope)
            } else { ProgressView("Reading discussions…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(height: 240)
        .task(id: renderKey) {
            do {
                let rendered = try await MarkdownRenderer.shared.renderDiscussion(thread,
                    loadRemoteImages: loadRemoteImages, appearance: appearance,
                    documentLanguage: documentLanguage, locale: locale, timeZone: timeZone, includeContext: false)
                guard !Task.isCancelled, scope.isCurrent() else { return }
                html = rendered.html; error = nil
            } catch is CancellationError {
                // A hidden conversation or replaced document owns no callbacks.
            } catch {
                guard !Task.isCancelled, scope.isCurrent() else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
