import Foundation
import Darwin
import Vision
import ImageIO

@main
struct SavedFrameRecognition {
    static func main() {
        do { try recognize() }
        catch {
            FileHandle.standardError.write(Data(("Saved-image recognition failed: " + String(describing: error) + "\n").utf8))
            exit(1)
        }
    }
    private static func recognize() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.arguments }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw Failure.image }
        let start = DispatchTime.now().uptimeNanoseconds
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(url: url, options: [:]).perform([request])
        let rows = (request.results ?? []).compactMap { result -> [String: Any]? in
            guard let text = result.topCandidates(1).first else { return nil }
            let b = result.boundingBox
            return ["text": text.string, "confidence": text.confidence,
                    "x": b.minX, "y": b.minY, "width": b.width, "height": b.height]
        }
        let data = try JSONSerialization.data(withJSONObject: ["width": width, "height": height,
            "observations": rows, "recognition_ns": DispatchTime.now().uptimeNanoseconds - start],
            options: [.sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    }
    enum Failure: Error { case arguments, image }
}
