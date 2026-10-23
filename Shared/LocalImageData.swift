import Foundation

/// File providers must make their current bytes available before an image read.
/// The accessor and coordinator stay on one worker thread for the whole read.
enum LocalImageData {
    @concurrent
    static func read(_ url: URL, maximumBytes: Int = MarkdownSource.maximumBytes) async throws -> Data {
        try Task.checkCancellation()
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result {
                try Task.checkCancellation()
                guard try coordinatedURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw URLError(.cannotOpenFile)
                }
                let file = try FileHandle(forReadingFrom: coordinatedURL)
                defer { try? file.close() }
                let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
                guard data.count <= maximumBytes else { throw ReaderError.tooLarge }
                return data
            }
        }
        try Task.checkCancellation()
        if let coordinationError { throw coordinationError }
        guard let result else { throw URLError(.cannotOpenFile) }
        return try result.get()
    }
}
