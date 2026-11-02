import Foundation
import GitHubBarCore
import XCTest
@testable import GitHubBar

@MainActor
final class WorkspaceReviewTests: XCTestCase {
    func testContextUsesOutstandingHumansAndPreservesUnknownRoster() {
        let requested = [reviewer("me", .person), reviewer("review-bot", .bot), reviewer("team", .team)]
        let context = WorkspaceReviewContext.make(
            pullRequest(requested: requested), accountLogin: "me", stackURL: nil
        )
        XCTAssertEqual(context.requestedHumans, ["me"])
        XCTAssertEqual(context.requestedTeamCount, 1)
        XCTAssertTrue(context.reviewersComplete)
        XCTAssertEqual(context.headSHA, "head-1")
        XCTAssertEqual(context.priority(in: .empty).rank, 1)

        let unknown = WorkspaceReviewContext.make(
            pullRequest(requested: nil), accountLogin: "me", stackURL: nil
        )
        XCTAssertFalse(unknown.reviewersComplete)
        XCTAssertTrue(unknown.requestedHumans.isEmpty)
        XCTAssertEqual(unknown.priority(in: .empty).rank, 1)
    }

    func testSortingUsesEffectivePriorityThenOldestGitHubUpdate() throws {
        let old = context(number: 1, updatedAt: 10)
        let recent = context(number: 2, updatedAt: 20)
        var manual = context(number: 3, updatedAt: 30)
        manual.authorLogin = "colleague"
        var board = LocalWorkspaceDocument.empty
        board.setEntry(BoardEntry(
            subject: .pullRequest(try PullRequestKey(url: URL(string: manual.prURL)!)), priority: .high
        ))

        let sorted = [recent, manual, old].sorted {
            WorkspaceReviewContext.precedes($0, $1, in: board)
        }

        XCTAssertEqual(sorted.map(\.prURL), [manual.prURL, old.prURL, recent.prURL])
        XCTAssertEqual(manual.priority(in: board).reason, "Manual priority")
    }

    func testAutomaticPriorityPreservesNotesAndTags() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let subject = BoardSubject.pullRequest(try PullRequestKey(url: pullRequest().url))
        try await fixture.store.update {
            $0.setEntry(BoardEntry(subject: subject, priority: .high, tagIDs: ["blocked"], note: "Keep me"))
        }
        await fixture.model.reload()

        fixture.model.setPriority(.none, for: subject)
        await eventually { fixture.model.document.entry(for: subject)?.priority == nil }

        let entry = try await fixture.store.load().entry(for: subject)
        XCTAssertNil(entry?.priority)
        XCTAssertEqual(entry?.note, "Keep me")
        XCTAssertEqual(entry?.tagIDs, ["blocked"])
    }

    func testLegacyWorkerFileIsNeverChangedOrUsedAsCurrentMetadata() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var context = context(number: 1, updatedAt: 100)
        context.headSHA = "stale-worker-head"
        let oldContext = context
        try await fixture.reviews.update { $0.contexts[oldContext.prURL] = oldContext; $0.enabled = true }
        let file = fixture.directory.appendingPathComponent("agent-reviews.json")
        let before = try Data(contentsOf: file)
        await fixture.model.reload()
        fixture.model.updateWorkload(state())
        await fixture.model.reload()
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(fixture.model.reviewContext(for: pullRequest()).headSHA, "head-1")
    }

    func testPriorityAuthorsPersistWithoutReviewWorker() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.model.setPriorityAuthors(["COLLEAGUE"])
        var pr = context(number: 1)
        pr.authorLogin = "colleague"
        XCTAssertEqual(fixture.model.reviewPriority(for: pr).rank, 2)
        fixture.model.setPriorityAuthors([])
    }

    private func fixture() -> (
        directory: URL, store: LocalWorkspaceStore, reviews: AgentReviewStore, model: WorkspaceModel
    ) {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/workspace-tests/\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "WorkspaceReviewTests-\(UUID())")!
        let store = LocalWorkspaceStore(directoryURL: directory)
        let reviews = AgentReviewStore(directoryURL: directory)
        return (directory, store, reviews, WorkspaceModel(
            store: store, sessions: AgentSessionManager(store: store, tmuxURL: nil), reviewStore: reviews, defaults: defaults
        ))
    }

    private func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for workspace update", file: file, line: line)
    }

    private func state() -> AppPresentationState {
        var value = AppPresentationState.empty
        value.accountConnection = .connected(login: "me", accessCoverage: AccessCoverage(isComplete: true))
        value.needsYourReview = [pullRequest()]
        return value
    }

    private func reviewer(_ login: String, _ kind: ReviewerPresentation.Kind) -> ReviewerPresentation {
        ReviewerPresentation(id: login, displayName: login, avatarURL: nil, kind: kind)
    }

    private func pullRequest(requested: [ReviewerPresentation]? = []) -> PullRequestPresentation {
        PullRequestPresentation(
            id: "pr", repositoryID: "repo", repositoryNameWithOwner: "org/repo", number: 1,
            title: "A pull request", url: URL(string: "https://github.com/org/repo/pull/1")!,
            isDraft: false,
            author: PullRequestAuthorPresentation(id: "author", displayName: "author", avatarURL: nil),
            updatedAt: Date(timeIntervalSince1970: 10), requestedReviewers: requested,
            reviewers: [reviewer("not-outstanding", .person)], headSHA: "head-1"
        )
    }

    private func context(number: Int, updatedAt: TimeInterval = 10) -> AgentPRContext {
        AgentPRContext(
            prURL: "https://github.com/org/repo/pull/\(number)", authorLogin: "author",
            accountLogin: "me", headSHA: "head-1", updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}
