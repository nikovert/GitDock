import Foundation
import XCTest
@testable import GitDockCore

final class AgentSessionSafetyTests: XCTestCase {
    func testMissingOriginReportsCommandFailureWhenGitWritesNoError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("githubbar-origin-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkout = directory.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let store = LocalWorkspaceStore(directoryURL: directory.appendingPathComponent("board"))
        var document = LocalWorkspaceDocument.empty
        document.configuration.repositoryCheckouts["acme/widget"] = checkout.path
        document.configuration.worktreeRoot = directory.appendingPathComponent("worktrees").path
        try await store.save(document)
        let manager = AgentSessionManager(
            store: store, commandRunner: SilentOriginFailureRunner(),
            tmuxURL: URL(fileURLWithPath: "/usr/bin/true"),
            agentURLs: [.codex: URL(fileURLWithPath: "/usr/bin/true")]
        )
        let subject = BoardSubject.pullRequest(try PullRequestKey(
            url: URL(string: "https://github.com/acme/widget/pull/12")!
        ))

        do {
            _ = try await manager.launch(subject: subject, agent: .codex)
            XCTFail("A missing origin must not launch a worktree")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("origin"))
        }
    }

    func testLaunchRejectsCheckoutWhoseOriginIsAnotherRepository() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("githubbar-remote-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkout = directory.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let store = LocalWorkspaceStore(directoryURL: directory.appendingPathComponent("board"))
        var document = LocalWorkspaceDocument.empty
        document.configuration.repositoryCheckouts["acme/widget"] = checkout.path
        document.configuration.worktreeRoot = directory.appendingPathComponent("worktrees").path
        try await store.save(document)
        let runner = WrongRemoteRunner()
        let manager = AgentSessionManager(
            store: store, commandRunner: runner,
            gitURL: URL(fileURLWithPath: "/usr/bin/git"),
            tmuxURL: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
            agentURLs: [.codex: URL(fileURLWithPath: "/usr/bin/true")]
        )
        let subject = BoardSubject.pullRequest(try PullRequestKey(
            url: URL(string: "https://github.com/acme/widget/pull/12")!
        ))

        do {
            _ = try await manager.launch(subject: subject, agent: .codex)
            XCTFail("The app must not fetch PR 12 from another repository")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "The checkout's origin must point to acme/widget on github.com."
            )
            let fetched = await runner.didFetch
            XCTAssertFalse(fetched)
        }
    }

    func testLaunchAcceptsMatchingHTTPSAndSSHOrigins() async throws {
        for remoteURL in [
            "https://github.com/Acme/Widget.git",
            "git@github.com:Acme/Widget.git",
            "ssh://git@github.com/Acme/Widget.git",
        ] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("githubbar-matching-remote-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let checkout = directory.appendingPathComponent("checkout")
            try FileManager.default.createDirectory(
                at: checkout, withIntermediateDirectories: true
            )
            let store = LocalWorkspaceStore(directoryURL: directory.appendingPathComponent("board"))
            var document = LocalWorkspaceDocument.empty
            document.configuration.repositoryCheckouts["acme/widget"] = checkout.path
            document.configuration.worktreeRoot = directory.appendingPathComponent("worktrees").path
            try await store.save(document)
            let runner = WrongRemoteRunner(remoteURL: remoteURL)
            let manager = AgentSessionManager(
                store: store, commandRunner: runner,
                gitURL: URL(fileURLWithPath: "/usr/bin/git"),
                tmuxURL: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
                agentURLs: [.codex: URL(fileURLWithPath: "/usr/bin/true")]
            )
            let subject = BoardSubject.pullRequest(try PullRequestKey(
                url: URL(string: "https://github.com/acme/widget/pull/12")!
            ))

            let session = try await manager.launch(subject: subject, agent: .codex)

            XCTAssertEqual(session.state, .running)
            let fetched = await runner.didFetch
            XCTAssertTrue(fetched, remoteURL)
        }
    }

    func testLaunchPlanUsesItsOwnBranchInsteadOfSharedFetchHead() throws {
        let subject = BoardSubject.pullRequest(try PullRequestKey(
            url: URL(string: "https://github.com/acme/widget/pull/12")!
        ))
        let plan = try AgentSessionLaunchPlan(
            subject: subject, agent: .codex,
            checkoutPath: "/tmp/widget", worktreeRoot: "/tmp/worktrees",
            agentExecutablePath: "/usr/bin/true",
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        )

        XCTAssertEqual(plan.gitFetchArguments, [
            "-C", "/tmp/widget", "fetch", "origin",
            "refs/pull/12/head:refs/heads/githubbar/pr-12-00000000-0000-0000-0000-000000000012",
        ])
        XCTAssertEqual(plan.gitWorktreeArguments.suffix(1), [
            "githubbar/pr-12-00000000-0000-0000-0000-000000000012",
        ])
    }

    func testInterleavedFetchesCreateWorktreesAtTheirOwnPRHeads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("githubbar-fetch-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let checkout = directory.appendingPathComponent("checkout")
        let root = directory.appendingPathComponent("worktrees")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await runGit(["init", "-q", source.path])
        try Data("PR 12".utf8).write(to: source.appendingPathComponent("pr.txt"))
        try await runGit(["-C", source.path, "add", "pr.txt"])
        try await commit(in: source)
        try await runGit(["-C", source.path, "update-ref", "refs/pull/12/head", "HEAD"])
        try Data("PR 13".utf8).write(to: source.appendingPathComponent("pr.txt"))
        try await runGit(["-C", source.path, "add", "pr.txt"])
        try await commit(in: source)
        try await runGit(["-C", source.path, "update-ref", "refs/pull/13/head", "HEAD"])
        try await runGit(["clone", "-q", source.path, checkout.path])
        let first = try AgentSessionLaunchPlan(
            subject: .pullRequest(PullRequestKey(
                url: URL(string: "https://github.com/acme/widget/pull/12")!
            )),
            agent: .codex, checkoutPath: checkout.path, worktreeRoot: root.path,
            agentExecutablePath: "/usr/bin/true",
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        )
        let second = try AgentSessionLaunchPlan(
            subject: .pullRequest(PullRequestKey(
                url: URL(string: "https://github.com/acme/widget/pull/13")!
            )),
            agent: .claude, checkoutPath: checkout.path, worktreeRoot: root.path,
            agentExecutablePath: "/usr/bin/true",
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        )

        try await runGit(first.gitFetchArguments)
        try await runGit(second.gitFetchArguments)
        try await runGit(first.gitWorktreeArguments)
        try await runGit(second.gitWorktreeArguments)

        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: first.worktreePath)
                .appendingPathComponent("pr.txt"), encoding: .utf8),
            "PR 12"
        )
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: second.worktreePath)
                .appendingPathComponent("pr.txt"), encoding: .utf8),
            "PR 13"
        )
    }

    func testStoppingMissingSessionDoesNotKillPrefixMatchedSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("githubbar-tmux-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalWorkspaceStore(directoryURL: directory)
        let session = AgentSessionLink(
            subject: .pullRequest(try PullRequestKey(
                url: URL(string: "https://github.com/acme/widget/pull/12")!
            )),
            agent: .codex, worktreePath: directory.path,
            tmuxSessionName: "work.1", managedWorktree: false, state: .running
        )
        var document = LocalWorkspaceDocument.empty
        document.setSession(session)
        try await store.save(document)
        let runner = PrefixMatchingTmuxRunner()
        let manager = AgentSessionManager(
            store: store, commandRunner: runner,
            tmuxURL: URL(fileURLWithPath: "/opt/homebrew/bin/tmux")
        )

        try await manager.stop(id: session.id)

        let killed = await runner.killedSessions
        XCTAssertTrue(killed.isEmpty, "A different session must not be killed")
        let checked = await runner.checkedSessions
        XCTAssertEqual(checked, ["=work.1:"])
    }

    func testProcessRunnerDrainsLargeOutputAndErrorStreams() async throws {
        let result = await ProcessCommandRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "seq 1 50000; seq 1 50000 >&2"],
            environment: [:]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.hasPrefix("1\n2\n3\n"))
        XCTAssertTrue(result.standardOutput.hasSuffix("50000\n"))
        XCTAssertTrue(result.standardError.hasPrefix("1\n2\n3\n"))
        XCTAssertTrue(result.standardError.hasSuffix("50000\n"))
    }

    func testProcessRunnerExposesHomebrewToGitHooksFromFinderPath() async throws {
        let result = await ProcessCommandRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' \"$PATH\""],
            environment: ["PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(result.exitCode, 0)
        let directories = result.standardOutput.split(separator: ":").map(String.init)
        XCTAssertEqual(Array(directories.prefix(2)), ["/usr/bin", "/bin"])
        XCTAssertTrue(directories.contains("/opt/homebrew/bin"))
        XCTAssertTrue(directories.contains("/usr/local/bin"))
    }

    func testIgnoredFileBlocksWorktreeRemovalWhenGitHidesUntrackedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("githubbar-removal-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkout = directory.appendingPathComponent("checkout")
        let root = directory.appendingPathComponent("worktrees")
        let worktree = root.appendingPathComponent("pr-12")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await runGit(["init", "-q", checkout.path])
        try Data("*.env\n".utf8).write(to: checkout.appendingPathComponent(".gitignore"))
        try await runGit(["-C", checkout.path, "add", ".gitignore"])
        try await runGit([
            "-C", checkout.path, "-c", "user.name=GitDock Tests",
            "-c", "user.email=githubbar@example.invalid", "commit", "-qm", "Initial commit",
        ])
        try await runGit(["-C", checkout.path, "worktree", "add", "-qb", "pr-12", worktree.path])
        try await runGit(["-C", checkout.path, "config", "status.showUntrackedFiles", "no"])
        let ignoredFile = worktree.appendingPathComponent("secret.env")
        try Data("keep this".utf8).write(to: ignoredFile)

        let store = LocalWorkspaceStore(directoryURL: directory.appendingPathComponent("board"))
        let subject = BoardSubject.pullRequest(try PullRequestKey(
            url: URL(string: "https://github.com/acme/widget/pull/12")!
        ))
        let session = AgentSessionLink(
            subject: subject, agent: .codex, worktreePath: worktree.path,
            tmuxSessionName: nil, managedWorktree: true, state: .stopped
        )
        var document = LocalWorkspaceDocument.empty
        document.configuration.worktreeRoot = root.path
        document.setSession(session)
        try await store.save(document)
        let manager = AgentSessionManager(
            store: store, gitURL: URL(fileURLWithPath: "/usr/bin/git"), tmuxURL: nil
        )

        do {
            try await manager.removeManagedWorktree(id: session.id)
            XCTFail("Ignored local data must prevent worktree removal")
        } catch AgentSessionLaunchError.dirtyWorktree {
            XCTAssertTrue(FileManager.default.fileExists(atPath: ignoredFile.path))
            let remaining = try await store.load().sessions
            XCTAssertEqual(remaining.count, 1)
        }
    }

    private func runGit(_ arguments: [String]) async throws {
        let result = await ProcessCommandRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments, environment: [:]
        )
        guard result.exitCode == 0 else {
            throw NSError(domain: "GitDockCoreTests", code: Int(result.exitCode),
                          userInfo: [NSLocalizedDescriptionKey: result.standardError])
        }
    }

    private func commit(in repository: URL) async throws {
        try await runGit([
            "-C", repository.path, "-c", "user.name=GitDock Tests",
            "-c", "user.email=githubbar@example.invalid", "commit", "-qm", "Fixture",
        ])
    }
}

