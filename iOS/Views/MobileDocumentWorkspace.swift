import SwiftUI
import UIKit

enum MobileReaderPanelLayout {
    static let inspectorWidth = 340.0
    static let outlineWidth = 240.0

    static func canDockInspector(width: Double, bodyFont: Double, horizontalInsets: Double) -> Bool {
        canDock(width: width, panelWidth: inspectorWidth, bodyFont: bodyFont, horizontalInsets: horizontalInsets)
    }
    static func canDockOutline(width: Double, bodyFont: Double, horizontalInsets: Double) -> Bool {
        canDock(width: width, panelWidth: outlineWidth, bodyFont: bodyFont, horizontalInsets: horizontalInsets)
    }
    private static func canDock(width: Double, panelWidth: Double, bodyFont: Double, horizontalInsets: Double) -> Bool {
        guard width.isFinite, width > 0, bodyFont.isFinite, bodyFont > 0,
              horizontalInsets.isFinite, horizontalInsets >= 0 else { return false }
        // reader.css uses 44pt gutters, reducing them to 22pt in compact content.
        // Reserve the full gutters so showing a panel cannot change whether it fits.
        let minimum = DiscussionMarginLayout.minimumDocumentWidth(bodyFont: bodyFont,
            horizontalInsets: max(88, horizontalInsets), outlineWidth: 0)
        return width >= minimum + panelWidth + 1
    }
}

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
        let measurement = WorkspaceWidth(viewport: viewport, width: width)
        guard measuredWidth != measurement else { return }
        measuredWidth = measurement
    }

    /// Native navigation is a projection of the retained discussion intent.
    func navigationBinding() -> Binding<[MobileDiscussionRoute]> {
        let document = reader.documentGeneration, presentation = reader.discussionLayoutGeneration
        let inspector = reader.inspector
        return Binding(get: { reader.discussionUsesMargin ? [] : reader.discussionNavigationPath },
            set: { path in
                // A queued native pop belongs to the presentation that created
                // its binding, even if a newer layout has become compact again.
                guard document == reader.documentGeneration,
                      presentation == reader.discussionLayoutGeneration,
                      inspector == .discussions, inspector == reader.inspector,
                      !reader.discussionUsesMargin else { return }
                reader.discussionNavigationPath = path
            })
    }

    var body: some View {
        GeometryReader { geometry in
            let fits: Bool? = textSize.isAccessibilitySize ? false : availableWidth(in: geometry.size).map { width in
                MobileReaderPanelLayout.canDockInspector(width: width,
                    bodyFont: reader.discussionMargin?.bodyFont ?? 16 * reader.zoom,
                    horizontalInsets: reader.discussionMargin?.horizontalInsets ?? 88)
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
            .background {
                MobileNavigationWidthReporter(active: active) { width in
                    if measurement?.viewport != viewport || measurement?.size.width != CGFloat(width) {
                        measurement = .init(size: CGSize(width: CGFloat(width), height: 0), viewport: viewport)
                    }
                    // Another navigation leaf may have replaced the shared
                    // measurement since this leaf last reported the same size.
                    // Only the workspace can decide that a report is redundant.
                    report(width)
                }
                .allowsHitTesting(false).accessibilityHidden(true)
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

/// Lists may propose their full bounds while document content is already inset.
/// Use the same native navigation area for either presentation.
private struct MobileNavigationWidthReporter: UIViewRepresentable {
    let active: Bool
    let report: (Double) -> Void

    func makeUIView(context: Context) -> MobileNavigationWidthView {
        let view = MobileNavigationWidthView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.isOpaque = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: MobileNavigationWidthView, context: Context) {
        view.active = active
        view.report = report
        view.requestMeasurement()
    }

    static func dismantleUIView(_ view: MobileNavigationWidthView, coordinator: ()) {
        view.active = false
        view.report = nil
    }
}

@MainActor
private final class MobileNavigationWidthView: UIView {
    var active = false {
        didSet { if !active { stopObservingGeometry() } }
    }
    var report: ((Double) -> Void)?
    private var queued = false
    private var waitingForTransition = false
    private var geometryObserver: MobileNavigationGeometryView?

    override func layoutSubviews() {
        super.layoutSubviews()
        requestMeasurement()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        requestMeasurement()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopObservingGeometry() }
        else { requestMeasurement() }
    }

    private func observeGeometry(of nativeArea: UIView) {
        guard geometryObserver?.superview !== nativeArea else { return }
        stopObservingGeometry()
        let observer = MobileNavigationGeometryView()
        observer.isUserInteractionEnabled = false
        observer.isAccessibilityElement = false
        observer.accessibilityElementsHidden = true
        observer.isOpaque = false
        observer.backgroundColor = .clear
        observer.translatesAutoresizingMaskIntoConstraints = false
        observer.changed = { [weak self] in self?.requestMeasurement() }
        geometryObserver = observer
        // A constrained reader or margin can keep its own size when the native
        // window shrinks. Observe the navigation area independently of it.
        nativeArea.insertSubview(observer, at: 0)
        NSLayoutConstraint.activate([
            observer.leadingAnchor.constraint(equalTo: nativeArea.leadingAnchor),
            observer.trailingAnchor.constraint(equalTo: nativeArea.trailingAnchor),
            observer.topAnchor.constraint(equalTo: nativeArea.topAnchor),
            observer.bottomAnchor.constraint(equalTo: nativeArea.bottomAnchor)
        ])
    }

    private func stopObservingGeometry() {
        geometryObserver?.changed = nil
        geometryObserver?.removeFromSuperview()
        geometryObserver = nil
    }

    func requestMeasurement() {
        guard active, window != nil, !queued else { return }
        queued = true
        // Deliver outside UIKit/SwiftUI's current layout transaction.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queued = false
            self.measureWhenSettled()
        }
    }

    private func measureWhenSettled() {
        guard active, window != nil else { return }
        var responder: UIResponder? = self
        var navigation: UINavigationController?
        while let current = responder {
            if let controller = current as? UIViewController,
               let owner = controller.navigationController {
                navigation = owner
                break
            }
            responder = current.next
        }
        guard let navigation, let nativeArea = navigation.viewIfLoaded,
              nativeArea.window === window else { return }
        observeGeometry(of: nativeArea)
        if let transition = navigation.transitionCoordinator {
            guard !waitingForTransition else { return }
            waitingForTransition = true
            let registered = transition.animate(alongsideTransition: nil) { [weak self] _ in
                self?.waitingForTransition = false
                self?.requestMeasurement()
            }
            if !registered { waitingForTransition = false }
            return
        }
        guard let top = navigation.topViewController?.viewIfLoaded,
              top.window === window else { return }
        let width = Double(top.safeAreaLayoutGuide.layoutFrame.width)
        guard width.isFinite, width > 0 else { return }
        report?(width)
    }
}

/// A noninteractive native-area observer, owned only while its reporter is active.
@MainActor
private final class MobileNavigationGeometryView: UIView {
    var changed: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        changed?()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        changed?()
    }
}
