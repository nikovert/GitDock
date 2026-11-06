import Foundation
import XCTest
@testable import GitHubBarCore

final class AgentSessionConcurrencyTests: XCTestCase {
    func testLaunchSucceedsWhileSessionStatusPollIsSuspended() async throws {
        try await launchDuringBackgroundWork(polling: true)
    }

    func testLaunchSucceedsWhileCleanupPreviewIsSuspended() async throws {
        try await launchDuringBackgroundWork(polling: false)
    }

    func testStalePollCannotOverwriteRestartedSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("githubbar-stale-poll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LocalWorkspaceStore(directoryURL: directory.appendingPathComponent("board"))
        let subject = BoardSubject.pullRequest(try PullRequestKey(
            url: URL(string: "https://github.com/acme/widget/pull/12")!))
        let session = AgentSessionLink(subject: subject, agent: .codex,
            worktreePath: directory.path, tmuxSessionName: "existing", managedWorktree: false,
            state: .running)
        var document = LocalWorkspaceDocument.empty
        document.setSession(session)
        try await store.save(document)
        let runner = SuspendedWorkspaceRunner(polling: true)
        let manager = AgentSessionManager(store: store, commandRunner: runner,
            tmuxURL: URL(fileURLWithPath: "/fake/tmux"),
            agentURLs: [.codex: URL(fileURLWithPath: "/fake/codex")])
        let poll = Task { try await manager.refreshStates() }
        await runner.waitUntilSuspended()
        do { _ = try await manager.restart(id: session.id) }
        catch { XCTFail("Polling must not reject restart: \(error)") }
        await runner.resume()
        let refreshed = try await poll.value
        let saved = try await store.load()
        XCTAssertEqual(saved.sessions.first?.state, .running)
        XCTAssertEqual(refreshed.first?.state, .running)
    }

    private func launchDuringBackgroundWork(polling: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("githubbar-concurrency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkout = directory.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let store = LocalWorkspaceStore(directoryURL: directory.appendingPathComponent("board"))
        let subject = BoardSubject.pullRequest(try PullRequestKey(
            url: URL(string: "https://github.com/acme/widget/pull/12")!))
        var document = LocalWorkspaceDocument.empty
        document.configuration.repositoryCheckouts["acme/widget"] = checkout.path
        document.configuration.worktreeRoot = directory.appendingPathComponent("worktrees").path
        if polling {
            document.setSession(AgentSessionLink(subject: subject, agent: .codex,
                worktreePath: checkout.path, tmuxSessionName: "existing", managedWorktree: false,
                state: .running))
        }
        try await store.save(document)
        let runner = SuspendedWorkspaceRunner(polling: polling)
        let manager = AgentSessionManager(store: store, commandRunner: runner,
            tmuxURL: URL(fileURLWithPath: "/fake/tmux"),
            agentURLs: [.codex: URL(fileURLWithPath: "/fake/codex")])
        let coordinator = WorktreeCleanupCoordinator(store: store, sessions: manager, commandRunner: runner)
        let background = Task {
            if polling { _ = try await manager.refreshStates() }
            else { _ = try await coordinator.preview(accountLogin: "tester") }
        }
        await runner.waitUntilSuspended()
        do {
            let launched = try await manager.launch(subject: subject, agent: .codex)
            XCTAssertEqual(launched.state, .running)
            let saved = try await store.load()
            XCTAssertTrue(saved.sessions.contains(where: { $0.id == launched.id }))
        } catch {
            XCTFail("Background observation must not reject a launch: \(error.localizedDescription)")
        }
        await runner.resume()
        try await background.value
        let saved = try await store.load()
        XCTAssertEqual(saved.sessions.count, polling ? 2 : 1)
    }
}

private actor SuspendedWorkspaceRunner: CommandRunning {
    private let polling: Bool
    private var suspended = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    init(polling: Bool) { self.polling = polling }

    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { started = $0 }
    }

    func resume() { continuation?.resume(); continuation = nil }

    func run(executableURL: URL, arguments: [String], environment: [String: String]) async -> CommandResult {
        let shouldSuspend = !suspended && (polling ? arguments.first == "has-session" : arguments.contains("list"))
        if shouldSuspend {
            suspended = true
            await withCheckedContinuation {
                continuation = $0
                started?.resume(); started = nil
            }
        }
        return CommandResult(exitCode: shouldSuspend && polling ? 1 : 0,
            standardOutput: arguments.contains("get-url") ? "git@github.com:acme/widget.git\n" : "",
            standardError: "")
    }
}