private actor SilentOriginFailureRunner: CommandRunning {
    func run(
        executableURL: URL, arguments: [String], environment: [String: String]
    ) async -> CommandResult {
        CommandResult(exitCode: 1, standardOutput: "", standardError: "")
    }
}

private actor WrongRemoteRunner: CommandRunning {
    private(set) var didFetch = false
    private let remoteURL: String

    init(remoteURL: String = "git@github.com:other/widget.git") {
        self.remoteURL = remoteURL
    }

    func run(
        executableURL: URL, arguments: [String], environment: [String: String]
    ) async -> CommandResult {
        if arguments.contains("get-url") {
            return CommandResult(
                exitCode: 0, standardOutput: "\(remoteURL)\n", standardError: ""
            )
        }
        if arguments.contains("fetch") { didFetch = true }
        return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
    }
}

private actor PrefixMatchingTmuxRunner: CommandRunning {
    private(set) var killedSessions: [String] = []
    private(set) var checkedSessions: [String] = []

    func run(
        executableURL: URL, arguments: [String], environment: [String: String]
    ) async -> CommandResult {
        if arguments.first == "has-session" {
            let target = arguments.last ?? ""
            checkedSessions.append(target)
            return CommandResult(
                exitCode: target == "=work.1" ? 0 : 1, standardOutput: "", standardError: ""
            )
        }
        if arguments.first == "kill-session" {
            killedSessions.append(arguments.last ?? "")
        }
        return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
    }
}
