import XCTest
@testable import GitDockCore

final class PRReviewThreadTests: XCTestCase {
    private let key = try! PullRequestKey(url: URL(string: "https://github.com/org/repo/pull/1")!)

    func testRepliesAreGroupedByRootEvenWhenTheyArriveOutOfOrder() {
        let root = PRReviewComment(id: "root", author: "a", body: "question", path: "new.swift", line: 2, side: .left)
        let reply = PRReviewComment(id: "reply", author: "b", body: "answer", path: "new.swift", line: 2, replyToID: "root", side: .left)
        let nested = PRReviewComment(id: "nested", author: "c", body: "thanks", replyToID: "reply")
        let threads = PRReviewThread.group([nested, reply, root])
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].root?.id, "root")
        XCTAssertEqual(threads[0].comments.map(\.id), ["root", "nested", "reply"])
        XCTAssertEqual(snapshot(comments: []).anchor(for: threads[0])?.side, .left)
    }

    func testBothSidesAndRenamedCurrentPathResolveButPreviousPathNeverDoes() {
        let snapshot = snapshot(comments: [])
        for side in PRReviewDraftComment.Side.allCases {
            let current = PRReviewComment(id: "root", author: "a", body: "comment", path: "new.swift", line: 2, side: side)
            XCTAssertEqual(snapshot.anchor(for: PRReviewThread.group([current])[0])?.line, 2)
            let previous = PRReviewComment(id: "old", author: "a", body: "comment", path: "old.swift", line: 2, side: side)
            XCTAssertNil(snapshot.anchor(for: PRReviewThread.group([previous])[0]))
        }
    }

    func testOutdatedUnknownSideMissingLinePatchAndRootNeverAttach() {
        let cases = [
            PRReviewComment(id: "old", author: "a", body: "old", path: "new.swift", line: 2, side: .right, isOutdated: true),
            PRReviewComment(id: "unknown", author: "a", body: "side missing", path: "new.swift", line: 2),
            PRReviewComment(id: "line", author: "a", body: "missing line", path: "new.swift", side: .right),
            PRReviewComment(id: "outside", author: "a", body: "outside", path: "new.swift", line: 99, side: .right),
            PRReviewComment(id: "reply", author: "a", body: "root unavailable", path: "new.swift", line: 2, replyToID: "missing", side: .right)
        ]
        for comment in cases {
            let thread = PRReviewThread.group([comment])[0]
            XCTAssertNil(snapshot(comments: []).anchor(for: thread))
            XCTAssertNotNil(snapshot(comments: []).anchorUnavailableReason(for: thread))
        }
        let current = PRReviewThread.group([PRReviewComment(id: "root", author: "a", body: "ok", path: "new.swift", line: 2, side: .right)])[0]
        XCTAssertNil(snapshot(comments: [], patch: nil).anchor(for: current))
    }

    func testReplyCyclesDoNotLoopOrProduceAnAnchor() {
        let comments = [PRReviewComment(id: "a", author: "a", body: "a", replyToID: "b"),
                        PRReviewComment(id: "b", author: "b", body: "b", replyToID: "a")]
        let threads = PRReviewThread.group(comments)
        XCTAssertEqual(threads.count, 1)
        XCTAssertNil(threads[0].root)
        XCTAssertNil(snapshot(comments: []).anchor(for: threads[0]))
    }

    private func snapshot(comments: [PRReviewComment], patch: String? = "@@ -1,3 +1,3 @@\n same\n-old\n+new\n tail") -> PRReviewSnapshot {
        PRReviewSnapshot(key: key, title: "PR", body: "", author: "author", createdAt: nil, updatedAt: .now,
            headSHA: "head", baseSHA: "base", files: [PRSearchFile(path: "new.swift", previousPath: "old.swift", patch: patch, additions: 1, deletions: 1)],
            notices: [], comments: comments, checksSummary: "", fileListComplete: true)
    }
}
