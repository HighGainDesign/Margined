#if MARGINED_BENCHMARK
import Foundation
import UIKit
import WebKit
import Darwin

enum MobileViewingBenchmarkFailure: Error {
    case requiresOptimizedBuild, invalidClock, unsupportedPresentation
    case hiddenWindow, staleDocument, emptySnapshot, geometryChanged, timeout
}

/// Uses the production reader and its real file presenter. Only instrumented
/// developer builds can enter this path; a normal launch never reads a manifest.
@MainActor
final class MobileViewingBenchmarkSession {
    static private(set) var current: MobileViewingBenchmarkSession?
    private let reader: MobileReaderState
    private let manifest: URL
    private let openFile: @MainActor (URL) async -> Void
    private var request: ViewingBenchmarkRequest?
    private var expectedMarker = ""
    private var rendered: RenderedMarkdown?
    private var renderReadyNS: UInt64?
    private var samples: [ViewingBenchmarkMeasurement] = []
    private var watchdog: Task<Void, Never>?
    private var finished = false

    static func startIfRequested(reader: MobileReaderState,
        open: @escaping @MainActor (URL) async -> Void) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["MARGINED_BENCHMARK_REQUEST"] else { return false }
        guard current == nil else { return true }
        let session = Self(reader: reader, manifest: URL(fileURLWithPath: path), open: open)
        current = session
        Task { await session.run() }
        return true
    }

    private init(reader: MobileReaderState, manifest: URL,
        open: @escaping @MainActor (URL) async -> Void) {
        self.reader = reader; self.manifest = manifest; openFile = open
    }

    func didRender(reader: MobileReaderState, output: RenderedMarkdown) {
        guard !finished, reader === self.reader, renderReadyNS == nil, !expectedMarker.isEmpty,
              reader.source.hasPrefix("# " + expectedMarker + "\n"),
              output.taskSource.utf8.elementsEqual(reader.source.utf8) else { return }
        rendered = output; renderReadyNS = DispatchTime.now().uptimeNanoseconds
    }

    private func prepare(_ marker: String) {
        expectedMarker = marker; rendered = nil; renderReadyNS = nil
    }

    private func run() async {
        do {
            #if DEBUG
            throw MobileViewingBenchmarkFailure.requiresOptimizedBuild
            #else
            let data = try Data(contentsOf: manifest, options: .mappedIfSafe)
            guard data.count < 16_384 else { throw ViewingBenchmarkError.invalidRequest }
            let request = try JSONDecoder().decode(ViewingBenchmarkRequest.self, from: data)
            guard (request.presentation ?? .collapsed) == .collapsed else {
                throw MobileViewingBenchmarkFailure.unsupportedPresentation
            }
            self.request = request
            let source = try request.validatedSource(manifestURL: manifest)
            guard !FileManager.default.fileExists(atPath: resultURL.path),
                  ProcessInfo.processInfo.environment["MARGINED_TEST_PREFERENCES"] == "1" else {
                throw ViewingBenchmarkError.invalidRequest
            }
            watchdog = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30 * request.sampleCount + 20)) }
                catch { return }
                self?.finish(error: MobileViewingBenchmarkFailure.timeout)
            }
            prepare(request.expectedMarker)
            if request.kind == .cold {
                guard let value = ProcessInfo.processInfo.environment["MARGINED_BENCHMARK_START_NS"],
                      let start = UInt64(value), start > 0,
                      start <= DispatchTime.now().uptimeNanoseconds else {
                    throw MobileViewingBenchmarkFailure.invalidClock
                }
                await openFile(source.url)
                samples.append(try await frame(marker: request.expectedMarker, index: 0, start: start))
            } else {
                let start = DispatchTime.now().uptimeNanoseconds
                await openFile(source.url)
                _ = try await frame(marker: request.expectedMarker, index: -1, start: start)
                for index in 0..<request.sampleCount {
                    let marker = request.expectedMarker + "-revision-\(index)"
                    let text = source.text.replacingOccurrences(of: request.expectedMarker, with: marker)
                    if request.kind == .warm {
                        let url = manifest.deletingLastPathComponent().appendingPathComponent("warm-\(index).md")
                        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
                        prepare(marker)
                        let start = DispatchTime.now().uptimeNanoseconds
                        await openFile(url)
                        samples.append(try await frame(marker: marker, index: index, start: start))
                    } else {
                        let delays = [0, 173, 409, 683, 937]
                        try await Task.sleep(for: .milliseconds(delays[index % delays.count]))
                        prepare(marker)
                        let start = DispatchTime.now().uptimeNanoseconds
                        try Data(text.utf8).write(to: source.url, options: .atomic)
                        // Do not call refresh(): the normal file presenter must deliver this save.
                        samples.append(try await frame(marker: marker, index: index, start: start))
                    }
                }
            }
            finish(error: nil)
            #endif
        } catch { finish(error: error) }
    }

    private func frame(marker: String, index: Int, start: UInt64) async throws -> ViewingBenchmarkMeasurement {
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard !finished else { throw CancellationError() }
            if let error = reader.errorMessage { throw NSError(domain: "MarginedMobileBenchmark", code: 1,
                userInfo: [NSLocalizedDescriptionKey: error]) }
            if let ready = renderReadyNS, let output = rendered, !reader.isOpening, !reader.isRendering,
               output.taskSource.utf8.elementsEqual(reader.source.utf8) {
                let threads = output.discussions?.threads ?? []
                let messages = threads.reduce(0) { $0 + $1.messages.count }
                let attached = output.discussionText?.anchorResults.values.filter { $0.status == .attached }.count ?? 0
                guard output.discussions?.diagnostics.isEmpty == true,
                      request?.expectedThreads == nil || request?.expectedThreads == threads.count,
                      request?.expectedMessages == nil || request?.expectedMessages == messages,
                      request?.expectedAttached == nil || request?.expectedAttached == attached else {
                    throw ViewingBenchmarkError.invalidMeasurement
                }
                for window in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
                    where window.isKeyWindow {
                    for web in Self.webViews(in: window)
                        where web.url != nil && !web.isLoading && MobileViewingBenchmarkFrame.visibleWindow(web) != nil {
                        guard try await MobileViewingBenchmarkFrame.isCurrent(web, marker: marker,
                            expectedMath: request?.expectedMath ?? 0, expectedDiagrams: request?.expectedDiagrams ?? 0) else { continue }
                        let layout = DispatchTime.now().uptimeNanoseconds
                        let capture = try await MobileViewingBenchmarkFrame.capture(web, marker: marker,
                            expectedMath: request?.expectedMath ?? 0, expectedDiagrams: request?.expectedDiagrams ?? 0)
                        guard let bitmap = capture.image.cgImage, let png = capture.image.pngData(),
                              !output.benchmarkPhases.isEmpty, output.benchmarkTotalNS > 0 else {
                            throw MobileViewingBenchmarkFailure.emptySnapshot
                        }
                        let phases = output.benchmarkPhases, total = output.benchmarkTotalNS
                        let name = index < 0 ? "warmup.png" : "frame-\(index).png"
                        try png.write(to: manifest.deletingLastPathComponent().appendingPathComponent(name), options: .withoutOverwriting)
                        var result = try ViewingBenchmarkMeasurement(index: max(0, index), pid: getpid(),
                            requestNS: start, renderReadyNS: ready, frameNS: capture.timestamp)
                        result.geometry = capture.geometry
                        result.geometry["imageWidth"] = Double(bitmap.width)
                        result.geometry["imageHeight"] = Double(bitmap.height)
                        result.renderPhases = phases; result.rendererTotalNS = total; result.layoutReadyNS = layout
                        result.discussionLayout = .init(threadCount: threads.count, messageCount: messages, attachedCount: attached)
                        return result
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MobileViewingBenchmarkFailure.timeout
    }

    private static func webViews(in view: UIView) -> [WKWebView] {
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap { webViews(in: $0) }
    }

    private var resultURL: URL { manifest.deletingLastPathComponent().appendingPathComponent("result.json") }

    private func finish(error: Error?) {
        guard !finished else { return }
        finished = true; watchdog?.cancel()
        do {
            let rows = try JSONSerialization.jsonObject(with: JSONEncoder().encode(samples))
            var payload: [String: Any] = [
                "schema": 1, "status": error == nil ? "ok" : "error",
                "kind": request?.kind.rawValue ?? "invalid", "samples": rows,
                "boundary": "verified-frame-v1", "presentation": "collapsed",
                "expected_discussions": ["thread_count": request?.expectedThreads ?? 0,
                    "message_count": request?.expectedMessages ?? 0, "attached_count": request?.expectedAttached ?? 0],
                "phase_clock": "elapsed-wall-nanoseconds; artwork may await another actor",
                "layout_boundary": "actual native view readiness including verification, not pure CPU layout",
                "refresh_phase_delays_ms": [0, 173, 409, 683, 937],
                "appearance": reader.appearance.rawValue, "wide": reader.wide,
                "system_version": UIDevice.current.systemVersion,
                "warm_behavior": "normal file switching in the same application process"]
            #if targetEnvironment(simulator)
            payload["platform"] = "iOS Simulator"
            #else
            payload["platform"] = "iOS device"
            #endif
            #if DEBUG
            payload["configuration"] = "Debug"
            #else
            payload["configuration"] = "Release"
            #endif
            if let error { payload["error"] = String(describing: error) }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: resultURL, options: .withoutOverwriting)
            // The external owner captures the actual simulator screen before terminating this private app.
        } catch {
            FileHandle.standardError.write(Data(("Margined benchmark result: \(error)\n").utf8))
        }
    }
}

@MainActor
enum MobileViewingBenchmarkFrame {
    private static let world = WKContentWorld.world(name: "MarginedBenchmark")

    static func isCurrent(_ web: WKWebView, marker: String, expectedMath: Int = 0,
        expectedDiagrams: Int = 0) async throws -> Bool {
        try await web.callAsyncJavaScript(ViewingBenchmarkDOM.script,
            arguments: ["marker": marker, "expectedMath": expectedMath, "expectedDiagrams": expectedDiagrams],
            in: nil, contentWorld: world) as? Bool == true
    }

    static func capture(_ web: WKWebView, marker: String, expectedMath: Int = 0,
        expectedDiagrams: Int = 0) async throws -> (timestamp: UInt64, image: UIImage, geometry: [String: Double]) {
        guard let window = visibleWindow(web) else { throw MobileViewingBenchmarkFailure.hiddenWindow }
        _ = try await web.callAsyncJavaScript("""
        await document.fonts.ready;
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        """, arguments: [:], in: nil, contentWorld: world)
        guard try await isCurrent(web, marker: marker, expectedMath: expectedMath, expectedDiagrams: expectedDiagrams) else {
            throw MobileViewingBenchmarkFailure.staleDocument
        }
        let dimensions = geometry(window, web)
        let image = try await web.takeSnapshot(configuration: nil)
        guard visibleWindow(web) === window else { throw MobileViewingBenchmarkFailure.hiddenWindow }
        guard dimensions == geometry(window, web) else { throw MobileViewingBenchmarkFailure.geometryChanged }
        guard try await isCurrent(web, marker: marker, expectedMath: expectedMath, expectedDiagrams: expectedDiagrams) else {
            throw MobileViewingBenchmarkFailure.staleDocument
        }
        guard image.size.width > 0, image.size.height > 0 else { throw MobileViewingBenchmarkFailure.emptySnapshot }
        return (DispatchTime.now().uptimeNanoseconds, image, dimensions)
    }

    fileprivate static func visibleWindow(_ web: WKWebView) -> UIWindow? {
        guard UIApplication.shared.applicationState == .active, let window = web.window,
              window.isKeyWindow, window.windowScene?.activationState == .foregroundActive,
              web.bounds.width > 0, web.bounds.height > 0,
              web.convert(web.bounds, to: window).intersects(window.bounds) else { return nil }
        var current: UIView? = web
        while let view = current {
            if view.isHidden || view.alpha <= 0.01 { return nil }
            current = view.superview
        }
        return window
    }

    private static func geometry(_ window: UIWindow, _ web: WKWebView) -> [String: Double] {
        ["windowWidth": Double(window.bounds.width), "windowHeight": Double(window.bounds.height),
         "viewportWidth": Double(web.bounds.width), "viewportHeight": Double(web.bounds.height),
         "backingScale": Double(window.windowScene?.screen.scale ?? 0),
         "safeAreaTop": Double(window.safeAreaInsets.top), "safeAreaBottom": Double(window.safeAreaInsets.bottom)]
    }
}
#endif
