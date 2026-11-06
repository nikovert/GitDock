import Foundation
import Darwin

struct WorktreeCleanupLocal: Sendable {
    let runner: any CommandRunning
    let tmuxURL: URL?
    private let gitURL = URL(fileURLWithPath: "/usr/bin/git")

    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return lexicalPath(path)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Darwin's /var and /tmp aliases are stable system paths, unlike arbitrary user symlinks.
    private static func lexicalPath(_ path: String) -> String {
        let lexical = URL(fileURLWithPath: path).standardizedFileURL.path
        for alias in ["/var", "/tmp"] where lexical == alias || lexical.hasPrefix(alias + "/") {
            return "/private" + lexical
        }
        return lexical
    }

    func registeredPaths(checkout: String) async throws -> [String] {
        guard checkout.hasPrefix("/") else { throw CleanupBlocked("Configure an absolute repository checkout path.") }
        let records = try await registrations(checkout: Self.canonical(checkout))
        return records.dropFirst().compactMap { record in
            guard let field = record.first, field.hasPrefix("worktree "),
                  !record.contains("bare") else { return nil }
            return String(field.dropFirst("worktree ".count))
        }
    }

    private func registrations(checkout: String) async throws -> [[String]] {
        try await git(["worktree", "list", "--porcelain", "-z"], at: checkout)
            .components(separatedBy: "\0\0").map { $0.components(separatedBy: "\0") }
            .filter { $0.first?.isEmpty == false }
    }

    func validate(path: String, links: [AgentSessionLink], configuration: WorkspaceConfiguration,
                  repository: String? = nil, provenance: WorktreeCleanupProvenance = .managed) async throws {
        guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\t"),
              FileManager.default.fileExists(atPath: path),
              Self.lexicalPath(path) == Self.canonical(path),
              links.allSatisfy({ Self.lexicalPath($0.worktreePath) == path }) else {
            throw CleanupBlocked("Only existing, unambiguous Git-registered worktree paths can be cleaned up.")
        }
        if provenance == .managed {
            guard !links.isEmpty, links.allSatisfy(\.managedWorktree) else {
                throw CleanupBlocked("Managed worktree ownership could not be verified.")
            }
            let root = Self.canonical(configuration.worktreeRoot)
            let lexicalRoot = URL(fileURLWithPath: configuration.worktreeRoot).standardizedFileURL.path
            guard configuration.worktreeRoot.hasPrefix("/"), root != "/", path.hasPrefix(root + "/"),
                  links.allSatisfy({ link in
                      let lexical = URL(fileURLWithPath: link.worktreePath).standardizedFileURL.path
                      return lexical.hasPrefix(lexicalRoot + "/") &&
                          root + lexical.dropFirst(lexicalRoot.count) == Self.canonical(link.worktreePath)
                  }) else {
                throw CleanupBlocked("The path is outside the managed root or contains a symlink.")
            }
        }
        let checkout = try checkout(configuration: configuration, links: links, repository: repository)
        let topLevel = try await git(["rev-parse", "--show-toplevel"], at: path).trimmed
        guard path != Self.canonical(checkout), topLevel == path else {
            throw CleanupBlocked("The main checkout or an unexpected repository cannot be removed.")
        }
        let records = try await registrations(checkout: checkout)
        guard records.first?.first != "worktree " + path,
              let record = records.first(where: { $0.first == "worktree " + path }),
              !record.contains(where: { $0.hasPrefix("locked") || $0.hasPrefix("prunable") || $0 == "bare" }) else {
            throw CleanupBlocked("Worktree registration is missing, locked, or is the main checkout.")
        }
        let common = try await git(["rev-parse", "--git-common-dir"], at: path).trimmed
        let checkoutCommon = try await git(["rev-parse", "--git-common-dir"], at: checkout).trimmed
        func absolute(_ value: String, from base: String) -> String {
            Self.canonical(value.hasPrefix("/") ? value : base + "/" + value)
        }
        guard absolute(common, from: path) == absolute(checkoutCommon, from: checkout) else {
            throw CleanupBlocked("Worktree belongs to a different repository.")
        }
        let origin = try await git(["remote", "get-url", "origin"], at: path)
        let checkoutOrigin = try await git(["remote", "get-url", "origin"], at: checkout)
        guard let originRepository = AgentSessionManager.repositoryNameWithOwner(fromRemoteURL: origin),
              AgentSessionManager.repositoryNameWithOwner(fromRemoteURL: checkoutOrigin) == originRepository,
              originRepository == (repository ?? links.first?.subject.key.repositoryNameWithOwner),
              links.allSatisfy({ $0.subject.key.repositoryNameWithOwner == originRepository }) else {
            throw CleanupBlocked("Origin does not match the linked PR repository.")
        }
        let filters = try await filterSafety(path: path)
        let status = try await git(["status", "--porcelain", "--ignored", "--untracked-files=all", "--ignore-submodules=none"], at: path, flags: filters)
        guard status.isEmpty else { throw CleanupBlocked("Local changes, untracked, or ignored files must be preserved.") }
        let tracked = try await git(["ls-files", "-v", "-z"], at: path)
        guard !tracked.split(separator: "\0").contains(where: {
            guard let first = $0.first else { return false }
            return first == "S" || first.isLowercase
        }) else { throw CleanupBlocked("Hidden or sparse tracked files prevent a reliable clean check.") }
        try await verifyTrackedContents(path: path)
    }

