import XCTest
import GitDockCore
@testable import GitDock

@MainActor
final class WorkspaceDashboardTests: XCTestCase {
    func testNativeStackDeduplicatesWorkloadAndKeepsClosedMembersOnlyAsNavigation() {
        let open = pr(2, position: 2)
        let closed = pr(1, position: 1, state: .merged)
        let standalone = pr(3)
        let groups = WorkspaceDashboard.groups(visible: [open, open, standalone], stacks: [
            PullRequestStack(id: "stack", number: 10, pullRequests: [open, closed])
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].members.map { $0.pullRequest.number }, [1, 2])
        XCTAssertEqual(groups[0].members.map(\.isNavigationContext), [true, false])
        XCTAssertEqual(groups[1].members.map { $0.pullRequest.number }, [3])
        XCTAssertEqual(groups.flatMap(\.members).filter { !$0.isNavigationContext }.count, 2)
    }

    func testFilteredStackUsesCurrentMetadataAndKeepsUnmatchedMembersAsContext() {
        let a = pr(1, position: 1)
        let b = pr(2, position: 2)
        let groups = WorkspaceDashboard.groups(visible: [b], stacks: [PullRequestStack(id: "stack", number: 10, pullRequests: [a, b])])
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].members[0].isNavigationContext)
        XCTAssertFalse(groups[0].members[1].isNavigationContext)
        XCTAssertTrue(WorkspaceDashboard.groups(visible: [], stacks: [PullRequestStack(id: "stack", number: 10, pullRequests: [a])]).isEmpty)
    }

    func testClosedRowsAreExcludedFromActiveWorkload() {
        XCTAssertEqual(WorkspaceDashboard.active([pr(1), pr(1), pr(2, state: .closed)]).map(\.number), [1])
    }

    func testFreshOpenWorkloadOverridesClosedStackSnapshot() {
        let current = pr(1, position: 1)
        let stale = pr(1, position: 1, state: .merged)
        let groups = WorkspaceDashboard.groups(visible: [current], stacks: [PullRequestStack(id: "stack", number: 10, pullRequests: [stale])])
        XCTAssertEqual(groups[0].members[0].pullRequest.state, .open)
        XCTAssertFalse(groups[0].members[0].isNavigationContext)
    }

    private func pr(_ number: Int, position: Int? = nil, state: PullRequestState = .open) -> PullRequestPresentation {
        PullRequestPresentation(id: "pr-\(number)", repositoryID: "repo", repositoryNameWithOwner: "org/repo", number: number,
            title: "PR \(number)", url: URL(string: "https://github.com/org/repo/pull/\(number)")!, isDraft: false,
            state: state, stackMembership: position.map { PullRequestStackMembership(id: "stack", number: 10, size: 2, position: $0) },
            updatedAt: .now, reviewers: [])
    }
}
