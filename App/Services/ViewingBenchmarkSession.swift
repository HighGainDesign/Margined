#if MARGINED_BENCHMARK
import AppKit
import Darwin
import WebKit

/// Opt-in instrumentation for an optimized developer build. Normal releases do
/// not include this entry point, its file writes or its document automation.
@MainActor
final class ViewingBenchmarkSession {
    private(set) static var current: ViewingBenchmarkSession?
    private let manifest: URL
    private var documents: [MarkdownDocument] = []
    private var samples: [ViewingBenchmarkMeasurement] = []
    private var expectedMarker = ""
    private var renderReadyNS: UInt64?
    private var renderOutput: RenderedMarkdown?
    private var cardFrames: [ObjectIdentifier: [String: CGRect]] = [:]
    private var request: ViewingBenchmarkRequest?
    private var finished = false
    private var watchdog: Task<Void, Never>?

    private init(manifest: URL) { self.manifest = manifest }

    static func startIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["MARGINED_BENCHMARK_REQUEST"] else { return false }
        let session = ViewingBenchmarkSession(manifest: URL(fileURLWithPath: path))
        current = session
        Task { await session.run() }
        return true
    }

    func didRender(source: String, output: RenderedMarkdown) {
        guard renderReadyNS == nil, !expectedMarker.isEmpty,
              source.hasPrefix("# " + expectedMarker + "\n") else { return }
        renderOutput = output
        renderReadyNS = DispatchTime.now().uptimeNanoseconds
    }

    func didLayoutDiscussions(reader: ReaderState, frames: [String: CGRect]) {
        guard !expectedMarker.isEmpty, reader.source.hasPrefix("# " + expectedMarker + "\n") else { return }
        cardFrames[ObjectIdentifier(reader)] = frames
    }

    private func run() async {
        do {
            #if DEBUG
            throw ViewingBenchmarkSessionError.requiresOptimizedBuild
            #else
            let data = try Data(contentsOf: manifest, options: .mappedIfSafe)
            guard data.count < 16_384 else { throw ViewingBenchmarkError.invalidRequest }
            let request = try JSONDecoder().decode(ViewingBenchmarkRequest.self, from: data)
            self.request = request
            let source = try request.validatedSource(manifestURL: manifest)
            guard !FileManager.default.fileExists(atPath: resultURL.path) else {
                throw ViewingBenchmarkError.invalidRequest
            }
            watchdog = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30 * request.sampleCount + 20)) }
                catch { return }
                self?.finish(error: ViewingBenchmarkSessionError.timeout)
            }
            if request.kind == .cold {
                guard let input = ProcessInfo.processInfo.environment["MARGINED_BENCHMARK_START_NS"],
                      let start = UInt64(input), start > 0, start <= DispatchTime.now().uptimeNanoseconds else {
                    throw ViewingBenchmarkSessionError.invalidClock
                }
                let (_, sample) = try await open(source.url, marker: request.expectedMarker, index: 0, start: start)
                samples.append(sample)
            } else {
                let start = DispatchTime.now().uptimeNanoseconds
                let (initial, _) = try await open(source.url, marker: request.expectedMarker, index: -1, start: start)
                for index in 0..<request.sampleCount {
                    let marker = request.expectedMarker + "-revision-\(index)"
                    let text = source.text.replacingOccurrences(of: request.expectedMarker, with: marker)
                    if request.kind == .warm {
                        let url = manifest.deletingLastPathComponent().appendingPathComponent("warm-\(index).md")
                        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
                        let start = DispatchTime.now().uptimeNanoseconds
                        let (document, sample) = try await open(url, marker: marker, index: index, start: start)
                        samples.append(sample)
                        document.close()
                        documents.removeAll { $0 === document }
                        cardFrames.removeValue(forKey: ObjectIdentifier(document.reader))
                    } else {
                        // Cover different phases of the reader's actual one-second
                        // poll instead of always saving immediately after a poll.
                        let delays = [0, 173, 409, 683, 937]
                        try await Task.sleep(for: .milliseconds(delays[index % delays.count]))
                        expectedMarker = marker; renderReadyNS = nil; renderOutput = nil
                        let start = DispatchTime.now().uptimeNanoseconds
                        try Data(text.utf8).write(to: source.url, options: .atomic)
                        samples.append(try await frame(for: initial, marker: marker, index: index, start: start))
                    }
                }
            }
            finish(error: nil)
            #endif
        } catch { finish(error: error) }
    }

    private func open(_ url: URL, marker: String, index: Int, start: UInt64) async throws -> (MarkdownDocument, ViewingBenchmarkMeasurement) {
        expectedMarker = marker; renderReadyNS = nil; renderOutput = nil
        let document: MarkdownDocument = try await withCheckedThrowingContinuation { continuation in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
                if let document = document as? MarkdownDocument { continuation.resume(returning: document) }
                else { continuation.resume(throwing: error ?? ViewingBenchmarkSessionError.documentUnavailable) }
            }
        }
        documents.append(document)
        return (document, try await frame(for: document, marker: marker, index: index, start: start))
    }

    private func frame(for document: MarkdownDocument, marker: String, index: Int, start: UInt64) async throws -> ViewingBenchmarkMeasurement {
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        var previousFrames: [String: CGRect]?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard !finished else { throw CancellationError() }
            let reader = document.reader
            if let error = reader.errorMessage { throw NSError(domain: "MarginedBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            if let ready = renderReadyNS, let output = renderOutput,
               output.discussions?.source.utf8.elementsEqual(reader.source.utf8) == true,
               let window = document.windowControllers.first?.window, let view = window.contentView,
               let web = Self.webViews(in: view).first, web.url != nil, !web.isLoading,
               try await ViewingBenchmarkFrame.isCurrent(web, marker: marker,
                   expectedMath: request?.expectedMath ?? 0, expectedDiagrams: request?.expectedDiagrams ?? 0) {
                var layout = try discussionCensus(output)
                var history: (timestamp: UInt64, image: NSImage, geometry: [String: Double])?
                var capturedFrames: [String: CGRect]?
                let expanded = request?.presentation == .expanded
                if expanded {
                    guard let thread = output.discussions?.threads.first else { throw ViewingBenchmarkSessionError.discussionExpectation }
                    if !reader.showDiscussions || reader.discussions.selection != .thread(thread.id) || reader.discussions.filter != .all {
                        reader.discussions.filter = .all
                        reader.openDiscussion(thread.id)
                        try await Task.sleep(for: .milliseconds(10)); continue
                    }
                    let expectedCards = Set((output.discussions?.threads ?? []).map { "t:" + $0.id })
                    let attached = Set((output.discussionText?.anchorResults ?? [:]).filter { $0.value.status == .attached }.map(\.key))
                    guard let frames = cardFrames[ObjectIdentifier(reader)], Set(frames.keys) == expectedCards,
                          frames.values.allSatisfy({ $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }),
                          let margin = reader.discussionMargin, margin.sourceID == output.discussionText?.sourceID,
                          Set(margin.anchors.map(\.id)) == attached,
                          web.bounds.width <= (window.contentView?.bounds.width ?? 0) - 300 else {
                        try await Task.sleep(for: .milliseconds(10)); continue
                    }
                    guard previousFrames == frames else {
                        previousFrames = frames
                        try await Task.sleep(for: .milliseconds(10)); continue
                    }
                    var historyWeb: WKWebView?
                    for candidate in Self.webViews(in: view) where candidate !== web && candidate.url != nil && !candidate.isLoading {
                        if try await ViewingBenchmarkFrame.historyIsCurrent(candidate, thread: thread) { historyWeb = candidate; break }
                    }
                    guard let historyWeb else { try await Task.sleep(for: .milliseconds(10)); continue }
                    history = try await ViewingBenchmarkFrame.captureHistory(historyWeb, window: window, thread: thread)
                    capturedFrames = frames
                    layout.laidOutCards = frames.count
                    layout.historyThread = thread.id
                    layout.historyMessages = thread.messages.count
                    layout.historyGeometry = history?.geometry
                }
                // Elapsed readiness of the actual views, including history
                // preparation/verification; this is not pure CPU layout time.
                let layoutReady = DispatchTime.now().uptimeNanoseconds
                let capture = try await ViewingBenchmarkFrame.capture(web, window: window, marker: marker,
                    expectedMath: request?.expectedMath ?? 0, expectedDiagrams: request?.expectedDiagrams ?? 0)
                if let capturedFrames, cardFrames[ObjectIdentifier(reader)] != capturedFrames {
                    previousFrames = nil; continue
                }
                let imageName = index < 0 ? "warmup.png" : "frame-\(index).png"
                let bitmap = try save(capture.image, name: imageName)
                if let history {
                    _ = try save(history.image, name: index < 0 ? "history-warmup.png" : "history-frame-\(index).png")
                }
                var measurement = try ViewingBenchmarkMeasurement(index: max(index, 0), pid: getpid(), requestNS: start,
                    renderReadyNS: ready, frameNS: capture.timestamp)
                measurement.geometry = capture.geometry
                measurement.geometry["imageWidth"] = Double(bitmap.pixelsWide)
                measurement.geometry["imageHeight"] = Double(bitmap.pixelsHigh)
                measurement.renderPhases = output.benchmarkPhases
                measurement.rendererTotalNS = output.benchmarkTotalNS
                measurement.layoutReadyNS = layoutReady
                measurement.discussionLayout = layout
                return measurement
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ViewingBenchmarkSessionError.timeout
    }

    private func discussionCensus(_ output: RenderedMarkdown) throws -> ViewingBenchmarkDiscussionLayout {
        let threads = output.discussions?.threads ?? []
        let messages = threads.reduce(0) { $0 + $1.messages.count }
        let attached = output.discussionText?.anchorResults.values.filter { $0.status == .attached }.count ?? 0
        guard output.discussions?.diagnostics.isEmpty == true,
              request?.expectedThreads == nil || request?.expectedThreads == threads.count,
              request?.expectedMessages == nil || request?.expectedMessages == messages,
              request?.expectedAttached == nil || request?.expectedAttached == attached else {
            throw ViewingBenchmarkSessionError.discussionExpectation
        }
        return .init(threadCount: threads.count, messageCount: messages, attachedCount: attached)
    }

    private func save(_ image: NSImage, name: String) throws -> NSBitmapImageRep {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ViewingBenchmarkSessionError.emptySnapshot
        }
        try png.write(to: manifest.deletingLastPathComponent().appendingPathComponent(name), options: .withoutOverwriting)
        return bitmap
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap { webViews(in: $0) }
    }

    private var resultURL: URL { manifest.deletingLastPathComponent().appendingPathComponent("result.json") }

    private func finish(error: Error?) {
        guard !finished else { return }
        finished = true; watchdog?.cancel()
        documents.forEach { $0.close() }; documents.removeAll()
        do {
            let rows = try JSONSerialization.jsonObject(with: JSONEncoder().encode(samples))
            var payload: [String: Any] = ["schema": 1, "status": error == nil ? "ok" : "error",
                "kind": request?.kind.rawValue ?? "invalid", "samples": rows,
                "boundary": request?.presentation == .expanded ? "verified-discussion-frame-v1" : "verified-frame-v1",
                "presentation": request?.presentation?.rawValue ?? "collapsed",
                "expected_discussions": ["thread_count": request?.expectedThreads ?? samples.first?.discussionLayout?.threadCount ?? 0,
                    "message_count": request?.expectedMessages ?? samples.first?.discussionLayout?.messageCount ?? 0,
                    "attached_count": request?.expectedAttached ?? samples.first?.discussionLayout?.attachedCount ?? 0],
                "phase_clock": "elapsed-wall-nanoseconds; artwork may await another actor",
                "layout_boundary": "actual view/history readiness including verification, not pure CPU layout",
                "expected_math": request?.expectedMath ?? 0, "expected_diagrams": request?.expectedDiagrams ?? 0,
                "refresh_phase_delays_ms": [0, 173, 409, 683, 937],
                "appearance": ReaderPreferences.appearance(in: ReaderPreferences.defaults).rawValue,
                "wide": UserDefaults.standard.object(forKey: "wideLayout") as? Bool ?? true]
            #if DEBUG
            payload["configuration"] = "Debug"
            #else
            payload["configuration"] = "Release"
            #endif
            if let error { payload["error"] = String(describing: error) }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: resultURL, options: .withoutOverwriting)
        } catch {
            FileHandle.standardError.write(Data("Benchmark result could not be saved: \(error)\n".utf8))
            exit(1)
        }
        if error != nil { exit(1) }
        NSApp.terminate(nil)
    }
}

