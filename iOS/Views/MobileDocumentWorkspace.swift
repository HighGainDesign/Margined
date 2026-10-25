import SwiftUI

/// One native navigation stack retains its document root while presenting conversations.
struct MobileDocumentWorkspace: View {
    @Bindable var reader: MobileReaderState
    let openFolder: () -> Void
    let closeFile: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var measuredWidth: WorkspaceWidth?
    @StateObject private var readingPage: MobileReadingPage

    @MainActor
    init(reader: MobileReaderState, openFolder: @escaping () -> Void, closeFile: @escaping () -> Void) {
        self.reader = reader; self.openFolder = openFolder; self.closeFile = closeFile
        _readingPage = StateObject(wrappedValue: MobileReadingPage(reader: reader))
    }

    private struct WorkspaceWidth: Equatable {
        let viewport: CGSize
        let width: Double
    }
    private func availableWidth(in viewport: CGSize) -> Double? {
        // A new viewport has no current measurement yet. Preserve its existing
        // presentation until the active content reports its usable width; zero
        // would briefly rebuild compact navigation even between wide windows.
        guard let measuredWidth, measuredWidth.viewport == viewport else { return nil }
        return min(Double(viewport.width), measuredWidth.width)
    }

    private func report(_ width: Double, in viewport: CGSize, for route: MobileDiscussionRoute?) {
        let activeRoute = reader.discussionUsesMargin ? nil : reader.discussionNavigationPath.last
        guard activeRoute == route, width.isFinite, width > 0 else { return }
        measuredWidth = .init(viewport: viewport, width: width)
    }

    /// Native navigation is a projection of the retained discussion intent.
    func navigationBinding() -> Binding<[MobileDiscussionRoute]> {
        let document = reader.documentGeneration, presentation = reader.discussionLayoutGeneration
        return Binding(get: { reader.discussionUsesMargin ? [] : reader.discussionNavigationPath },
            set: { path in
                // A queued native pop belongs to the presentation that created
                // its binding, even if a newer layout has become compact again.
                guard document == reader.documentGeneration,
                      presentation == reader.discussionLayoutGeneration,
                      !reader.discussionUsesMargin else { return }
                reader.discussionNavigationPath = path
            })
    }

    var body: some View {
        GeometryReader { geometry in
            let fits: Bool? = textSize.isAccessibilitySize ? false : availableWidth(in: geometry.size).map { width in
                DiscussionMarginLayout.canShowMargin(width: width - 1,
                    bodyFont: reader.discussionMargin?.bodyFont ?? 16 * reader.zoom,
                    horizontalInsets: reader.discussionMargin?.horizontalInsets ?? 48, outlineWidth: 0)
            }
            NavigationStack(path: navigationBinding()) {
                MobileReaderView(reader: reader, openFolder: openFolder, closeFile: closeFile,
                    readingPage: readingPage, viewport: geometry.size, contentWidthChanged: { report($0, in: geometry.size, for: nil) })
                    .navigationTitle(reader.title).navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(for: MobileDiscussionRoute.self) { route in
                        switch route {
                        case .list:
                            MobileDiscussionList(reader: reader, viewport: geometry.size,
                                contentWidthChanged: { report($0, in: geometry.size, for: route) })
                        case .thread(let key):
                            MobileDiscussionThread(reader: reader, key: key, viewport: geometry.size,
                                contentWidthChanged: { report($0, in: geometry.size, for: route) })
                        }
                    }
            }
            .onChange(of: fits, initial: true) { _, value in
                guard let value else { return }
                reader.discussionUsesMargin = value
            }
            .background { MobilePrintPresenter(reader: reader).allowsHitTesting(false).accessibilityHidden(true) }
            .overlay {
                MobileDiscussionFilePickerPresenter(reader: reader).frame(width: 0, height: 0)
                if let sheet = reader.discussionSheet { MobileDiscussionSheetPresenter(reader: reader, sheet: sheet).id(sheet.id) }
            }
        }
    }
}

/// Attach before navigation/toolbar modifiers so reports exclude their chrome.
struct MobileWorkspaceWidthReporter: ViewModifier {
    let viewport: CGSize
    let active: Bool
    let report: (Double) -> Void
    private struct Measurement {
        let size: CGSize
        let viewport: CGSize
    }
    @State private var measurement: Measurement?
    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { value in
                measurement = .init(size: value, viewport: viewport)
                report(Double(value.width))
            }
            .onAppear { replayCurrentWidth() }
            .onChange(of: active) { _, ownsLayout in
                if ownsLayout { replayCurrentWidth() }
            }
    }
    private func replayCurrentWidth() {
        // A retained root may already have its final size when ownership changes.
        // A width from another viewport must wait for a fresh layout instead.
        guard let measurement, measurement.viewport == viewport,
              measurement.size.width > 0 else { return }
        report(Double(measurement.size.width))
    }
}