    func verifyOriginHead(path: String, subject: BoardSubject, sha: String) async throws {
        guard sha.count == 40, sha.allSatisfy(\.isHexDigit) else { throw CleanupBlocked("GitHub did not return a valid PR head.") }
        let ref = "refs/githubbar/cleanup/" + UUID().uuidString.lowercased()
        let result = await command(["fetch", "--no-tags", "--no-write-fetch-head", "origin",
            "refs/pull/\(subject.key.number)/head:\(ref)"], at: path)
        guard result.exitCode == 0 else { throw CleanupBlocked("Could not fetch the PR head from origin. Nothing was removed.") }
        let fetched: String
        do { fetched = try await git(["rev-parse", "--verify", ref], at: path).trimmed }
        catch { throw CleanupBlocked("Could not verify fetched PR head.") }
        let deleted = await command(["update-ref", "-d", ref, fetched], at: path)
        guard deleted.exitCode == 0 else { throw CleanupBlocked("Could not release the temporary verification ref.") }
        guard fetched == sha else { throw CleanupBlocked("GitHub and origin disagree about the PR head. Scan again.") }
        try await requireHead(sha, path: path)
    }

    /// Verify exact remote branch tips freshly, without trusting stale remote-tracking refs.
    func verifyRemoteBranchHead(path: String) async throws -> String {
        let sha = try await git(["rev-parse", "HEAD"], at: path).trimmed
        guard sha.count == 40, sha.allSatisfy(\.isHexDigit) else { throw CleanupBlocked("Local HEAD could not be verified.") }
        let refs = try await git(["ls-remote", "--heads", "origin"], at: path)
        guard refs.split(separator: "\n").contains(where: { line in
            let fields = line.split(separator: "\t")
            return fields.count == 2 && fields[0] == sha && fields[1].hasPrefix("refs/heads/")
        }) else { throw CleanupBlocked("Local HEAD is not a verified remote branch tip; local commits are preserved.") }
        try await requireHead(sha, path: path)
        return sha
    }

    func requireHead(_ sha: String, path: String) async throws {
        guard try await git(["rev-parse", "HEAD"], at: path).trimmed == sha else {
            throw CleanupBlocked("Local HEAD differs from the merged PR head; local commits are preserved.")
        }
    }

