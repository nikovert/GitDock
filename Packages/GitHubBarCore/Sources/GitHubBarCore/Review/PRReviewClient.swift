import Foundation

public actor PRReviewClient: PRReviewServicing {
    private let connection: any AccountConnection
    private let transport: any PRReviewTransport
    private let reader: PRReviewReadTransport
    private let rest: PRSearchRESTClient
    private let maximumPages: Int
    private let maximumResponseBytes: Int
    private var comparisonViews: Set<Identity> = []

    private struct Identity: Hashable {
        let account: String
        let key: PullRequestKey
    }

    public init(accountConnection: any AccountConnection = GitHubCLIAccountConnection(),
                transport: any PRReviewTransport = URLSessionPRReviewTransport(),
                maximumPages: Int = 30, maximumResponseBytes: Int = 16 * 1_024 * 1_024) {
        connection = accountConnection
        self.transport = transport
        self.maximumPages = max(1, min(30, maximumPages))
        self.maximumResponseBytes = max(1, maximumResponseBytes)
        let reader = PRReviewReadTransport(transport: transport, maximumResponseBytes: max(1, maximumResponseBytes))
        self.reader = reader
        rest = PRSearchRESTClient(transport: reader, now: { Date() })
    }

    public func load(key: PullRequestKey, accountLogin: String, sinceSHA: String?) async throws -> PRReviewSnapshot {
        let identity = Identity(account: accountLogin.lowercased(), key: key)
        if let sinceSHA {
            guard Self.validSHA(sinceSHA) else { throw PRReviewError.invalidResponse }
            comparisonViews.insert(identity)
        } else { comparisonViews.remove(identity) }
        let account = try await resolve(accountLogin)
        let before = try await detail(key, account)
        var notices: [String] = []
        let document: PRSearchDocument
        let files: [PRSearchFile]
        if let sinceSHA {
            document = before
            let response = try await reader.get(path: "\(prefix(key))/compare/\(sinceSHA)...\(before.headSHA)?per_page=100&page=1", account: account)
            let comparison = try decode(Comparison.self, response.data)
            files = comparison.files.map(\.file)
            notices.append("Changes since \(sinceSHA.prefix(12)); inline review drafts are disabled in comparison view. GitHub returns at most 300 comparison files.")
            if files.count >= 300 { notices.append("Comparison file limit reached; additional files may be omitted.") }
            if comparison.mergeBaseCommit.sha.lowercased() != sinceSHA.lowercased() {
                notices.append("The last-reviewed commit is no longer an ancestor of this head. GitHub's comparison starts at their merge base, not the last-reviewed tree.")
            }
            if files.contains(where: { !$0.hasCompletePatch }) {
                notices.append("Some comparison patches are omitted, binary, or truncated.")
            }
        } else {
            document = try await hydrate(before, account)
            files = document.files ?? []
            notices += document.coverage.reasons
        }
        var comments: [PRReviewComment] = []
        let sources = [("\(pullPath(key))/comments", "inline", "Inline comments"),
                       ("\(prefix(key))/issues/\(key.number)/comments", "issue", "Conversation comments"),
                       ("\(pullPath(key))/reviews", "review", "Review comments")]
        for (path, kind, label) in sources {
            do {
                let values: [Comment] = try await pages(path: path, account: account, label: label, notices: &notices)
                comments += values.map { $0.comment(kind: kind) }
            } catch PRSearchError.accessDenied {
                notices.append("\(label) are unavailable for this account; discussion coverage is partial.")
            }
        }
        var seen = Set<String>()
        comments = comments.filter { seen.insert($0.id).inserted }.sorted {
            ($0.createdAt ?? .distantPast, $0.id) < ($1.createdAt ?? .distantPast, $1.id)
        }
        let checks = try await checksSummary(key, head: document.headSHA, account: account, notices: &notices)
        let after = try await detail(key, account)
        try unchanged(document, after)
        return PRReviewSnapshot(key: key, title: after.pullRequest.title, body: after.body,
            author: after.pullRequest.author?.displayName ?? "Unknown", createdAt: after.pullRequest.createdAt,
            updatedAt: after.pullRequest.updatedAt, headSHA: after.headSHA, baseSHA: after.baseSHA,
            files: files, notices: notices, comments: comments, checksSummary: checks, comparisonBaseSHA: sinceSHA,
            fileListComplete: sinceSHA == nil && document.coverage.fileListComplete)
    }

    @discardableResult
    public func submit(key: PullRequestKey, accountLogin: String, headSHA: String, baseSHA: String, event: PRReviewEvent,
                       body: String, comments: [PRReviewDraftComment]) async throws -> PRReviewSubmissionReceipt {
        let account = try await resolve(accountLogin)
        guard Self.validSHA(headSHA), Self.validSHA(baseSHA) else { throw PRReviewError.invalidResponse }
        guard event.permits(body: body, commentCount: comments.count),
              comments.count <= 100, body.utf8.count <= 65_536 else { throw PRReviewError.invalidReview }
        let identity = Identity(account: accountLogin.lowercased(), key: key)
        try validateComparison(comments, identity)
        let before = try await detail(key, account)
        guard before.headSHA == headSHA, before.baseSHA == baseSHA else { throw PRReviewError.revisionChanged }
        guard before.pullRequest.state == .open else { throw PRReviewError.submissionRejected }
        if !comments.isEmpty {
            let document = try await hydrate(before, account)
            guard document.coverage.fileListComplete else { throw PRReviewError.invalidComment }
            for comment in comments {
                guard comment.line > 0, !comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      comment.body.utf8.count <= 65_536,
                      let file = document.files?.first(where: { $0.path == comment.path }),
                      file.hasCompletePatch, let patch = file.patch,
                      PRDiffParser.parse(patch).contains(where: {
                          $0.kind != .hunk && (comment.side == .left ? $0.oldLine : $0.newLine) == comment.line
                      }) else { throw PRReviewError.invalidComment }
            }
        }
        let after = try await detail(key, account)
        try unchanged(before, after)
        guard after.pullRequest.state == .open else { throw PRReviewError.submissionRejected }
        try validateComparison(comments, identity)
        try Task.checkCancellation()
        let payload = Submission(commit_id: headSHA, event: event, body: body,
                                 comments: comments.map { .init(path: $0.path, line: $0.line, side: $0.side, body: $0.body) })
        let data = try JSONEncoder().encode(payload)
        guard data.count <= maximumResponseBytes else { throw PRSearchError.responseTooLarge }
        let verifiedAccount = try await resolve(accountLogin)
        try Task.checkCancellation()
        let response = try await transport.post(path: "\(pullPath(key))/reviews", account: verifiedAccount, body: data)
        // A failed or ambiguous POST is never retried here: that could duplicate a review.
        if response.statusCode == 422 { throw PRReviewError.submissionRejected }
        if let failure = PRSearchHTTPPolicy.failure(status: response.statusCode, headers: response.headers, body: response.data) { throw failure }
        guard response.data.count <= maximumResponseBytes else { throw PRSearchError.responseTooLarge }
        let confirmation = try decode(SubmittedReview.self, response.data)
        guard confirmation.id > 0, confirmation.commitId == headSHA,
              confirmation.state == event.submittedState else { throw PRReviewError.invalidResponse }
        return PRReviewSubmissionReceipt(id: confirmation.id, headSHA: headSHA, event: event, url: confirmation.htmlUrl)
    }

    private func validateComparison(_ comments: [PRReviewDraftComment], _ identity: Identity) throws {
        guard comments.isEmpty || (!comparisonViews.contains(identity) && comments.allSatisfy { $0.comparisonBaseSHA == nil }) else {
            throw PRReviewError.comparisonDraft
        }
    }

    private func resolve(_ login: String) async throws -> ResolvedAccount {
        guard !login.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PRReviewError.connectionRequired }
        let result = await connection.inspect(selectedLogin: login)
        try Task.checkCancellation()
        guard case .connected(let account) = result else {
            if case .failed(.viewerMismatch) = result { throw PRReviewError.accountMismatch }
            throw PRReviewError.connectionRequired
        }
        guard account.login.caseInsensitiveCompare(login) == .orderedSame,
              account.hostname.lowercased() == "github.com" else { throw PRReviewError.accountMismatch }
        return account
    }

    private func detail(_ key: PullRequestKey, _ account: ResolvedAccount) async throws -> PRSearchDocument {
        guard key.number > 0, PRSearchRESTClient.validRepository(key.repositoryNameWithOwner) else { throw PRReviewError.invalidResponse }
        let document = try await rest.detail(repository: key.repositoryNameWithOwner, number: key.number, account: account)
        guard document.pullRequest.number == key.number,
              document.pullRequest.repositoryNameWithOwner.lowercased() == key.repositoryNameWithOwner.lowercased(),
              (try? PullRequestKey(url: document.pullRequest.url)) == key,
              Self.validSHA(document.headSHA), Self.validSHA(document.baseSHA) else { throw PRReviewError.invalidResponse }
        return document
    }

    private func hydrate(_ document: PRSearchDocument, _ account: ResolvedAccount) async throws -> PRSearchDocument {
        do { return try await rest.hydrate(document, account: account) }
        catch PRSearchError.revisionChanged { throw PRReviewError.revisionChanged }
    }

    private func unchanged(_ before: PRSearchDocument, _ after: PRSearchDocument) throws {
        guard before.headSHA == after.headSHA, before.baseSHA == after.baseSHA,
              before.changedFiles == after.changedFiles else { throw PRReviewError.revisionChanged }
    }

    private func pages<T: Decodable>(path: String, account: ResolvedAccount, label: String,
                                    notices: inout [String]) async throws -> [T] {
        var result: [T] = [], bytes = 0
        for page in 1...maximumPages {
            let response = try await reader.get(path: "\(path)?per_page=100&page=\(page)", account: account)
            bytes += response.data.count
            if bytes > maximumResponseBytes { notices.append("\(label) size limit reached; results are partial."); return result }
            let values = try decode([T].self, response.data)
            result += values
            if !hasNext(response, count: values.count) { return result }
        }
        notices.append("\(label) pagination limit reached; results are partial.")
        return result
    }

    private func checksSummary(_ key: PullRequestKey, head: String, account: ResolvedAccount,
                               notices: inout [String]) async throws -> String {
        var summary: [String] = []
        do {
            let response = try await reader.get(path: "\(prefix(key))/commits/\(head)/status?per_page=100&page=1", account: account)
            let status = try decode(CombinedStatus.self, response.data)
            if status.totalCount > 0 { summary.append("Commit statuses: \(status.state) (\(status.totalCount))") }
        } catch PRSearchError.accessDenied {
            summary.append("Commit statuses unavailable")
            notices.append("Commit status checks are unavailable for this account.")
        }
        do {
            var runs: [CheckRun] = [], bytes = 0, complete = false
            for page in 1...maximumPages {
                let response = try await reader.get(path: "\(prefix(key))/commits/\(head)/check-runs?per_page=100&page=\(page)", account: account)
                bytes += response.data.count
                if bytes > maximumResponseBytes { break }
                let checks = try decode(CheckRuns.self, response.data)
                runs += checks.checkRuns
                if !hasNext(response, count: checks.checkRuns.count) {
                    complete = runs.count >= checks.totalCount
                    break
                }
            }
            if !complete { notices.append("Checks pagination or size limit reached; checks summary is partial.") }
            if !runs.isEmpty {
                let passed = runs.filter { $0.status == "completed" && $0.conclusion == "success" }.count
                let failed = runs.filter { ["failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale"].contains($0.conclusion ?? "") }.count
                let pending = runs.filter { $0.status != "completed" }.count
                let other = max(0, runs.count - passed - failed - pending)
                summary.append("Checks: \(passed) passed, \(failed) failed, \(pending) pending, \(other) other\(complete ? "" : " (partial)")")
            } else if !complete { summary.append("Checks incomplete") }
        } catch PRSearchError.accessDenied {
            summary.append("Checks unavailable")
            notices.append("Checks are unavailable for this account.")
        }
        return summary.isEmpty ? "No checks reported" : summary.joined(separator: "; ")
    }

    private func prefix(_ key: PullRequestKey) -> String { "/repos/\(key.repositoryNameWithOwner)" }
    private func pullPath(_ key: PullRequestKey) -> String { "\(prefix(key))/pulls/\(key.number)" }
    private static func validSHA(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    private func hasNext(_ response: GitHubTransportResponse, count: Int) -> Bool {
        response.headers.first { $0.key.lowercased() == "link" }?.value.contains("rel=\"next\"") == true || count == 100
    }
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(type, from: data) }
        catch { throw PRReviewError.invalidResponse }
    }
}

