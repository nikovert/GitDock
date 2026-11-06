import Foundation

public enum AgentFixMode: String, Codable, CaseIterable, Sendable {
    case off, lowRisk = "low_risk", all
    public var label: String { switch self { case .off: "Don't auto-fix"; case .lowRisk: "Low-risk fixes"; case .all: "All fixes" } }
}

public struct AgentReviewPolicy: Codable, Equatable, Sendable {
    public var fixMode: AgentFixMode?
    public var comments: Bool?
    public var replies: Bool?
    public init(fixMode: AgentFixMode? = nil, comments: Bool? = nil, replies: Bool? = nil) {
        self.fixMode = fixMode; self.comments = comments; self.replies = replies
    }
    enum CodingKeys: String, CodingKey { case fixMode = "fix_mode", comments, replies }
}

public struct AgentPriority: Equatable, Sendable {
    public let rank: Int
    public let reason: String
    public var label: String { rank >= 3 ? "High" : rank == 2 ? "Medium" : "Low" }
}

public struct AgentPRContext: Codable, Equatable, Sendable {
    public var prURL: String
    public var title: String
    public var authorLogin: String
    public var accountLogin: String
    public var headSHA: String
    public var updatedAt: Date
    public var requestedHumans: [String]
    public var requestedTeamCount: Int
    public var reviewersComplete: Bool
    public var stackURL: String?
    public var priorityRank: Int?
    public var priorityReason: String?

    public init(prURL: String, title: String = "", authorLogin: String = "", accountLogin: String = "",
                headSHA: String = "", updatedAt: Date = .distantPast, requestedHumans: [String] = [],
                requestedTeamCount: Int = 0, reviewersComplete: Bool = false, stackURL: String? = nil) {
        self.prURL = prURL; self.title = title; self.authorLogin = authorLogin
        self.accountLogin = accountLogin; self.headSHA = headSHA; self.updatedAt = updatedAt
        self.requestedHumans = requestedHumans; self.requestedTeamCount = requestedTeamCount
        self.reviewersComplete = reviewersComplete; self.stackURL = stackURL
    }

    enum CodingKeys: String, CodingKey {
        case prURL = "pr_url", title, authorLogin = "author_login", accountLogin = "account_login"
        case headSHA = "head_sha", updatedAt = "updated_at", requestedHumans = "requested_humans"
        case requestedTeamCount = "requested_team_count", reviewersComplete = "reviewers_complete"
        case stackURL = "stack_url", priorityRank = "priority_rank", priorityReason = "priority_reason"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(prURL: try c.decode(String.self, forKey: .prURL),
                  title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
                  authorLogin: try c.decodeIfPresent(String.self, forKey: .authorLogin) ?? "",
                  accountLogin: try c.decodeIfPresent(String.self, forKey: .accountLogin) ?? "",
                  headSHA: try c.decodeIfPresent(String.self, forKey: .headSHA) ?? "",
                  updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast,
                  requestedHumans: try c.decodeIfPresent([String].self, forKey: .requestedHumans) ?? [],
                  requestedTeamCount: try c.decodeIfPresent(Int.self, forKey: .requestedTeamCount) ?? 0,
                  reviewersComplete: try c.decodeIfPresent(Bool.self, forKey: .reviewersComplete) ?? false,
                  stackURL: try c.decodeIfPresent(String.self, forKey: .stackURL))
    }

    public func validated() throws -> AgentPRContext {
        guard let url = URL(string: prURL), let key = try? PullRequestKey(url: url),
              !accountLogin.isEmpty else { throw AgentReviewError.invalid("A valid PR URL and monitored account are required.") }
        var copy = self
        copy.prURL = key.url.absoluteString
        if let stackURL {
            guard let url = URL(string: stackURL), let root = try? PullRequestKey(url: url),
                  root.repositoryNameWithOwner == key.repositoryNameWithOwner else {
                throw AgentReviewError.invalid("Stack root must belong to the PR repository.")
            }
            copy.stackURL = root.url.absoluteString
        }
        return copy
    }

