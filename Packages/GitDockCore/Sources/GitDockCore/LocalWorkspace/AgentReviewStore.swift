import Darwin
import Foundation

public actor AgentReviewStore {
    private let directory: URL
    public nonisolated var directoryURL: URL { directory }
    public init(directoryURL: URL? = nil) {
        directory = directoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // Preserve the pre-rename data directory for existing installations.
            .appendingPathComponent("GitHubBar", isDirectory: true)
    }

    public func load() throws -> AgentReviewDocument { try transaction { $0 } }

    @discardableResult
    public func saveConnection(_ connection: ReviewAgentConnection, priorityAuthors: [String]) throws -> AgentReviewDocument {
        let validated = try connection.validated()
        let authors = try ReviewAgentConnection.validatedPriorityAuthors(priorityAuthors)
        return try update { document in
            document.reviewAgentConnection = validated
            document.priorityAuthors = authors
        }
    }

    @discardableResult
    public func update(_ edit: @Sendable (inout AgentReviewDocument) throws -> Void) throws -> AgentReviewDocument {
        try transaction { document in try edit(&document); return document }
    }

    private func transaction<T>(_ body: (inout AgentReviewDocument) throws -> T) throws -> T {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(directory.appendingPathComponent("agent-reviews.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LocalWorkspaceStoreError.lockUnavailable }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw LocalWorkspaceStoreError.lockUnavailable }
        defer { flock(descriptor, LOCK_UN) }
        let url = directory.appendingPathComponent("agent-reviews.json")
        var document = AgentReviewDocument()
        if manager.fileExists(atPath: url.path) {
            do { document = try Self.decoder.decode(AgentReviewDocument.self, from: Data(contentsOf: url)) }
            catch { throw AgentReviewError.invalid("Could not read agent-reviews.json. Preserve the file and check its format before retrying.") }
            guard document.schemaVersion == 1 else { throw LocalWorkspaceStoreError.incompatibleVersion }
        }
        let original = document
        document.expireJobs(now: .now)
        let result = try body(&document)
        if original != document {
            try Self.encoder.encode(document).write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return result
    }

    public static var encoder: JSONEncoder {
        let value = JSONEncoder(); value.dateEncodingStrategy = .secondsSince1970
        value.outputFormatting = [.sortedKeys]; return value
    }
    public static var decoder: JSONDecoder {
        let value = JSONDecoder(); value.dateDecodingStrategy = .secondsSince1970; return value
    }

    public func execute(_ input: Data, workspace: LocalWorkspaceStore) async throws -> Data {
        guard input.count <= 2_000_000 else { throw AgentReviewError.invalid("Agent request is too large.") }
        let request = try Self.decoder.decode(AgentBridgeRequest.self, from: input)
        if request.op == "priority" {
            guard let url = request.prURL.flatMap(URL.init(string:)), let raw = request.priority,
                  let priority = BoardPriority(rawValue: raw) else { throw AgentReviewError.invalid("Supply a PR URL and priority high, medium, low or none.") }
            let subject = BoardSubject.pullRequest(try PullRequestKey(url: url))
            let by = request.by ?? "review-agent"
            _ = try await workspace.update { document in
                var entry = document.entry(for: subject) ?? BoardEntry(subject: subject)
                entry.priority = priority == .none ? nil : priority
                entry.updatedAt = .now; entry.updatedBy = by
                document.setEntry(entry)
            }
        }
        let board = try await workspace.load()
        return try transaction { document in
            let now = Date()
            switch request.op {
            case "show", "priority": break
            case "configure":
                if let login = request.accountLogin {
                    guard !login.isEmpty, login.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
                        throw AgentReviewError.invalid("Invalid GitHub account login.")
                    }
                    guard document.accountLogin.isEmpty || document.accountLogin.lowercased() == login.lowercased() else {
                        throw AgentReviewError.invalid("Agent reviews are configured for a different GitHub account. Use a separate workspace for that account.")
                    }
                    document.accountLogin = login
                }
                if let enabled = request.enabled {
                    guard !enabled || !document.accountLogin.isEmpty else { throw AgentReviewError.invalid("Configure a GitHub account before enabling agent reviews.") }
                    document.enabled = enabled
                }
                if let authors = request.priorityAuthors {
                    document.priorityAuthors = try ReviewAgentConnection.validatedPriorityAuthors(authors)
                }
            case "sync":
                for context in request.contexts ?? [] {
                    let valid = try context.validated()
                    guard document.accountLogin.isEmpty || document.accountLogin.lowercased() == valid.accountLogin.lowercased() else { continue }
                    guard valid.updatedAt >= (document.contexts[valid.prURL]?.updatedAt ?? .distantPast) else { continue }
                    document.contexts[valid.prURL] = valid
                }
            case "policy":
                guard let patch = request.policy else { throw AgentReviewError.invalid("Supply a policy patch.") }
                if request.scope == "global" { patch.apply(to: &document.defaultPolicy) }
                else {
                    guard ["pr", "stack"].contains(request.scope ?? ""), let url = request.prURL.flatMap(URL.init(string:)) else {
                        throw AgentReviewError.invalid("Policy scope must be global, pr, or stack.")
                    }
                    let key = try PullRequestKey(url: url)
                    let policyKey = (request.scope == "stack" ? "stack:" : "") + key.url.absoluteString
                    var policy = document.policyOverrides[policyKey] ?? AgentReviewPolicy()
                    patch.apply(to: &policy)
                    document.policyOverrides[policyKey] = policy
                }
            case "effective-policy":
                guard let context = request.context else { throw AgentReviewError.invalid("Supply PR context.") }
                let valid = try context.validated()
                guard document.enabled, document.accountLogin.lowercased() == valid.accountLogin.lowercased() else {
                    return try Self.encoder.encode(AgentReviewPolicy(fixMode: .off, comments: false, replies: false))
                }
                return try Self.encoder.encode(document.effectivePolicy(for: valid))
            case "enqueue":
                guard let context = request.context else { throw AgentReviewError.invalid("Supply PR context.") }
                return try Self.encoder.encode(document.enqueue(context: context, source: request.source ?? "board", now: now,
                    focuses: request.focuses ?? [], instructions: request.instructions ?? "",
                    slackChannel: request.slackChannel, slackThreadTS: request.slackThreadTS))
            case "claim":
                guard let worker = request.workerID, !worker.isEmpty else { throw AgentReviewError.invalid("Supply a worker ID.") }
                return try Self.encoder.encode(document.claim(workerID: worker, board: board, now: now))
            case "heartbeat", "update":
                guard let id = request.jobID, let worker = request.workerID else { throw AgentReviewError.invalid("Supply a job ID and worker ID.") }
                return try Self.encoder.encode(document.updateJob(id: id, workerID: worker, now: now) { job in
                    if request.op == "update" {
                        if let status = request.status {
                            guard status != .queued else { throw AgentReviewError.invalid("Cannot requeue a running job.") }
                            job.status = status
                        }
                        if let value = request.summary { job.summary = value }
                        if let value = request.error { job.error = value }
                        if let value = request.headSHA { job.headSHA = value }
                        if let value = request.githubURL { job.githubURL = value }
                        if let value = request.slackURL { job.slackURL = value }
                        if let value = request.worktreePath { job.worktreePath = value }
                    }
                })
            default: throw AgentReviewError.invalid("Unknown agent operation: \(request.op)")
            }
            var presented = document
            for (key, context) in document.contexts {
                let priority = context.priority(in: board, priorityAuthors: document.priorityAuthors)
                presented.contexts[key]?.priorityRank = priority.rank
                presented.contexts[key]?.priorityReason = priority.reason
            }
            return try Self.encoder.encode(presented)
        }
    }
}

private struct AgentPolicyPatch: Decodable {
    let value: AgentReviewPolicy
    let keys: Set<AgentReviewPolicy.CodingKeys>
    init(from decoder: any Decoder) throws {
        value = try AgentReviewPolicy(from: decoder)
        keys = Set(try decoder.container(keyedBy: AgentReviewPolicy.CodingKeys.self).allKeys)
    }
    func apply(to policy: inout AgentReviewPolicy) {
        if keys.contains(.fixMode) { policy.fixMode = value.fixMode }
        if keys.contains(.comments) { policy.comments = value.comments }
        if keys.contains(.replies) { policy.replies = value.replies }
    }
}

private struct AgentBridgeRequest: Decodable {
    let op: String
    var enabled: Bool?
    var accountLogin: String?
    var priorityAuthors: [String]?
    var contexts: [AgentPRContext]?
    var context: AgentPRContext?
    var scope: String?
    var prURL: String?
    var policy: AgentPolicyPatch?
    var priority: String?
    var by: String?
    var source: String?
    var focuses: [String]?
    var instructions: String?
    var slackChannel: String?
    var slackThreadTS: String?
    var workerID: String?
    var jobID: String?
    var status: AgentReviewStatus?
    var summary: String?
    var error: String?
    var headSHA: String?
    var githubURL: String?
    var slackURL: String?
    var worktreePath: String?
    enum CodingKeys: String, CodingKey {
        case op, enabled, accountLogin = "account_login", contexts, context, scope, prURL = "pr_url"
        case priorityAuthors = "priority_authors"
        case policy, priority, by, source, focuses, instructions, slackChannel = "slack_channel"
        case slackThreadTS = "slack_thread_ts", workerID = "worker_id", jobID = "job_id", status, summary, error
        case headSHA = "head_sha", githubURL = "github_url", slackURL = "slack_url", worktreePath = "worktree_path"
    }
}
