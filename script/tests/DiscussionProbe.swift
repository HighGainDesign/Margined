import XCTest

@main
struct DiscussionProbe {
    static func main() {
        let suite = XCTestSuite(name: "Margined discussion contract")
        suite.addTest(MarkdownSourceEditsTests.defaultTestSuite)
        suite.addTest(SourceFileEditTests.defaultTestSuite)
        suite.addTest(SourceFileGateTests.defaultTestSuite)
        suite.addTest(DiscussionSessionTests.defaultTestSuite)
        suite.addTest(DiscussionCodecTests.defaultTestSuite)
        suite.addTest(DiscussionAnchorTests.defaultTestSuite)
        guard suite.testCaseCount > 0 else { exit(2) }
        suite.run()
        if suite.testRun?.hasSucceeded != true { exit(1) }
    }
}
