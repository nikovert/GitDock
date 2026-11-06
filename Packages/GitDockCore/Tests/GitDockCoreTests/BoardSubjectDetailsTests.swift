import Foundation
import XCTest
@testable import GitDockCore

final class BoardSubjectDetailsTests: XCTestCase {
    func testPullRequestUsesMatchingRepositoryAndRequestedReviewers() throws {
        let other = pullRequest(
            id: "other", repository: "other/widget", number: 12,
            title: "Wrong PR", author: "eve", requested: ["mallory"]
        )
        let wanted = pullRequest(
            id: "wanted", repository: "acme/widget", number: 12,
            title: "Repair kiln feed", author: "alice", requested: ["bob"],
            reviewers: ["bob", "carol"]
        )
        let subject = BoardSubject.pullRequest(try PullRequestKey(url: wanted.url))

        let details = BoardSubjectDetails.resolve(
            subject: subject, pullRequests: [other, wanted], stacks: []
        )

        XCTAssertEqual(details?.primary.title, "Repair kiln feed")
        XCTAssertEqual(details?.primary.author?.displayName, "alice")
        XCTAssertEqual(details?.primary.requestedReviewers?.map(\.displayName), ["bob"])
        XCTAssertEqual(details?.primary.reviewers.map(\.displayName), ["bob", "carol"])
        XCTAssertEqual(details?.members.map(\.id), [])
    }

    func testStackUsesRootAndExposesEachMember() throws {
        let root = pullRequest(
            id: "root", repository: "acme/widget", number: 12,
            title: "Prepare kiln", author: "alice", requested: ["bob"], position: 1
        )
        let child = pullRequest(
            id: "child", repository: "acme/widget", number: 13,
            title: "Tune controller", author: "carol", requested: ["dave"], position: 2
        )
        let stack = PullRequestStack(
            id: "stack-1", number: 7, pullRequests: [root, child]
        )
        let subject = BoardSubject.stack(try PullRequestKey(url: root.url))

        let details = BoardSubjectDetails.resolve(
            subject: subject, pullRequests: [child, root], stacks: [stack]
        )

        XCTAssertEqual(details?.primary.id, "root")
        XCTAssertEqual(details?.members.map(\.title), ["Prepare kiln", "Tune controller"])
        XCTAssertEqual(details?.members.last?.author?.displayName, "carol")
    }

    private func pullRequest(
        id: String,
        repository: String,
        number: Int,
        title: String,
        author: String,
        requested: [String],
        reviewers: [String] = [],
        position: Int? = nil
    ) -> PullRequestPresentation {
        PullRequestPresentation(
            id: id, repositoryID: repository, repositoryNameWithOwner: repository,
            number: number, title: title,
            url: URL(string: "https://github.com/\(repository)/pull/\(number)")!,
            isDraft: false,
            author: PullRequestAuthorPresentation(id: author, displayName: author, avatarURL: nil),
            reviewDecision: .reviewRequired,
            stackMembership: position.map {
                PullRequestStackMembership(id: "stack-1", number: 7, size: 2, position: $0)
            },
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            requestedReviewers: requested.map {
                ReviewerPresentation(id: $0, displayName: $0, avatarURL: nil, kind: .person)
            },
            reviewers: reviewers.map {
                ReviewerPresentation(id: $0, displayName: $0, avatarURL: nil, kind: .person)
            }
        )
    }
}
