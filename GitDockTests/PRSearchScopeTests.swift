import GitDockCore
import Foundation
import XCTest
@testable import GitDock

final class PRSearchScopeTests: XCTestCase {
    func testPinnedScopeDefaultsToPinsEvenWithoutCurrentPRs() {
        var state = connectedState()
        state.repositoryScope = .pinned
        state.pinnedRepositories = [PinnedRepository(id: "a", nameWithOwner: "org/pinned")]
        state.availableRepositories = [RepositoryChoice(id: "b", nameWithOwner: "org/other")]
        XCTAssertEqual(PRSearchScope.defaultRepositories(in: state), ["org/pinned"])
    }

    func testAllScopeUsesAccountRepositoriesAndDeduplicatesNames() {
        var state = connectedState()
        state.availableRepositories = [
            RepositoryChoice(id: "b", nameWithOwner: "org/b"),
            RepositoryChoice(id: "a", nameWithOwner: "Org/A"),
            RepositoryChoice(id: "a", nameWithOwner: "org/a")
        ]
        XCTAssertEqual(PRSearchScope.defaultRepositories(in: state), ["org/a", "org/b"])
    }

    func testDisconnectedSnapshotDoesNotSupplyPrivateSearchContext() {
        var state = AppPresentationState.empty
        state.availableRepositories = [RepositoryChoice(id: "private", nameWithOwner: "org/private")]
        XCTAssertNil(PRSearchScope.accountLogin(in: state))
        XCTAssertEqual(PRSearchScope.defaultRepositories(in: state), [])
    }

    func testRepositoryInputRejectsURLAndQuerySyntax() {
        XCTAssertEqual(PRSearchScope.normalizedRepository(" Org/Repo "), "org/repo")
        for value in ["https://github.com/org/repo", "org", "org/repo/extra", "org/repo is:open", "../repo"] {
            XCTAssertNil(PRSearchScope.normalizedRepository(value), value)
        }
    }

    func testActiveListDeduplicatesCanonicalPRsAndHidesDisconnectedSnapshot() {
        var state = connectedState()
        let pr = PullRequestPresentation(
            id: "pr1", repositoryID: "repo", repositoryNameWithOwner: "org/repo", number: 1,
            title: "Fix", url: URL(string: "https://github.com/org/repo/pull/1")!,
            isDraft: false, updatedAt: .now, reviewers: []
        )
        state.needsYourReview = [pr]
        state.authoredPullRequests = [pr]
        XCTAssertEqual(PRSearchScope.activePullRequests(in: state).count, 1)
        state.accountConnection = .connectionRequired(.connectionRequired)
        XCTAssertEqual(PRSearchScope.activePullRequests(in: state), [])
    }

    private func connectedState() -> AppPresentationState {
        var state = AppPresentationState.empty
        state.accountConnection = .connected(login: "reader", accessCoverage: AccessCoverage(isComplete: true))
        return state
    }
}