@MainActor
enum ViewingBenchmarkFrame {
    private static let world = WKContentWorld.world(name: "MarginedBenchmark")

    static func isCurrent(_ web: WKWebView, marker: String, expectedMath: Int = 0, expectedDiagrams: Int = 0) async throws -> Bool {
        try await web.callAsyncJavaScript("""
        const main = document.querySelector('main#document');
        if (document.readyState !== 'complete' || document.fonts.status !== 'loaded' || main?.querySelector('h1')?.textContent !== marker) return false;
        const math = Array.from(main.querySelectorAll('span.margined-math'));
        const diagrams = Array.from(main.querySelectorAll('figure.margined-diagram'));
        return math.length === expectedMath && diagrams.length === expectedDiagrams
            && math.every(node => node.querySelectorAll('math').length === 1)
            && diagrams.every(node => node.querySelectorAll(':scope > img').length === 1
                && node.querySelector(':scope > img').getAttribute('src').startsWith('data:image/svg+xml'))
            && Array.from(main.querySelectorAll('img')).every(image => image.complete && image.naturalWidth > 0);
        """, arguments: ["marker": marker, "expectedMath": expectedMath, "expectedDiagrams": expectedDiagrams], in: nil, contentWorld: world) as? Bool == true
    }

    static func historyIsCurrent(_ web: WKWebView, thread: DiscussionThread) async throws -> Bool {
        try await web.callAsyncJavaScript("""
        if (document.readyState !== 'complete' || document.fonts.status !== 'loaded'
            || !document.body.classList.contains('discussion-history')) return false;
        const articles = Array.from(document.querySelectorAll('main#document > article'));
        return JSON.stringify(articles.map(node => node.getAttribute('data-message-id'))) === JSON.stringify(ids)
            && articles.every(node => node.querySelector('header h3') && node.querySelector('.discussion-message-body'))
            && Array.from(document.querySelectorAll('main#document img')).every(image => image.complete && image.naturalWidth > 0);
        """, arguments: ["ids": thread.messages.map(\.id)], in: nil, contentWorld: world) as? Bool == true
    }