private struct Comparison: Decodable {
    let files: [ReviewFile]
    let mergeBaseCommit: Commit
    struct Commit: Decodable { let sha: String }
}
private struct ReviewFile: Decodable {
    let filename: String
    let previousFilename: String?
    let patch: String?
    let additions: Int
    let deletions: Int
    var file: PRSearchFile { .init(path: filename, previousPath: previousFilename, patch: patch, additions: additions, deletions: deletions) }
}
private struct Comment: Decodable {
    let id: Int
    let user: User?
    let body: String?
    let path: String?
    let line: Int?
    let side: PRReviewDraftComment.Side?
    let originalLine: Int?
    let htmlUrl: URL?
    let createdAt: Date?
    let submittedAt: Date?
    let inReplyToId: Int?
    struct User: Decodable { let login: String }
    func comment(kind: String) -> PRReviewComment {
        .init(id: "\(kind):\(id)", author: user?.login ?? "Unknown", body: body ?? "", path: path,
              line: line, url: htmlUrl, createdAt: createdAt ?? submittedAt,
              replyToID: inReplyToId.map { "inline:\($0)" }, side: side,
              isOutdated: kind == "inline" && path != nil && line == nil, originalLine: originalLine)
    }
}
private struct CombinedStatus: Decodable { let state: String; let totalCount: Int }
private struct CheckRuns: Decodable { let totalCount: Int; let checkRuns: [CheckRun] }
private struct CheckRun: Decodable { let status: String; let conclusion: String? }
private struct Submission: Encodable {
    let commit_id: String
    let event: PRReviewEvent
    let body: String
    let comments: [Inline]
    struct Inline: Encodable { let path: String; let line: Int; let side: PRReviewDraftComment.Side; let body: String }
}

private struct SubmittedReview: Decodable {
    let id: Int
    let commitId: String
    let state: String
    let htmlUrl: URL?
}
