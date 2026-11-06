import Foundation
import GitDockCore
import XCTest
@testable import GitDock

@MainActor
final class WorkspaceErrorTests: XCTestCase {
    func testBackgroundReloadDoesNotDismissAnActionError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("githubbar-error-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalWorkspaceStore(directoryURL: directory)
        let workspace = WorkspaceModel(
            store: store, sessions: AgentSessionManager(store: store, tmuxURL: nil),
            reviewStore: AgentReviewStore(directoryURL: directory)
        )
        workspace.errorMessage = "Could not create worktree"

        await workspace.reload()

        XCTAssertEqual(workspace.errorMessage, "Could not create worktree")
    }

    func testFailedBackgroundReloadDoesNotReplaceAnActionError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("githubbar-error-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid JSON".utf8).write(
            to: directory.appendingPathComponent("workspace.json")
        )
        let store = LocalWorkspaceStore(directoryURL: directory)
        let workspace = WorkspaceModel(
            store: store, sessions: AgentSessionManager(store: store, tmuxURL: nil),
            reviewStore: AgentReviewStore(directoryURL: directory)
        )
        workspace.errorMessage = "Could not create worktree"

        await workspace.reload()

        XCTAssertEqual(workspace.errorMessage, "Could not create worktree")
    }

    func testSuccessfulUnrelatedActionDoesNotDismissAnActionError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("githubbar-error-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalWorkspaceStore(directoryURL: directory)
        let workspace = WorkspaceModel(
            store: store, sessions: AgentSessionManager(store: store, tmuxURL: nil),
            reviewStore: AgentReviewStore(directoryURL: directory)
        )
        workspace.errorMessage = "Could not create worktree"
        let changed = expectation(description: "Workspace root saved")
        workspace.onDocumentChange = { changed.fulfill() }

        workspace.saveWorktreeRoot(directory.appendingPathComponent("worktrees").path)
        await fulfillment(of: [changed], timeout: 5)

        XCTAssertEqual(workspace.errorMessage, "Could not create worktree")
    }
}
