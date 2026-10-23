import Foundation

private final class ImagePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let contents: Data

    init(url: URL, contents: Data) {
        presentedItemURL = url
        self.contents = contents
        super.init()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }

    func relinquishPresentedItem(toReader reader: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
        // A real presenter makes its current bytes available before allowing the
        // read, just as coordinated document/provider access requires.
        do { try contents.write(to: presentedItemURL!) }
        catch { fatalError("Fixture preparation failed: \(error)") }
        reader(nil)
    }
}

@main
struct LocalImageDataProbe {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let mode = CommandLine.arguments[1]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("figure.png")
        let expected = Data([137, 80, 78, 71, 13, 10, 26, 10])
        try Data().write(to: image)
        switch mode {
        case "coordination":
            let presenter = ImagePresenter(url: image, contents: expected)
            NSFileCoordinator.addFilePresenter(presenter)
            defer { NSFileCoordinator.removeFilePresenter(presenter) }
            let actual = try await LocalImageData.read(image)
            guard actual == expected else {
                throw NSError(domain: "ImageRegression", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Image read bypassed the presenter's current bytes"])
            }
        case "bounded":
            try Data(repeating: 1, count: 65).write(to: image)
            do {
                _ = try await LocalImageData.read(image, maximumBytes: 64)
                throw NSError(domain: "ImageRegression", code: 2)
            } catch ReaderError.tooLarge { }
        case "directory":
            do {
                _ = try await LocalImageData.read(folder)
                throw NSError(domain: "ImageRegression", code: 3)
            } catch let error as NSError where error.domain != "ImageRegression" { }
        case "cancelled":
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await LocalImageData.read(image)
                throw NSError(domain: "ImageRegression", code: 4)
            } catch is CancellationError { }
        default: fatalError("Unknown case")
        }
        print("PASS \(mode)")
    }
}
