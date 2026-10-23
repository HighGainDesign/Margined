import XCTest

@main
struct DiscussionProbe {
    static func main() {
        let suite = DiscussionCodecTests.defaultTestSuite
        guard suite.testCaseCount > 0 else { exit(2) }
        suite.run()
        if suite.testRun?.hasSucceeded != true { exit(1) }
    }
}