    public func priority(in board: LocalWorkspaceDocument, priorityAuthors: [String] = []) -> AgentPriority {
        if let url = URL(string: prURL), let key = try? PullRequestKey(url: url) {
            let root = stackURL.flatMap(URL.init(string:)).flatMap { try? PullRequestKey(url: $0) }
            let manual = board.resolvedEntry(for: key, stackRoot: root).priority
            if manual != .none {
                return AgentPriority(rank: manual == .high ? 3 : manual == .medium ? 2 : 1,
                                     reason: "Manual priority")
            }
        }
        if reviewersComplete, requestedTeamCount == 0, !accountLogin.isEmpty,
           Set(requestedHumans.map { $0.lowercased() }) == [accountLogin.lowercased()] {
            return AgentPriority(rank: 3, reason: "You are the only requested human reviewer")
        }
        if priorityAuthors.contains(where: { $0.lowercased() == authorLogin.lowercased() }) {
            return AgentPriority(rank: 2, reason: "Priority author: \(authorLogin)")
        }
        return AgentPriority(rank: 1, reason: "Standard priority")
    }
}

public enum AgentReviewStatus: String, Codable, Sendable { case queued, running, completed, failed }

public struct AgentReviewJob: Codable, Equatable, Identifiable, Sendable {
    public var id: String = UUID().uuidString.lowercased()
    public var context: AgentPRContext
    public var source: String
    public var requestedAt: Date
    public var updatedAt: Date
    public var status: AgentReviewStatus = .queued
    public var workerID: String?
    public var leaseUntil: Date?
    public var summary = ""
    public var error = ""
    public var headSHA: String
    public var githubURL: String?
    public var slackURL: String?
    public var worktreePath: String?
    public var focuses: [String] = []
    public var instructions = ""
    public var slackChannel: String?
    public var slackThreadTS: String?

    public var isActive: Bool { status == .queued || status == .running }
    public func displayStatus(currentSHA: String?) -> String {
        if status == .completed, let currentSHA, !currentSHA.isEmpty, currentSHA != headSHA { return "Stale — new commits" }
        return status.rawValue.capitalized
    }
    enum CodingKeys: String, CodingKey {
        case id, context, source, requestedAt = "requested_at", updatedAt = "updated_at", status
        case workerID = "worker_id", leaseUntil = "lease_until", summary, error, headSHA = "head_sha"
        case githubURL = "github_url", slackURL = "slack_url", worktreePath = "worktree_path"
        case focuses, instructions, slackChannel = "slack_channel", slackThreadTS = "slack_thread_ts"
    }
}

public enum AgentReviewError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { switch self { case let .invalid(message): message } }
}

