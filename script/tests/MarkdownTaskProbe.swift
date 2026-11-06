import Foundation
import XCTest
#if MARGINED_READER_STATE_PROBE
import AppKit
#endif
@testable import Margined

// Links the actual reader objects without MarginedApp.o or its application loop.
@main
struct MarkdownTaskProbe {
    static func main() async {
        do {
            #if MARGINED_READER_STATE_PROBE
            // Link actual state objects without the app entrypoint/delegate.
            // This process is explicitly forbidden from activating or showing UI.
            let application = NSApplication.shared
            guard application.setActivationPolicy(.prohibited) else { exit(2) }
            let suite = XCTestSuite(name: "Noninteractive reader state")
            suite.addTest(ChecklistStateTests.defaultTestSuite)
            suite.addTest(ResponseStateTests.defaultTestSuite)
            guard suite.testCaseCount > 0 else { exit(2) }
            suite.run()
            guard suite.testRun?.hasSucceeded == true else { exit(1) }
            return
            #else
            let suite = XCTestSuite(name: "Task and response mapping")
            suite.addTest(MarkdownTaskTests.defaultTestSuite)
            suite.addTest(MarkdownResponseTests.defaultTestSuite)
            guard suite.testCaseCount > 0 else { exit(2) }
            suite.run()
            guard suite.testRun?.hasSucceeded == true else { exit(1) }
            try await verify()
            #endif
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func verify() async throws {
        let fixtures: [(String, [String])] = [
            ("- [ ] One `echo a | cat`.\n- [x] Two `echo b | cat`.\n",
             ["One echo a | cat.", "Two echo b | cat."]),
            ("- [ ] One ``echo `a` | cat``.\n- [ ] Two ``echo `b` | cat``.\n",
             ["One echo `a` | cat.", "Two echo `b` | cat."]),
            ("- [ ] Café \\| 日本語\n- [x] Two \\| pipes\n",
             ["Café | 日本語", "Two | pipes"]),
            ("- [ ] Run commands.\n  ```sh\n  echo a | cat\n  ```\n- [x] Finish.\n",
             ["Run commands. echo a | cat", "Finish."]),
            ((0..<50).map { "- [ ] Task \($0) `echo a | cat`.\n" }.joined(),
             (0..<50).map { "Task \($0) echo a | cat." })
        ]
        for (source, labels) in fixtures {
            let rendered = try await MarkdownRenderer.shared.render(source, mapTasks: true)
            guard rendered.checkboxCount == labels.count,
                  rendered.tasks.map(\.label) == labels else {
                throw failure("Expected \(labels.count) exact task mappings, got \(rendered.tasks.count); HTML: \(rendered.html)")
            }
            for task in rendered.tasks {
                let bytes = Data(source.utf8)
                let changed = try MarkdownTasks.patch(bytes, expectedSource: source, task: task, checked: !task.checked)
                guard changed.count == bytes.count, zip(bytes, changed).filter({ $0 != $1 }).count == 1 else {
                    throw failure("A checkbox edit changed more than its one source byte")
                }
                var expected = Array(bytes)
                expected[task.utf8Offset] = task.checked ? 32 : 120
                guard changed == Data(expected) else { throw failure("Wrong source byte edited") }
            }
            print("PASS \(labels.count)/\(rendered.checkboxCount) exact mappings and one-byte edits")
        }
        if CommandLine.arguments.count >= 2 {
            let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
            let rendered = try await MarkdownRenderer.shared.render(source, mapTasks: true)
            let discussions = try DiscussionCodec.parse(source)
            guard rendered.checkboxCount == 3, rendered.tasks.count == 3,
                  discussions.diagnostics.isEmpty, discussions.threads.count == 1,
                  discussions.threads[0].messages.count == 2,
                  discussions.threads[0].messages[1].inReplyTo == discussions.threads[0].messages[0].id else {
                throw failure("Authoring skill example failed its real codec/task contract")
            }
            print("PASS skill example: 3 mappings, 1 thread, 2 messages, linked reply")
        }
        for path in CommandLine.arguments.dropFirst(2) {
            let source = try String(contentsOfFile: path, encoding: .utf8)
            let rendered = try await MarkdownRenderer.shared.render(source, mapTasks: true)
            guard rendered.checkboxCount == 3, rendered.tasks.count == 3 else {
                throw failure("Build 14 authoring sample must have 3 exact task mappings")
            }
            for task in rendered.tasks {
                let changed = try MarkdownTasks.patch(Data(source.utf8), expectedSource: source, task: task, checked: !task.checked)
                guard zip(Data(source.utf8), changed).filter({ $0 != $1 }).count == 1 else {
                    throw failure("Build 14 sample did not preserve a one-byte checkbox edit")
                }
            }
            print("PASS Build 14 authoring sample: 3 mappings and one-byte edits")
        }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "MarkdownTaskProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
