import Foundation

public struct WorktreeCleanupPRSummary: Identifiable, Equatable, Sendable {
    public var id: PullRequestKey { key }
    public let key: PullRequestKey
    public let title: String
    public let description: String

    public init(key: PullRequestKey, title: String, body: String) {
        self.key = key
        self.title = title
        let text = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        description = text.count > 280 ? String(text.prefix(277)) + "…" : text
    }
}

public struct WorktreeCleanupPR: Equatable, Sendable {
    public var title: String
    public var body: String
    public var stackPullRequests: [WorktreeCleanupPRSummary]
    public var headSHA: String
    public var merged: Bool
    public var closed: Bool
    public var isDraft: Bool
    public var hasStack: Bool
    public var stackComplete: Bool
    public var stackMerged: Bool
    public init(title: String, headSHA: String, merged: Bool, hasStack: Bool = false, stackComplete: Bool = true, stackMerged: Bool = true,
                body: String = "", stackPullRequests: [WorktreeCleanupPRSummary] = [], closed: Bool = false, isDraft: Bool = false) {
        self.title = title; self.headSHA = headSHA; self.merged = merged
        self.closed = closed; self.isDraft = isDraft
        self.body = body; self.stackPullRequests = stackPullRequests
        self.hasStack = hasStack
        self.stackComplete = stackComplete; self.stackMerged = stackMerged
    }
}

public struct WorktreeCleanupSessionIdentity: Equatable, Sendable {
    public let id: String
    public let serverPID: Int
    public let serverStartedAt: Int
    public let sessionCreatedAt: Int
}

public protocol WorktreeCleanupGitHubChecking: Sendable {
    func verifyAccount(accountLogin: String) async throws
    func check(_ subject: BoardSubject, accountLogin: String) async throws -> WorktreeCleanupPR
}

public extension WorktreeCleanupGitHubChecking {
    func verifyAccount(accountLogin: String) async throws {
        guard !accountLogin.isEmpty else { throw CleanupBlocked("Connect a monitored account first.") }
    }
}

public enum WorktreeCleanupIntent: Equatable, Sendable { case automatic, manual }

public enum WorktreeCleanupProvenance: String, Equatable, Sendable { case managed, external }

public struct WorktreeCleanupCandidate: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let sessions: [AgentSessionLink]
    public let title: String
    public let headSHA: String
    public let skipReason: String?
    public let liveSessions: [String: WorktreeCleanupSessionIdentity]
    public let accountLogin: String
    public let configuration: WorkspaceConfiguration
    public var pullRequests: [WorktreeCleanupPRSummary] = []
    public var provenance: WorktreeCleanupProvenance = .managed
    public var repositoryNameWithOwner: String? = nil
    public var automaticSkipReason: String? = nil
    public var isEligible: Bool { skipReason == nil }
    public var isAutomaticallyEligible: Bool {
        isEligible && provenance == .managed && liveSessions.isEmpty && automaticSkipReason == nil
    }
}

public struct WorktreeCleanupResult: Identifiable, Equatable, Sendable {
    public enum Outcome: String, Sendable { case removed, skipped, failed }
    public var id: String { path }
    public let path: String
    public let outcome: Outcome
    public let message: String

    public init(path: String, outcome: Outcome, message: String) {
        self.path = path; self.outcome = outcome; self.message = message
    }
}

public protocol WorktreeCleanupServicing: Sendable {
    func preview(accountLogin: String) async throws -> [WorktreeCleanupCandidate]
    func execute(_ approved: [WorktreeCleanupCandidate], accountLogin: String) async -> [WorktreeCleanupResult]
    func execute(_ approved: [WorktreeCleanupCandidate], accountLogin: String, intent: WorktreeCleanupIntent) async -> [WorktreeCleanupResult]
}

public extension WorktreeCleanupServicing {
    func execute(_ approved: [WorktreeCleanupCandidate], accountLogin: String, intent: WorktreeCleanupIntent) async -> [WorktreeCleanupResult] {
        // Legacy implementations only support explicit manual approval. Fail closed for automatic callers.
        guard intent == .manual else {
            return approved.map { WorktreeCleanupResult(path: $0.path, outcome: .skipped,
                message: "This cleanup service does not support automatic cleanup.") }
        }
        return await execute(approved, accountLogin: accountLogin)
    }
}

