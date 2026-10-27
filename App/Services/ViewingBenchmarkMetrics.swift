import Foundation

/// Developer-only measurement contract. The native entry point is compiled only
/// with MARGINED_BENCHMARK; normal builds never consume benchmark manifests.
struct ViewingBenchmarkRequest: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case cold, warm, refresh }
    enum Presentation: String, Codable, Sendable { case collapsed, expanded }
    let version: Int
    let kind: Kind
    let sourceFile: String
    let expectedMarker: String
    let sampleCount: Int
    var expectedMath = 0
    var expectedDiagrams = 0
    var presentation: Presentation? = nil
    var expectedThreads: Int? = nil
    var expectedMessages: Int? = nil
    var expectedAttached: Int? = nil

    func validatedSource(manifestURL: URL) throws -> (url: URL, text: String) {
        guard version == 1, (1...100).contains(sampleCount),
              (0...200).contains(expectedMath), (0...20).contains(expectedDiagrams),
              [expectedThreads, expectedMessages, expectedAttached].compactMap({ $0 }).allSatisfy({ (0...200_000).contains($0) }),
              expectedAttached == nil || expectedThreads == nil || expectedAttached! <= expectedThreads!,
              kind != .cold || sampleCount == 1,
              manifestURL.isFileURL,
              !sourceFile.isEmpty, sourceFile == (sourceFile as NSString).lastPathComponent,
              sourceFile.hasSuffix(".md"),
              expectedMarker.hasPrefix("MARGINED-BENCHMARK-"), expectedMarker.count <= 160 else {
            throw ViewingBenchmarkError.invalidRequest
        }
        let directory = manifestURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let url = directory.appendingPathComponent(sourceFile)
        guard url.resolvingSymlinksInPath() == url,
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ViewingBenchmarkError.invalidRequest
        }
        let text = try MarkdownSource.read(url)
        guard text.hasPrefix("# " + expectedMarker + "\n") else { throw ViewingBenchmarkError.invalidRequest }
        return (url, text)
    }
}

struct ViewingBenchmarkMeasurement: Codable, Sendable {
    let index: Int
    let pid: Int32
    let requestNS: UInt64
    let renderReadyNS: UInt64
    let frameNS: UInt64
    var geometry: [String: Double] = [:]
    var renderPhases: [String: UInt64]? = nil
    var rendererTotalNS: UInt64? = nil
    var layoutReadyNS: UInt64? = nil
    var discussionLayout: ViewingBenchmarkDiscussionLayout? = nil
    var openingLifecycle: [String: UInt64]? = nil

    init(index: Int, pid: Int32, requestNS: UInt64, renderReadyNS: UInt64, frameNS: UInt64) throws {
        guard index >= 0, pid > 0, requestNS > 0,
              renderReadyNS >= requestNS, frameNS >= renderReadyNS else {
            throw ViewingBenchmarkError.invalidMeasurement
        }
        self.index = index; self.pid = pid; self.requestNS = requestNS
        self.renderReadyNS = renderReadyNS; self.frameNS = frameNS
    }
    var renderMilliseconds: Double { Double(renderReadyNS - requestNS) / 1_000_000 }
    var frameMilliseconds: Double { Double(frameNS - requestNS) / 1_000_000 }
    enum CodingKeys: String, CodingKey {
        case index, pid, geometry
        case renderPhases = "render_phases", rendererTotalNS = "renderer_total_ns"
        case layoutReadyNS = "layout_ready_ns", discussionLayout = "discussion_layout"
        case openingLifecycle = "opening_lifecycle"
        case requestNS = "request_ns", renderReadyNS = "render_ready_ns", frameNS = "frame_ns"
    }
}

struct ViewingBenchmarkDiscussionLayout: Codable, Sendable {
    let threadCount: Int
    let messageCount: Int
    let attachedCount: Int
    var laidOutCards = 0
    var historyThread: String? = nil
    var historyMessages = 0
    var historyGeometry: [String: Double]? = nil
    enum CodingKeys: String, CodingKey {
        case threadCount = "thread_count", messageCount = "message_count", attachedCount = "attached_count"
        case laidOutCards = "laid_out_cards", historyThread = "history_thread"
        case historyMessages = "history_messages", historyGeometry = "history_geometry"
    }
}

enum ViewingBenchmarkError: Error { case invalidRequest, invalidMeasurement }

#if MARGINED_BENCHMARK
/// Exact document/artwork predicate shared by the native Mac and mobile probes.
enum ViewingBenchmarkDOM {
    static let script = """
        const main = document.querySelector('main#document');
        if (document.readyState !== 'complete' || document.fonts.status !== 'loaded' || main?.querySelector('h1')?.textContent !== marker) return false;
        const math = Array.from(main.querySelectorAll('span.margined-math'));
        const diagrams = Array.from(main.querySelectorAll('figure.margined-diagram'));
        return math.length === expectedMath && diagrams.length === expectedDiagrams
            && math.every(node => node.querySelectorAll('math').length === 1)
            && diagrams.every(node => node.querySelectorAll(':scope > img').length === 1
                && node.querySelector(':scope > img').getAttribute('src').startsWith('data:image/svg+xml'))
            && Array.from(main.querySelectorAll('img')).every(image => image.complete && image.naturalWidth > 0);
        """
}
#endif