    func liveSessions(path: String, links: [AgentSessionLink]) async throws -> [String: WorktreeCleanupSessionIdentity] {
        guard let tmuxURL else { throw CleanupBlocked("Install tmux to verify session activity before cleanup.") }
        let response = await runner.run(executableURL: tmuxURL,
            arguments: ["list-panes", "-a", "-F", "#{session_id}\t#{session_name}\t#{pane_current_path}\t#{pid}\t#{start_time}\t#{session_created}"], environment: [:])
        if response.exitCode != 0 {
            if response.exitCode == 1 && (response.standardError.contains("no server running") ||
                (response.standardError.contains("error connecting to") && response.standardError.contains("No such file or directory"))) {
                return [:]
            }
            throw CleanupBlocked("Could not verify tmux session activity.")
        }
        var result: [String: WorktreeCleanupSessionIdentity] = [:]
        let names = Set(links.compactMap(\.tmuxSessionName))
        for line in response.standardOutput.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6, fields[0].first == "$", fields[0].count > 1,
                  fields[0].dropFirst().allSatisfy(\.isNumber),
                  let pid = Int(fields[3]), pid > 0,
                  let started = Int(fields[4]), started > 0,
                  let created = Int(fields[5]), created > 0 else {
                throw CleanupBlocked("Unrecognized tmux session metadata.")
            }
            let cwd = Self.canonical(fields[2])
            if names.contains(fields[1]) {
                guard links.filter({ $0.tmuxSessionName == fields[1] }).allSatisfy({ link in
                    let expected = "githubbar-\(link.agent.rawValue)-\(link.subject.key.repository)-pr-\(link.subject.key.number)-\(link.id.uuidString.prefix(8).lowercased())"
                    return link.managedWorktree && expected == fields[1]
                }), cwd == path || cwd.hasPrefix(path + "/") else {
                    throw CleanupBlocked("A linked session's ownership or working directory could not be verified.")
                }
                result[fields[1]] = WorktreeCleanupSessionIdentity(id: fields[0], serverPID: pid,
                    serverStartedAt: started, sessionCreatedAt: created)
            } else if cwd == path || cwd.hasPrefix(path + "/") {
                throw CleanupBlocked("An unlinked terminal session is using this worktree; close it manually first.")
            }
        }
        return result
    }

    func stop(sessionID: String) async throws {
        guard let tmuxURL else { throw CleanupBlocked("tmux is unavailable.") }
        let r = await runner.run(executableURL: tmuxURL, arguments: ["kill-session", "-t", sessionID], environment: [:])
        guard r.exitCode == 0 else { throw CleanupBlocked("Could not stop the selected session. Worktree retained.") }
    }

    func requireNoLocalProcesses(path: String) async throws {
        let result = await runner.run(executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-a", "-u", String(getuid()), "-d", "cwd", "-Fpn"], environment: [:])
        guard (result.exitCode == 0 || result.exitCode == 1), result.standardError.isEmpty else {
            throw CleanupBlocked("Could not verify remaining local processes. Worktree retained.")
        }
        for field in result.standardOutput.split(separator: "\n") where field.hasPrefix("n") {
            let cwd = Self.canonical(String(field.dropFirst()))
            if cwd == path || cwd.hasPrefix(path + "/") {
                throw CleanupBlocked("A local process still uses this worktree. Close it and scan again.")
            }
        }
    }

    func remove(path: String, configuration: WorkspaceConfiguration, links: [AgentSessionLink], repository: String? = nil,
                expectedHeadSHA: String) async throws {
        let checkout = try checkout(configuration: configuration, links: links, repository: repository)
        let filters = try await filterSafety(path: path) + filterSafety(path: checkout)
        try await verifyTrackedContents(path: path)
        try await requireHead(expectedHeadSHA, path: path)
        try Task.checkCancellation()
        _ = try await git(["worktree", "remove", "--", path], at: checkout, flags: filters)
    }

    private func verifyTrackedContents(path: String) async throws {
        let tree = try await git(["ls-tree", "-r", "-z", "--full-tree", "HEAD"], at: path)
        try WorktreeCleanupContent.verify(path: path, rawTree: tree)
    }

    /// Neutralize every configured filter driver instead of allowing clean/process hooks to hide bytes.
    private func filterSafety(path: String) async throws -> [String] {
        let response = await command(["config", "--null", "--name-only", "--get-regexp", "^filter\\..*\\.(process|smudge|clean|required)$"], at: path)
        guard response.exitCode == 0 || response.exitCode == 1, response.standardOutput.utf8.count < 1_024 * 1_024 else {
            throw CleanupBlocked("Could not safely enumerate Git content filters.")
        }
        var drivers = Set<String>()
        for key in response.standardOutput.split(separator: "\0").map(String.init) {
            guard key.hasPrefix("filter."), let dot = key.lastIndex(of: ".") else { throw CleanupBlocked("Unsupported Git filter configuration.") }
            drivers.insert(String(key[key.index(key.startIndex, offsetBy: 7)..<dot]))
        }
        guard drivers.count <= 1_024 else { throw CleanupBlocked("Git filters exceed their verification limit.") }
        return drivers.sorted().flatMap { name in
            ["-c", "filter.\(name).process=", "-c", "filter.\(name).clean=/bin/cat", "-c", "filter.\(name).smudge=/bin/cat", "-c", "filter.\(name).required=false"]
        }
    }

    private func checkout(configuration: WorkspaceConfiguration, links: [AgentSessionLink], repository: String? = nil) throws -> String {
        guard let key = repository ?? links.first?.subject.key.repositoryNameWithOwner,
              let checkout = configuration.repositoryCheckouts[key], checkout.hasPrefix("/") else {
            throw CleanupBlocked("Configure the repository checkout before cleanup.")
        }
        return Self.canonical(checkout)
    }

    private func command(_ args: [String], at path: String, flags: [String] = []) async -> CommandResult {
        await runner.run(executableURL: gitURL,
            arguments: ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
                "-c", "core.hooksPath=/dev/null", "-c", "core.autocrlf=false", "-c", "core.symlinks=true",
                "-c", "diff.external=", "-C", path] + flags + args,
            environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_NO_REPLACE_OBJECTS": "1",
                "GIT_GRAFT_FILE": "/dev/null", "GIT_LITERAL_PATHSPECS": "1"])
    }

    private func git(_ args: [String], at path: String, flags: [String] = []) async throws -> String {
        let r = await command(args, at: path, flags: flags)
        guard r.exitCode == 0 else { throw CleanupBlocked("Git could not verify or remove this worktree (\(args.first ?? "operation")).") }
        return r.standardOutput
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
