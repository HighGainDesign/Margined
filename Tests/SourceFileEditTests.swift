import Foundation
import XCTest
import Darwin
#if MARGINED_DISCUSSION_PROBE
#elseif os(iOS)
@testable import MarginediOS
#else
@testable import Margined
#endif

final class SourceFileEditTests: XCTestCase {
    // A successful save must preserve prose/metadata and return the actual new file identity.
    func testVariableLengthReplacementPreservesPermissionsAndExtendedAttributes() throws {
        try withFile { url in
            let original = Data([255,254]) + "# café\r\n".data(using: .utf16LittleEndian)!
            try original.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
            let attr = Data("retained".utf8)
            try attr.withUnsafeBytes { bytes in
                guard setxattr(url.path, "design.highgain.margined.test", bytes.baseAddress, bytes.count, 0, 0) == 0 else { throw posixError() }
            }
            let snapshot = try SourceFileEdit.read(url)
            let replacement = Data([255,254]) + "# café\r\n\r\nA longer reply 日本.\r\n".data(using: .utf16LittleEndian)!
            let saved = try SourceFileEdit.commit(replacement, expected: snapshot)
            XCTAssertEqual(saved.data, replacement)
            XCTAssertEqual(try Data(contentsOf: url), replacement)
            XCTAssertEqual(try SourceFileEdit.read(url), saved)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o640)
            var buffer = [UInt8](repeating: 0, count: 32)
            let length = getxattr(url.path, "design.highgain.margined.test", &buffer, buffer.count, 0, 0)
            XCTAssertEqual(length, 8)
            XCTAssertEqual(Data(buffer.prefix(max(0, length))), attr)
        }
    }

    func testRefusesEncodingOnlyChangeAndByteIdenticalReplacement() throws {
        try withFile { url in
            let data = Data("# Text\n".utf8)
            try data.write(to: url)
            let snapshot = try SourceFileEdit.read(url)
            let encoded = Data([239,187,191]) + data
            try encoded.write(to: url)
            XCTAssertThrowsError(try SourceFileEdit.commit(Data("changed".utf8), expected: snapshot))
            XCTAssertEqual(try Data(contentsOf: url), encoded)
            try data.write(to: url)
            let current = try SourceFileEdit.read(url)
            try data.write(to: url, options: .atomic)
            XCTAssertThrowsError(try SourceFileEdit.commit(Data("changed".utf8), expected: current))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testConditionalUndoDoesNotRestoreOverANewerAgentVersion() throws {
        try withFile { url in
            let original = Data("# Original\n".utf8), reply = Data("# Original\n\nReply.\n".utf8)
            try original.write(to: url)
            let baseline = try SourceFileEdit.read(url)
            let posted = try SourceFileEdit.commit(reply, expected: baseline)
            let undone = try SourceFileEdit.commit(original, expected: posted)
            XCTAssertEqual(undone.data, original)
            let redone = try SourceFileEdit.commit(reply, expected: undone)
            let newer = Data("# Agent changed the prose\n".utf8)
            try newer.write(to: url, options: .atomic)
            XCTAssertThrowsError(try SourceFileEdit.commit(original, expected: redone))
            XCTAssertEqual(try Data(contentsOf: url), newer)
        }
    }

    func testSymlinkSaveUpdatesItsTargetWithoutReplacingTheLink() throws {
        try withFile { url in
            try Data("body".utf8).write(to: url)
            let link = url.deletingLastPathComponent().appendingPathComponent("alias.md")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            let snapshot = try SourceFileEdit.read(link)
            let saved = try SourceFileEdit.commit(Data("body and reply".utf8), expected: snapshot)
            XCTAssertEqual(saved.url, link)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), url.path)
            XCTAssertEqual(try Data(contentsOf: url), Data("body and reply".utf8))
        }
    }

    func testReadOnlyOrRemovedFileCannotBeRecreatedBySave() throws {
        try withFile { url in
            let original = Data("body".utf8)
            try original.write(to: url)
            let snapshot = try SourceFileEdit.read(url)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
            XCTAssertThrowsError(try SourceFileEdit.commit(Data("reply".utf8), expected: snapshot))
            XCTAssertEqual(try Data(contentsOf: url), original)
            try FileManager.default.removeItem(at: url)
            XCTAssertThrowsError(try SourceFileEdit.commit(Data("reply".utf8), expected: snapshot))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testExternalReplacementWhileStagingIsNotOverwritten() throws {
        try withFile { url in
            try Data("body".utf8).write(to: url)
            let snapshot = try SourceFileEdit.read(url)
            let newer = Data("Agent replacement during staging".utf8)
            let manager = StagingFileManager { try newer.write(to: url, options: .atomic) }
            XCTAssertThrowsError(try SourceFileEdit.commit(Data("reply".utf8), expected: snapshot, fileManager: manager))
            XCTAssertEqual(try Data(contentsOf: url), newer)
        }
    }

    func testUnverifiedReplacementRetainsOriginalWithoutRestoringOverNewerFile() throws {
        try withFile { url in
            let original = Data("original body".utf8), newer = Data("Later agent version".utf8)
            try original.write(to: url)
            let snapshot = try SourceFileEdit.read(url)
            let manager = ReplacementFileManager { try newer.write(to: url, options: .atomic) }
            do {
                _ = try SourceFileEdit.commit(Data("reply".utf8), expected: snapshot, fileManager: manager)
                XCTFail("A replaced pathname must not be reported Saved")
            } catch SourceFileEdit.Failure.uncertain(let recovery, _) {
                defer { try? FileManager.default.removeItem(at: recovery.deletingLastPathComponent()) }
                XCTAssertEqual(try Data(contentsOf: recovery), original)
                XCTAssertEqual(try Data(contentsOf: url), newer)
            }
        }
    }

    func testMarkerWriteKeepsInodeAndRejectsAnIdenticalReplacedFile() throws {
        try withFile { url in
            let source = "- [ ] Task\r\n"
            let bytes = Data([254,255]) + source.data(using: .utf16BigEndian)!
            try bytes.write(to: url)
            let snapshot = try SourceFileEdit.read(url)
            let saved = try SourceFileEdit.setMarker(120, at: 3, was: 32, expected: snapshot)
            XCTAssertEqual(saved.identity, snapshot.identity)
            XCTAssertEqual(saved.data, Data([254,255]) + "- [x] Task\r\n".data(using: .utf16BigEndian)!)
            try saved.data.write(to: url, options: .atomic)
            XCTAssertThrowsError(try SourceFileEdit.setMarker(32, at: 3, was: 120, expected: saved))
            XCTAssertEqual(try Data(contentsOf: url), saved.data)
        }
    }

    private func withFile(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("Document.md"))
    }
    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

// Real file operations remain in place; these inject another writer precisely
// at the OS copy/replace boundary, rather than mocking a successful commit.
private final class StagingFileManager: FileManager, @unchecked Sendable {
    let interfere: () throws -> Void
    init(_ interfere: @escaping () throws -> Void) { self.interfere = interfere; super.init() }
    override func copyItem(at source: URL, to destination: URL) throws {
        try super.copyItem(at: source, to: destination)
        if destination.lastPathComponent == "Replacement.md" { try interfere() }
    }
}
private final class ReplacementFileManager: FileManager, @unchecked Sendable {
    let interfere: () throws -> Void
    init(_ interfere: @escaping () throws -> Void) { self.interfere = interfere; super.init() }
    override func replaceItem(at originalItemURL: URL, withItemAt newItemURL: URL, backupItemName: String?, options: FileManager.ItemReplacementOptions = [], resultingItemURL resultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        try super.replaceItem(at: originalItemURL, withItemAt: newItemURL, backupItemName: backupItemName, options: options, resultingItemURL: resultingURL)
        try interfere()
    }
}
