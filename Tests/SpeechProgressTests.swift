import XCTest
@testable import Margined

@MainActor
final class SpeechProgressTests: XCTestCase {
    func testProgressResumesExactAndInsertedContentWithoutPersistingDocumentText() async throws {
        let name = "MarginedTests.Progress.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SpeechProgressStore(defaults: defaults)
        defer { store.clear() }
        let url = URL(fileURLWithPath: "/private/tmp/confidential-name.md")
        let first = try await document("# Private heading\n\nSecret paragraph.\n")
        store.save(url: url, document: first, index: 1, offset: 7)
        XCTAssertEqual(store.resume(url: url, document: first)?.index, 1)
        XCTAssertEqual(store.resume(url: url, document: first)?.offset, 7)
        let inserted = try await document("Introduction.\n\n# Private heading\n\nSecret paragraph.\n")
        XCTAssertEqual(store.resume(url: url, document: inserted)?.index, 2)
        let persisted = String(describing: defaults.dictionaryRepresentation())
        XCTAssertFalse(persisted.contains("Secret paragraph"))
        XCTAssertFalse(persisted.contains("Private heading"))
        XCTAssertFalse(persisted.contains("confidential-name"))
        store.clear()
        XCTAssertNil(store.resume(url: url, document: first))
    }

    func testChangedOrUnrelatedDocumentDoesNotReuseOldPosition() async throws {
        let defaults = UserDefaults(suiteName: "MarginedTests.Progress.\(UUID())")!
        let store = SpeechProgressStore(defaults: defaults); defer { store.clear() }
        let url = URL(fileURLWithPath: "/tmp/first.md")
        let first = try await document("Original.")
        store.save(url: url, document: first, index: 0, offset: 3)
        let changed = try await document("Completely different.")
        XCTAssertNil(store.resume(url: url, document: changed))
        XCTAssertNil(store.resume(url: URL(fileURLWithPath: "/tmp/second.md"), document: first))
    }

    func testOldestProgressIsEvictedAndCompletedReadingDoesNotOfferResume() async throws {
        let defaults = UserDefaults(suiteName: "MarginedTests.Progress.\(UUID())")!
        let store = SpeechProgressStore(defaults: defaults); defer { store.clear() }
        let doc = try await document("A paragraph.")
        for index in 0..<101 {
            store.save(url: URL(fileURLWithPath: "/tmp/doc-\(index).md"), document: doc, index: 0, offset: 2)
        }
        XCTAssertNil(store.resume(url: URL(fileURLWithPath: "/tmp/doc-0.md"), document: doc))
        let last = URL(fileURLWithPath: "/tmp/doc-100.md")
        XCTAssertNotNil(store.resume(url: last, document: doc))
        store.save(url: last, document: doc, index: 0, offset: doc.segments[0].text.utf16.count)
        XCTAssertNil(store.resume(url: last, document: doc))
    }

    private func document(_ text: String) async throws -> SpeechDocument {
        let rendered = try await MarkdownRenderer.shared.render(text, prepareSpeech: true)
        return try XCTUnwrap(rendered.speech)
    }
}
