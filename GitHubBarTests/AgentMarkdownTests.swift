import XCTest
@testable import GitHubBar

final class AgentMarkdownTests: XCTestCase {
    func testFencedCodePreservesLiteralContentAndLanguage() {
        let blocks = AgentMarkdownBlock.parse("**Explanation**\n\n```swift\nlet x = \"**literal**\"\n```\nDone.")
        XCTAssertEqual(blocks, [.prose("**Explanation**\n"), .code(language: "swift", text: "let x = \"**literal**\""), .prose("Done.")])
    }

    func testUnclosedCodeFenceIsReadableWhileAnswerIsIncomplete() {
        XCTAssertEqual(AgentMarkdownBlock.parse("```\na\n\nb"), [.code(language: "", text: "a\n\nb")])
    }
}