    static func captureHistory(_ web: WKWebView, window: NSWindow, thread: DiscussionThread) async throws -> (timestamp: UInt64, image: NSImage, geometry: [String: Double]) {
        guard visible(window), web.window === window, !web.isHiddenOrHasHiddenAncestor,
              let content = window.contentView,
              web.convert(web.bounds, to: content).intersects(content.bounds) else { throw ViewingBenchmarkSessionError.hiddenWindow }
        _ = try await web.callAsyncJavaScript("""
        await document.fonts.ready;
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        """, arguments: [:], in: nil, contentWorld: world)
        guard try await historyIsCurrent(web, thread: thread) else { throw ViewingBenchmarkSessionError.staleDocument }
        let dimensions = geometry(window, web)
        guard dimensions.values.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw ViewingBenchmarkSessionError.emptySnapshot }
        let image = try await web.takeSnapshot(configuration: nil)
        guard visible(window), try await historyIsCurrent(web, thread: thread) else { throw ViewingBenchmarkSessionError.staleDocument }
        guard image.size.width > 0, image.size.height > 0 else { throw ViewingBenchmarkSessionError.emptySnapshot }
        guard dimensions == geometry(window, web) else { throw ViewingBenchmarkSessionError.geometryChanged }
        return (DispatchTime.now().uptimeNanoseconds, image, dimensions)
    }

    static func capture(_ web: WKWebView, window: NSWindow, marker: String,
                        expectedMath: Int = 0, expectedDiagrams: Int = 0) async throws -> (timestamp: UInt64, image: NSImage, geometry: [String: Double]) {
        guard visible(window) else { throw ViewingBenchmarkSessionError.hiddenWindow }
        let settled = try await web.callAsyncJavaScript("""
        await document.fonts.ready;
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        return document.querySelector('main#document h1')?.textContent === marker;
        """, arguments: ["marker": marker], in: nil, contentWorld: world) as? Bool == true
        guard settled, try await isCurrent(web, marker: marker, expectedMath: expectedMath, expectedDiagrams: expectedDiagrams) else { throw ViewingBenchmarkSessionError.staleDocument }
        guard visible(window) else { throw ViewingBenchmarkSessionError.hiddenWindow }
        let dimensions = geometry(window, web)
        guard dimensions.values.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw ViewingBenchmarkSessionError.emptySnapshot }
        let image = try await web.takeSnapshot(configuration: nil)
        guard image.size.width > 0, image.size.height > 0 else { throw ViewingBenchmarkSessionError.emptySnapshot }
        guard visible(window) else { throw ViewingBenchmarkSessionError.hiddenWindow }
        guard dimensions == geometry(window, web) else { throw ViewingBenchmarkSessionError.geometryChanged }
        return (DispatchTime.now().uptimeNanoseconds, image, dimensions)
    }

    private static func geometry(_ window: NSWindow, _ web: WKWebView) -> [String: Double] {
        ["windowWidth": Double(window.contentView?.bounds.width ?? 0),
         "windowHeight": Double(window.contentView?.bounds.height ?? 0),
         "viewportWidth": Double(web.bounds.width), "viewportHeight": Double(web.bounds.height),
         "backingScale": Double(window.backingScaleFactor)]
    }

    private static func visible(_ window: NSWindow) -> Bool {
        window.isVisible && window.isOnActiveSpace && window.occlusionState.contains(.visible) && NSApp.isActive
    }
}

enum ViewingBenchmarkSessionError: Error {
    case hiddenWindow, staleDocument, emptySnapshot, timeout, invalidClock, documentUnavailable, requiresOptimizedBuild, geometryChanged, discussionExpectation
}
#endif