public actor WorktreeCleanupCoordinator: WorktreeCleanupServicing {
    private let store: LocalWorkspaceStore
    private let sessions: AgentSessionManager
    private let github: any WorktreeCleanupGitHubChecking
    private let local: WorktreeCleanupLocal

    public init(store: LocalWorkspaceStore, sessions: AgentSessionManager,
                github: any WorktreeCleanupGitHubChecking = WorktreeCleanupGitHubClient(),
                commandRunner: any CommandRunning = ProcessCommandRunner(),
                tmuxURL: URL? = AgentSessionManager.findExecutable("tmux")) {
        self.store = store; self.sessions = sessions; self.github = github
        local = WorktreeCleanupLocal(runner: commandRunner, tmuxURL: tmuxURL)
    }

    public func preview(accountLogin: String) async throws -> [WorktreeCleanupCandidate] {
        try await sessions.exclusively { [self] in
            let document = try await store.load()
            var candidates: [WorktreeCleanupCandidate] = []
            let groups = Dictionary(grouping: document.sessions, by: { WorktreeCleanupLocal.canonical($0.worktreePath) })
            var repositories: [String: String] = [:]
            var discoveryFailures: [String: (String, String)] = [:]
            for (repository, checkout) in document.configuration.repositoryCheckouts.sorted(by: { $0.key < $1.key }) {
                do {
                    for path in try await local.registeredPaths(checkout: checkout) {
                        // Ambiguous registrations are retained and surfaced through validation.
                        if repositories[path] == nil { repositories[path] = repository }
                    }
                } catch {
                    try Task.checkCancellation()
                    discoveryFailures[WorktreeCleanupLocal.canonical(checkout)] = (repository,
                        "Could not enumerate registered worktrees: " + error.localizedDescription)
                }
            }
            for path in Set(groups.keys).union(repositories.keys).sorted() {
                try Task.checkCancellation()
                candidates.append(await inspect(path: path, document: document, accountLogin: accountLogin, repository: repositories[path]))
            }
            for (path, failure) in discoveryFailures.sorted(by: { $0.key < $1.key }) where !candidates.contains(where: { $0.path == path }) {
                candidates.append(WorktreeCleanupCandidate(path: path, sessions: [], title: failure.0, headSHA: "",
                    skipReason: failure.1, liveSessions: [:], accountLogin: accountLogin, configuration: document.configuration,
                    provenance: .external, repositoryNameWithOwner: failure.0, automaticSkipReason: failure.1))
            }
            return candidates
        }
    }

    public func execute(_ approved: [WorktreeCleanupCandidate], accountLogin: String) async -> [WorktreeCleanupResult] {
        await execute(approved, accountLogin: accountLogin, intent: .manual)
    }

    public func execute(_ approved: [WorktreeCleanupCandidate], accountLogin: String, intent: WorktreeCleanupIntent) async -> [WorktreeCleanupResult] {
        do {
            return try await sessions.exclusively { [self] in
                var results: [WorktreeCleanupResult] = []
                var visited = Set<String>()
                for candidate in approved where visited.insert(candidate.path).inserted {
                    if Task.isCancelled { break }
                    results.append(await remove(candidate, accountLogin: accountLogin, intent: intent))
                }
                return results
            }
        } catch {
            return approved.map { WorktreeCleanupResult(path: $0.path, outcome: .skipped, message: error.localizedDescription) }
        }
    }

    private func inspect(path: String, document: LocalWorkspaceDocument, accountLogin: String,
                         repository: String? = nil, checkingSessionActivity: Bool = true) async -> WorktreeCleanupCandidate {
        let links = document.sessions.filter { WorktreeCleanupLocal.canonical($0.worktreePath) == path }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        var title = links.first?.subject.key.description ?? path
        var sha = ""
        var live: [String: WorktreeCleanupSessionIdentity] = [:]
        var reason: String?
        var pullRequests: [WorktreeCleanupPRSummary] = []
        let provenance: WorktreeCleanupProvenance = !links.isEmpty && links.allSatisfy(\.managedWorktree) ? .managed : .external
        let repository = repository ?? links.first?.subject.key.repositoryNameWithOwner
        var automaticReason: String? = provenance == .external ? "Other Git worktrees require explicit manual approval." : nil
        do {
            guard !accountLogin.isEmpty else { throw CleanupBlocked("Connect a monitored account first.") }
            try await github.verifyAccount(accountLogin: accountLogin)
            let subjects = Set(links.map(\.subject)).sorted { $0.key.description < $1.key.description }
            var metadata: [BoardSubject: WorktreeCleanupPR] = [:]
            var metadataError: (any Error)?
            for subject in subjects {
                try Task.checkCancellation()
                do {
                    let pr = try await github.check(subject, accountLogin: accountLogin)
                    metadata[subject] = pr
                    let summaries = [WorktreeCleanupPRSummary(key: subject.key, title: pr.title, body: pr.body)] + pr.stackPullRequests
                    for summary in summaries where !pullRequests.contains(where: { $0.key == summary.key }) {
                        pullRequests.append(summary)
                    }
                } catch { metadataError = error }
            }
            title = pullRequests.first?.title ?? title
            try await local.validate(path: path, links: links, configuration: document.configuration, repository: repository, provenance: provenance)
            if let metadataError, provenance == .managed { throw metadataError }
            // External registrations are explicitly approved local assets; their PR lifecycle is display context.
            for subject in subjects where provenance == .managed {
                guard let pr = metadata[subject] else { throw CleanupBlocked("PR information is unavailable.") }
                guard pr.merged || (pr.closed && pr.isDraft) else { throw CleanupBlocked("The PR is neither merged nor a verified closed draft.") }
                if !pr.merged { automaticReason = "Automatic cleanup only removes merged PR worktrees." }
                let wasStack: Bool
                if case .stack = subject { wasStack = true } else { wasStack = false }
                if pr.merged && (pr.hasStack || wasStack) {
                    guard pr.stackComplete, pr.stackMerged else { throw CleanupBlocked("The complete stack must be verified merged.") }
                }
                try await local.verifyOriginHead(path: path, subject: subject, sha: pr.headSHA)
                if !sha.isEmpty, sha != pr.headSHA { throw CleanupBlocked("Linked PRs have different heads.") }
                sha = pr.headSHA
            }
            if provenance == .external { sha = try await local.verifyRemoteBranchHead(path: path) }
            if checkingSessionActivity {
                live = try await local.liveSessions(path: path, links: links)
                if !live.isEmpty {
                    guard provenance == .managed else { throw CleanupBlocked("A session uses this other worktree. Close it manually first.") }
                    automaticReason = "Live sessions require explicit manual approval to stop."
                }
                // Owned live sessions can be approved manually; remaining processes are checked after their stop.
                if live.isEmpty { try await local.requireNoLocalProcesses(path: path) }
            }
            try Task.checkCancellation()
        } catch { reason = error.localizedDescription }
        return WorktreeCleanupCandidate(path: path, sessions: links, title: title, headSHA: sha,
            skipReason: reason, liveSessions: live, accountLogin: accountLogin,
            configuration: document.configuration, pullRequests: pullRequests, provenance: provenance,
            repositoryNameWithOwner: repository, automaticSkipReason: automaticReason)
    }

    private func remove(_ candidate: WorktreeCleanupCandidate, accountLogin: String, intent: WorktreeCleanupIntent) async -> WorktreeCleanupResult {
        var started = false
        var removed = false
        do {
            guard candidate.isEligible, candidate.accountLogin == accountLogin else {
                throw CleanupBlocked("Account or eligibility changed. Scan again.")
            }
            if intent == .automatic, !candidate.isAutomaticallyEligible {
                throw CleanupBlocked(candidate.automaticSkipReason ?? "Automatic cleanup requires a managed worktree without live sessions.")
            }
            let document = try await store.load()
            try unchanged(candidate, document: document)
            let fresh = await inspect(path: candidate.path, document: document, accountLogin: accountLogin, repository: candidate.repositoryNameWithOwner)
            guard fresh.isEligible else { throw CleanupBlocked(fresh.skipReason ?? "No longer eligible.") }
            if intent == .automatic, !fresh.isAutomaticallyEligible {
                throw CleanupBlocked(fresh.automaticSkipReason ?? "Automatic cleanup is no longer eligible.")
            }
            guard fresh.headSHA == candidate.headSHA, fresh.liveSessions == candidate.liveSessions else {
                throw CleanupBlocked("HEAD or live sessions changed. Scan again before stopping anything.")
            }
            try unchanged(candidate, document: await store.load())
            try await local.validate(path: candidate.path, links: candidate.sessions, configuration: candidate.configuration, repository: candidate.repositoryNameWithOwner, provenance: candidate.provenance)
            try await local.requireHead(candidate.headSHA, path: candidate.path)
            try Task.checkCancellation()
            started = true
            var remaining = candidate.liveSessions
            for (name, identity) in candidate.liveSessions.sorted(by: { $0.key < $1.key }) {
                guard intent == .manual, candidate.provenance == .managed else {
                    throw CleanupBlocked("Automatic cleanup never stops sessions.")
                }
                try Task.checkCancellation()
                try unchanged(candidate, document: await store.load())
                let current = try await local.liveSessions(path: candidate.path, links: candidate.sessions)
                guard current == remaining else { throw CleanupBlocked("Session activity changed; cleanup stopped. Scan again.") }
                try await local.validate(path: candidate.path, links: candidate.sessions, configuration: candidate.configuration,
                    repository: candidate.repositoryNameWithOwner, provenance: candidate.provenance)
                try await local.requireHead(candidate.headSHA, path: candidate.path)
                try await github.verifyAccount(accountLogin: accountLogin)
                try unchanged(candidate, document: await store.load())
                guard try await local.liveSessions(path: candidate.path, links: candidate.sessions) == remaining else {
                    throw CleanupBlocked("Session identity changed before stopping it. Worktree retained.")
                }
                // A session query awaits an external process. Reverify all non-session evidence after it.
                try await requireFreshEvidence(candidate, accountLogin: accountLogin, intent: intent)
                try await local.stop(sessionID: identity.id)
                remaining.removeValue(forKey: name)
            }
            try Task.checkCancellation()
            try unchanged(candidate, document: await store.load())
            guard try await local.liveSessions(path: candidate.path, links: candidate.sessions).isEmpty else {
                throw CleanupBlocked("A session is still attached. Worktree retained.")
            }
            // Reverify GitHub account/PR, origin and remote head after awaited session stops.
            let final = await inspect(path: candidate.path, document: try await store.load(), accountLogin: accountLogin,
                repository: candidate.repositoryNameWithOwner)
            guard final.isEligible, final.headSHA == candidate.headSHA, final.provenance == candidate.provenance,
                  final.liveSessions.isEmpty, intent != .automatic || final.isAutomaticallyEligible else {
                throw CleanupBlocked(final.skipReason ?? final.automaticSkipReason ?? "Worktree evidence changed. Scan again.")
            }
            try await local.requireNoLocalProcesses(path: candidate.path)
            try await local.validate(path: candidate.path, links: candidate.sessions, configuration: candidate.configuration, repository: candidate.repositoryNameWithOwner, provenance: candidate.provenance)
            try await local.requireHead(candidate.headSHA, path: candidate.path)
            try Task.checkCancellation()
            try unchanged(candidate, document: await store.load())
            guard try await local.liveSessions(path: candidate.path, links: candidate.sessions).isEmpty else {
                throw CleanupBlocked("A new live session appeared. Worktree retained.")
            }
            try await requireFreshEvidence(candidate, accountLogin: accountLogin, intent: intent)
            try await local.requireNoLocalProcesses(path: candidate.path)
            try unchanged(candidate, document: await store.load())
            try Task.checkCancellation()
            try await local.remove(path: candidate.path, configuration: candidate.configuration, links: candidate.sessions,
                repository: candidate.repositoryNameWithOwner, expectedHeadSHA: candidate.headSHA)
            removed = true
            let ids = Set(candidate.sessions.map(\.id))
            try await store.update { document in
                try self.unchanged(candidate, document: document)
                for id in ids { document.removeSession(id: id) }
            }
            return WorktreeCleanupResult(path: candidate.path, outcome: .removed,
                message: "Removed worktree and session links. Local branch and board history retained.")
        } catch {
            return WorktreeCleanupResult(path: candidate.path, outcome: started ? .failed : .skipped,
                message: removed ? "Worktree removed; session links were retained: " + error.localizedDescription : error.localizedDescription)
        }
    }

    /// Refresh GitHub/account, origin, registration, HEAD and clean contents without awaiting another
    /// session query afterward. This checks edits made while the last session query was in flight.
    private func requireFreshEvidence(_ candidate: WorktreeCleanupCandidate, accountLogin: String,
                                      intent: WorktreeCleanupIntent) async throws {
        try Task.checkCancellation()
        let document = try await store.load()
        try unchanged(candidate, document: document)
        let evidence = await inspect(path: candidate.path, document: document, accountLogin: accountLogin,
            repository: candidate.repositoryNameWithOwner, checkingSessionActivity: false)
        guard evidence.isEligible, evidence.headSHA == candidate.headSHA, evidence.provenance == candidate.provenance,
              intent != .automatic || evidence.isAutomaticallyEligible else {
            throw CleanupBlocked(evidence.skipReason ?? evidence.automaticSkipReason ?? "Worktree evidence changed. Scan again.")
        }
        // Fetching remote evidence also awaits processes; check local contents and HEAD after it.
        try await local.validate(path: candidate.path, links: candidate.sessions, configuration: candidate.configuration,
            repository: candidate.repositoryNameWithOwner, provenance: candidate.provenance)
        try await local.requireHead(candidate.headSHA, path: candidate.path)
        try unchanged(candidate, document: await store.load())
        try Task.checkCancellation()
    }

    private nonisolated func unchanged(_ candidate: WorktreeCleanupCandidate, document: LocalWorkspaceDocument) throws {
        let links = document.sessions.filter { WorktreeCleanupLocal.canonical($0.worktreePath) == candidate.path }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        // State and heartbeat updates are not changes of ownership.
        func identity(_ s: AgentSessionLink) -> AgentSessionLink {
            var value = s; value.state = .stopped; value.lastSeenAt = nil; return value
        }
        guard document.configuration == candidate.configuration,
              links.map(identity) == candidate.sessions.map(identity) else {
            throw CleanupBlocked("Workspace configuration or linked sessions changed. Scan again.")
        }
    }
}

struct CleanupBlocked: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
