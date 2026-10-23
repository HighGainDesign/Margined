import Foundation

/// Developer-only measurement contract. The native entry point is compiled only
/// with MARGINED_BENCHMARK; normal builds never consume benchmark manifests.
struct ViewingBenchmarkRequest: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case cold, warm, refresh }
    let version: Int
    let kind: Kind
    let sourceFile: String
    let expectedMarker: String
    let sampleCount: Int
    var expectedMath = 0
    var expectedDiagrams = 0

    func validatedSource(manifestURL: URL) throws -> (url: URL, text: String) {
        guard version == 1, (1...100).contains(sampleCount),
              (0...200).contains(expectedMath), (0...20).contains(expectedDiagrams),
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
        case requestNS = "request_ns", renderReadyNS = "render_ready_ns", frameNS = "frame_ns"
    }
}

enum ViewingBenchmarkError: Error { case invalidRequest, invalidMeasurement }
