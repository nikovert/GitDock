import Foundation
import GitDockCore

enum LocalWorkspaceChecks {
    static func run() async -> [String] {
        var failures: [String] = []
        do {
            check(
                AppearancePreference.allCases.map(\.rawValue) == ["system", "light", "dark"],
                "Appearance choices include system, light and dark", &failures
            )
            let update = try WorkspaceBoardUpdate.parse([
                "set", "--pr", "https://github.com/acme/widget/pull/12",
                "--priority", "high", "--tags", "blocked,agent-running",
                "--note", "Review tests", "--by", "codex",
            ])
            check(update.subject.key.description == "acme/widget#12", "CLI parses PR URL", &failures)
            check(update.priority == .high, "CLI parses priority", &failures)
            check(update.tagIDs == ["blocked", "agent-running"], "CLI parses tags", &failures)
            check(update.note == "Review tests", "CLI parses note", &failures)
            check(update.updatedBy == "codex", "CLI records agent", &failures)
            check(
                (try? WorkspaceBoardUpdate.parse(["set", "--pr", "x", "--priority", "urgent"])) == nil,
                "CLI rejects invalid priority", &failures
            )
            let launchPlan = try AgentSessionLaunchPlan(
                subject: .pullRequest(try PullRequestKey(
                    url: URL(string: "https://github.com/acme/widget/pull/12")!
                )),
                agent: .codex,
                checkoutPath: "/tmp/widget",
                worktreeRoot: "/tmp/worktrees",
                agentExecutablePath: "/opt/homebrew/bin/codex",
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
            )
            check(launchPlan.worktreePath.hasPrefix("/tmp/worktrees/"), "Worktree stays under configured root", &failures)
            check(launchPlan.tmuxSessionName.hasPrefix("githubbar-"), "tmux name is namespaced", &failures)
            check(
                launchPlan.gitFetchArguments == [
                    "-C", "/tmp/widget", "fetch", "origin",
                    "refs/pull/12/head:refs/heads/githubbar/pr-12-00000000-0000-0000-0000-000000000012",
                ],
                "Launch fetches the PR head into its own branch", &failures
            )
            check(launchPlan.tmuxArguments.contains("exec '/opt/homebrew/bin/codex'"), "Launch starts selected agent", &failures)
            let root = try PullRequestKey(url: URL(string: "https://github.com/acme/widget/pull/12")!)
            let child = try PullRequestKey(url: URL(string: "https://github.com/acme/widget/pull/13")!)
            check(root.description == "acme/widget#12", "PR key is human readable", &failures)
            check(
                (try? PullRequestKey(url: URL(string: "https://example.com/acme/widget/pull/12")!)) == nil,
                "Non-GitHub URLs are rejected",
                &failures
            )

            var board = LocalWorkspaceDocument.empty
            board.setEntry(BoardEntry(
                subject: .stack(root), priority: .high,
                tagIDs: ["blocked"], note: "Waiting on design", updatedBy: "claude"
            ))
            let inherited = board.resolvedEntry(for: child, stackRoot: root)
            check(inherited.priority == .high, "Stack priority reaches a member", &failures)
            check(inherited.tagIDs == ["blocked"], "Stack tags reach a member", &failures)
            check(inherited.note == "Waiting on design", "Stack note reaches a member", &failures)
            check(
                board.resolvedEntry(for: .stack(root), stackRoot: nil).priority == .high,
                "Stack board resolves its own priority", &failures
            )

            board.setEntry(BoardEntry(
                subject: .pullRequest(child), priority: .medium,
                tagIDs: ["needs-rework"], note: "Fix the tests", updatedBy: "codex"
            ))
            let overridden = board.resolvedEntry(for: child, stackRoot: root)
            check(overridden.priority == .medium, "PR priority overrides stack", &failures)
            check(overridden.tagIDs == ["needs-rework"], "PR tags override stack", &failures)
            check(overridden.note == "Fix the tests", "PR note overrides stack", &failures)

            let linked = AgentSessionLink(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
                subject: .pullRequest(child),
                agent: .codex,
                worktreePath: "/tmp/widget-13",
                tmuxSessionName: "githubbar-codex-widget-13",
                state: .running
            )
            board.setSession(linked)
            check(board.sessions(for: .pullRequest(child)) == [linked], "Session is pinned to its PR", &failures)
            check(board.sessions(for: .stack(root)).isEmpty, "PR session is not pinned to stack", &failures)
            board.configuration.repositoryCheckouts["acme/widget"] = "/tmp/widget"

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("githubbar-workspace-check-\(UUID().uuidString)")
            let store = LocalWorkspaceStore(directoryURL: directory)
            try await store.save(board)
            let loaded = try await store.load()
            check(loaded == board, "Board survives storage round trip", &failures)
            check(loaded.sessions(for: .pullRequest(child)) == [linked], "Pinned session survives restart", &failures)
            check(loaded.configuration.repositoryCheckouts["acme/widget"] == "/tmp/widget", "Checkout mapping survives restart", &failures)
            let file = directory.appendingPathComponent("workspace.json")
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            check(mode?.intValue == 0o600, "Board file is owner only", &failures)
            try Data("not-json".utf8).write(to: file, options: .atomic)
            do {
                _ = try await store.load()
                failures.append("FAILED: Corrupt board is rejected")
            } catch LocalWorkspaceStoreError.corrupt {
                // Expected.
            }
            try FileManager.default.removeItem(at: directory)
            let checkout = FileManager.default.temporaryDirectory
                .appendingPathComponent("githubbar-session-check-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: checkout) }
            let worktreeRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("githubbar-worktrees-check-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: worktreeRoot) }
            let sessionStore = LocalWorkspaceStore(directoryURL: checkout.appendingPathComponent("board"))
            var sessionDocument = LocalWorkspaceDocument.empty
            sessionDocument.configuration.repositoryCheckouts["acme/widget"] = checkout.path
            sessionDocument.configuration.worktreeRoot = worktreeRoot.path
            try await sessionStore.save(sessionDocument)
            let runner = SessionCheckCommandRunner()
            let manager = AgentSessionManager(
                store: sessionStore, commandRunner: runner,
                gitURL: URL(fileURLWithPath: "/usr/bin/git"),
                tmuxURL: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
                agentURLs: [.codex: URL(fileURLWithPath: "/opt/homebrew/bin/codex")]
            )
            let launched = try await manager.launch(subject: .pullRequest(root), agent: .codex)
            check(launched.managedWorktree, "Launched session owns its worktree", &failures)
            check(launched.state == .running, "Launched session is running", &failures)
            let calls = await runner.calls
            check(calls.count == 4, "Launch checks origin, fetches, creates worktree, starts tmux", &failures)
            check(calls[0].arguments == ["-C", checkout.path, "remote", "get-url", "origin"], "Launch verifies checkout origin", &failures)
            check(
                calls[1].arguments.starts(with: ["-C", checkout.path, "fetch", "origin"])
                    && calls[1].arguments.last?.hasPrefix(
                        "refs/pull/12/head:refs/heads/githubbar/pr-12-"
                    ) == true,
                "Launch fetches requested PR", &failures
            )
            await runner.setSessionExists(false)
            let vanished = try await manager.refreshStates()
            check(vanished[0].state == .stopped, "Exited tmux session is reflected in board", &failures)
            await runner.setSessionExists(true)
            let returned = try await manager.refreshStates()
            check(returned[0].state == .running, "Running tmux session is reflected in board", &failures)
            try await manager.stop(id: launched.id)
            check((try await sessionStore.load()).sessions[0].state == .stopped, "Stop persists session state", &failures)
            try FileManager.default.createDirectory(atPath: launched.worktreePath, withIntermediateDirectories: true)
            _ = try await manager.restart(id: launched.id)
            check((try await sessionStore.load()).sessions[0].state == .running, "Restart persists session state", &failures)
            await runner.setDirty(true)
            do {
                try await manager.removeManagedWorktree(id: launched.id)
                failures.append("FAILED: Dirty worktree is protected")
            } catch AgentSessionLaunchError.dirtyWorktree {
                check((try await sessionStore.load()).sessions.count == 1, "Dirty worktree remains pinned", &failures)
            }
            await runner.setDirty(false)
            try await manager.removeManagedWorktree(id: launched.id)
            check((try await sessionStore.load()).sessions.isEmpty, "Clean worktree can be unlinked", &failures)
        } catch {
            failures.append("FAILED: Local workspace check threw \(error)")
        }
        return failures
    }

    private static func check(_ condition: Bool, _ message: String, _ failures: inout [String]) {
        if !condition { failures.append("FAILED: \(message)") }
    }
}

private actor SessionCheckCommandRunner: CommandRunning {
    struct Call: Sendable {
        let arguments: [String]
    }

    private(set) var calls: [Call] = []
    private var isDirty = false
    private var sessionExists = true

    func setDirty(_ dirty: Bool) { isDirty = dirty }
    func setSessionExists(_ exists: Bool) { sessionExists = exists }

    func run(executableURL: URL, arguments: [String], environment: [String: String]) async -> CommandResult {
        calls.append(Call(arguments: arguments))
        if arguments.suffix(3) == ["remote", "get-url", "origin"] {
            return CommandResult(exitCode: 0, standardOutput: "git@github.com:acme/widget.git\n", standardError: "")
        }
        if arguments.first == "has-session" {
            return CommandResult(exitCode: sessionExists ? 0 : 1, standardOutput: "", standardError: "")
        }
        if arguments.suffix(4) == ["status", "--porcelain", "--ignored", "--untracked-files=all"] {
            return CommandResult(exitCode: 0, standardOutput: isDirty ? " M file.swift\n" : "", standardError: "")
        }
        return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
    }
}
