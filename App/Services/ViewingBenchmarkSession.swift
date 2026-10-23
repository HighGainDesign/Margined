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

    func didRender(source: String) {
        guard renderReadyNS == nil, !expectedMarker.isEmpty,
              source.hasPrefix("# " + expectedMarker + "\n") else { return }
        renderReadyNS = DispatchTime.now().uptimeNanoseconds
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
                    } else {
                        // Cover different phases of the reader's actual one-second
                        // poll instead of always saving immediately after a poll.
                        let delays = [0, 173, 409, 683, 937]
                        try await Task.sleep(for: .milliseconds(delays[index % delays.count]))
                        expectedMarker = marker; renderReadyNS = nil
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
        expectedMarker = marker; renderReadyNS = nil
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
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard !finished else { throw CancellationError() }
            if let error = document.reader.errorMessage { throw NSError(domain: "MarginedBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            if let ready = renderReadyNS,
               let window = document.windowControllers.first?.window,
               let view = window.contentView, let web = Self.webView(in: view),
               web.url != nil, !web.isLoading,
               try await ViewingBenchmarkFrame.isCurrent(web, marker: marker,
                   expectedMath: request?.expectedMath ?? 0, expectedDiagrams: request?.expectedDiagrams ?? 0) {
                let capture = try await ViewingBenchmarkFrame.capture(web, window: window, marker: marker,
                    expectedMath: request?.expectedMath ?? 0, expectedDiagrams: request?.expectedDiagrams ?? 0)
                guard let tiff = capture.image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw ViewingBenchmarkSessionError.emptySnapshot
                }
                let imageName = index < 0 ? "warmup.png" : "frame-\(index).png"
                try png.write(to: manifest.deletingLastPathComponent().appendingPathComponent(imageName), options: .withoutOverwriting)
                var measurement = try ViewingBenchmarkMeasurement(index: max(index, 0), pid: getpid(), requestNS: start,
                    renderReadyNS: ready, frameNS: capture.timestamp)
                measurement.geometry = capture.geometry
                measurement.geometry["imageWidth"] = Double(bitmap.pixelsWide)
                measurement.geometry["imageHeight"] = Double(bitmap.pixelsHigh)
                return measurement
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ViewingBenchmarkSessionError.timeout
    }

    private static func webView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for child in view.subviews { if let web = webView(in: child) { return web } }
        return nil
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
                "boundary": "verified-frame-v1",
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
        if (document.readyState !== 'complete' || main?.querySelector('h1')?.textContent !== marker) return false;
        const math = Array.from(main.querySelectorAll('span.margined-math'));
        const diagrams = Array.from(main.querySelectorAll('figure.margined-diagram'));
        return math.length === expectedMath && diagrams.length === expectedDiagrams
            && math.every(node => node.querySelectorAll('math').length === 1)
            && diagrams.every(node => node.querySelectorAll(':scope > img').length === 1
                && node.querySelector(':scope > img').getAttribute('src').startsWith('data:image/svg+xml'))
            && Array.from(main.querySelectorAll('img')).every(image => image.complete && image.naturalWidth > 0);
        """, arguments: ["marker": marker, "expectedMath": expectedMath, "expectedDiagrams": expectedDiagrams], in: nil, contentWorld: world) as? Bool == true
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
    case hiddenWindow, staleDocument, emptySnapshot, timeout, invalidClock, documentUnavailable, requiresOptimizedBuild, geometryChanged
}
#endif