public struct AgentReviewDocument: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var enabled = false
    public var accountLogin = ""
    public var defaultPolicy = AgentReviewPolicy()
    public var policyOverrides: [String: AgentReviewPolicy] = [:]
    public var contexts: [String: AgentPRContext] = [:]
    public var jobs: [AgentReviewJob] = []
    public var reviewAgentConnection: ReviewAgentConnection?
    public var priorityAuthors: [String] = []
    public init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", enabled, accountLogin = "account_login"
        case defaultPolicy = "default_policy", policyOverrides = "policy_overrides", contexts, jobs
        case reviewAgentConnection = "review_agent_connection", priorityAuthors = "priority_authors"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        accountLogin = try c.decode(String.self, forKey: .accountLogin)
        defaultPolicy = try c.decode(AgentReviewPolicy.self, forKey: .defaultPolicy)
        policyOverrides = try c.decode([String: AgentReviewPolicy].self, forKey: .policyOverrides)
        contexts = try c.decode([String: AgentPRContext].self, forKey: .contexts)
        jobs = try c.decode([AgentReviewJob].self, forKey: .jobs)
        reviewAgentConnection = try c.decodeIfPresent(ReviewAgentConnection.self, forKey: .reviewAgentConnection)
        priorityAuthors = try c.decodeIfPresent([String].self, forKey: .priorityAuthors) ?? []
    }

    public func effectivePolicy(for context: AgentPRContext) -> AgentReviewPolicy {
        let pr = policyOverrides[context.prURL]
        let stack = context.stackURL.flatMap { policyOverrides["stack:\($0)"] }
        let own = !context.authorLogin.isEmpty && context.authorLogin.lowercased() == context.accountLogin.lowercased()
        return AgentReviewPolicy(
            fixMode: own ? pr?.fixMode ?? stack?.fixMode ?? defaultPolicy.fixMode ?? .off : pr?.fixMode ?? .off,
            comments: pr?.comments ?? stack?.comments ?? defaultPolicy.comments ?? own,
            replies: pr?.replies ?? stack?.replies ?? defaultPolicy.replies ?? false)
    }

    public mutating func enqueue(context: AgentPRContext, source: String, now: Date,
                                 focuses: [String] = [], instructions: String = "",
                                 slackChannel: String? = nil, slackThreadTS: String? = nil) throws -> AgentReviewJob {
        let context = try context.validated()
        guard enabled, accountLogin.lowercased() == context.accountLogin.lowercased() else {
            throw AgentReviewError.invalid("Enable agent reviews for the monitored account first.")
        }
        guard ["board", "slack"].contains(source) else { throw AgentReviewError.invalid("Unknown review request source.") }
        expireJobs(now: now)
        if let existing = jobs.first(where: { $0.context.prURL == context.prURL && $0.isActive }) { return existing }
        let job = AgentReviewJob(context: context, source: source, requestedAt: now, updatedAt: now,
                                 headSHA: context.headSHA, focuses: focuses, instructions: instructions,
                                 slackChannel: slackChannel, slackThreadTS: slackThreadTS)
        if context.updatedAt >= (contexts[context.prURL]?.updatedAt ?? .distantPast) {
            contexts[context.prURL] = context
        }
        jobs.append(job)
        return job
    }

    public mutating func expireJobs(now: Date) {
        for index in jobs.indices where jobs[index].status == .running && (jobs[index].leaseUntil ?? .distantPast) <= now {
            jobs[index].status = .failed
            jobs[index].error = "Worker interrupted. Check GitHub and re-request the review."
            jobs[index].updatedAt = now
        }
    }

    public mutating func claim(workerID: String, board: LocalWorkspaceDocument, now: Date) -> AgentReviewJob? {
        expireJobs(now: now)
        guard enabled, !workerID.isEmpty, !jobs.contains(where: { $0.status == .running }) else { return nil }
        let candidates = jobs.indices.filter {
            jobs[$0].status == .queued && jobs[$0].context.accountLogin.lowercased() == accountLogin.lowercased()
        }.sorted { lhs, rhs in
            let a = (contexts[jobs[lhs].context.prURL] ?? jobs[lhs].context).priority(in: board, priorityAuthors: priorityAuthors).rank
            let b = (contexts[jobs[rhs].context.prURL] ?? jobs[rhs].context).priority(in: board, priorityAuthors: priorityAuthors).rank
            if a != b { return a > b }
            return jobs[lhs].requestedAt < jobs[rhs].requestedAt
        }
        guard let index = candidates.first else { return nil }
        jobs[index].status = .running
        jobs[index].workerID = workerID
        jobs[index].leaseUntil = now.addingTimeInterval(180)
        jobs[index].updatedAt = now
        return jobs[index]
    }

    @discardableResult
    public mutating func updateJob(id: String, workerID: String, now: Date,
                                   edit: (inout AgentReviewJob) throws -> Void) throws -> AgentReviewJob {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status == .running,
              jobs[index].workerID == workerID, (jobs[index].leaseUntil ?? .distantPast) > now else {
            throw AgentReviewError.invalid("Job is not owned by this worker or its lease expired.")
        }
        try edit(&jobs[index])
        jobs[index].updatedAt = now
        jobs[index].leaseUntil = jobs[index].status == .running ? now.addingTimeInterval(180) : nil
        return jobs[index]
    }

    public func latestJob(for prURL: String) -> AgentReviewJob? {
        jobs.filter { $0.context.prURL == prURL }.max { $0.requestedAt < $1.requestedAt }
    }
}
