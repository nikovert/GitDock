import Foundation

/// A remote-only preview. The scoped workload is supplied by the caller; no repository discovery occurs here.
public struct StaleDraftCleanupCandidate: Equatable, Identifiable, Sendable {
    public let previewID: UUID
    public let key: PullRequestKey
    public let nodeID: String
    public let accountLogin: String
    public let title: String
    public let authorLogin: String
    public let headSHA: String
    public let updatedAt: Date
    public let previewedAt: Date
    public let inactiveDays: Int
    public let viewerCanClose: Bool

    public var id: String { key.description }
    public var cutoff: Date { previewedAt.addingTimeInterval(-Double(inactiveDays) * 86_400) }
    public var isEligible: Bool { viewerCanClose && inactiveDays > 0 && updatedAt <= cutoff }

    public init(previewID: UUID = UUID(), key: PullRequestKey, nodeID: String, accountLogin: String,
                title: String, authorLogin: String, headSHA: String, updatedAt: Date, previewedAt: Date,
                inactiveDays: Int = 30, viewerCanClose: Bool) {
        self.previewID = previewID; self.key = key; self.nodeID = nodeID; self.accountLogin = accountLogin
        self.title = title; self.authorLogin = authorLogin; self.headSHA = headSHA; self.updatedAt = updatedAt
        self.previewedAt = previewedAt; self.inactiveDays = inactiveDays; self.viewerCanClose = viewerCanClose
    }
}

public struct StaleDraftCleanupResult: Equatable, Identifiable, Sendable {
    public enum Outcome: String, Equatable, Sendable { case closed, retained, unconfirmed }
    public let candidate: StaleDraftCleanupCandidate
    public let outcome: Outcome
    public let message: String
    public var id: String { candidate.id }

    public init(candidate: StaleDraftCleanupCandidate, outcome: Outcome, message: String) {
        self.candidate = candidate; self.outcome = outcome; self.message = message
    }
}

public protocol StaleDraftCleanupServicing: Sendable {
    func preview(workload: [PullRequestPresentation], accountLogin: String, inactiveDays: Int) async throws -> [StaleDraftCleanupCandidate]
    /// Call only for a preview item that the person explicitly selected and confirmed.
    func close(_ approved: StaleDraftCleanupCandidate, accountLogin: String) async -> StaleDraftCleanupResult
}

public enum StaleDraftCleanupError: Error, LocalizedError, Sendable {
    case invalidThreshold, accountUnavailable, incompleteGitHubData, readUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidThreshold: "Choose a positive number of inactive days."
        case .accountUnavailable: "Could not verify the monitored GitHub account."
        case .incompleteGitHubData: "GitHub did not return complete, authenticated draft information."
        case .readUnavailable: "Could not check drafts on GitHub. Refresh and try scanning again."
        }
    }
}

/// Uses only the account connection and GitHub transport. It cannot delete branches or access local worktrees/providers.
public actor StaleDraftCleanupService: StaleDraftCleanupServicing {
    private let connection: any AccountConnection
    private let transport: any GitHubTransport
    private let now: @Sendable () -> Date
    private var attemptedPreviews: Set<UUID> = []

    public init(connection: any AccountConnection = GitHubCLIAccountConnection(),
                transport: any GitHubTransport = URLSessionGitHubTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.connection = connection; self.transport = transport; self.now = now
    }

    public func preview(workload: [PullRequestPresentation], accountLogin: String,
                        inactiveDays: Int = 30) async throws -> [StaleDraftCleanupCandidate] {
        guard inactiveDays > 0 else { throw StaleDraftCleanupError.invalidThreshold }
        _ = try await verifiedAccount(accountLogin)
        let previewedAt = now()
        let cutoff = previewedAt.addingTimeInterval(-Double(inactiveDays) * 86_400)
        var candidates: [StaleDraftCleanupCandidate] = []
        var seen: Set<PullRequestKey> = []
        for row in workload where row.state == .open && row.isDraft && row.updatedAt <= cutoff &&
            row.author?.displayName.caseInsensitiveCompare(accountLogin) == .orderedSame {
            try Task.checkCancellation()
            guard let key = try? PullRequestKey(url: row.url), seen.insert(key).inserted else { continue }
            let account = try await verifiedAccount(accountLogin)
            let pr = try await read(key, account: account)
            // Fresh activity or ownership/state changes remove a draft from the queue before selection.
            guard pr.state == "OPEN", pr.isDraft, let author = pr.author,
                  author.login.lowercased() == accountLogin.lowercased(),
                  pr.updatedAt <= cutoff else { continue }
            candidates.append(StaleDraftCleanupCandidate(key: key, nodeID: pr.id, accountLogin: accountLogin,
                title: pr.title, authorLogin: author.login, headSHA: pr.headRefOid, updatedAt: pr.updatedAt,
                previewedAt: previewedAt, inactiveDays: inactiveDays, viewerCanClose: pr.viewerCanClose))
        }
        return candidates.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt < $1.updatedAt
        }
    }

    public func close(_ approved: StaleDraftCleanupCandidate, accountLogin: String) async -> StaleDraftCleanupResult {
        func retained(_ message: String) -> StaleDraftCleanupResult {
            .init(candidate: approved, outcome: .retained, message: message)
        }
        guard approved.isEligible, sameLogin(approved.accountLogin, accountLogin),
              sameLogin(approved.authorLogin, accountLogin), now() >= approved.previewedAt else {
            return retained("The account or inactivity cutoff changed. Scan again before closing this draft.")
        }
        guard !attemptedPreviews.contains(approved.previewID) else {
            return retained("This close was already attempted. Refresh GitHub and scan again to verify its state.")
        }
        do {
            let account = try await verifiedAccount(accountLogin)
            let fresh = try await read(approved.key, account: account)
            guard fresh.id == approved.nodeID, fresh.state == "OPEN", fresh.isDraft, fresh.viewerCanClose,
                  sameLogin(fresh.author?.login ?? "", approved.authorLogin),
                  fresh.headRefOid == approved.headSHA, fresh.updatedAt == approved.updatedAt,
                  fresh.updatedAt <= approved.cutoff else {
                return retained("This draft changed or can no longer be closed. Scan again to review its current state.")
            }
            // Account inspection is awaited: repeat cancellation/attempt checks after it, immediately before the write.
            let writeAccount = try await verifiedAccount(accountLogin)
            try Task.checkCancellation()
            guard !attemptedPreviews.contains(approved.previewID) else {
                return retained("This close was already attempted. Refresh GitHub and scan again to verify its state.")
            }
            let body = try JSONSerialization.data(withJSONObject: ["query": Self.closeMutation,
                "variables": ["id": approved.nodeID]])
            attemptedPreviews.insert(approved.previewID)
            do {
                let response = try await transport.execute(body: body, accessToken: writeAccount.accessToken)
                let payload = try JSONDecoder().decode(CloseResponse.self, from: response.data)
                guard response.statusCode == 200, payload.errors?.isEmpty != false,
                      let closed = payload.data?.closePullRequest?.pullRequest,
                      closed.id == approved.nodeID, closed.state == "CLOSED" else {
                    return unconfirmed(approved)
                }
                return .init(candidate: approved, outcome: .closed,
                    message: "Closed on GitHub. Remote branches and all local data were kept.")
            } catch {
                // A dispatched mutation may have succeeded even if the response was lost. Never retry here.
                return unconfirmed(approved)
            }
        } catch is CancellationError {
            return retained("Closing stopped before this draft was sent to GitHub.")
        } catch {
            return retained("Could not revalidate this draft and monitored account. Nothing was sent to GitHub.")
        }
    }

    private func verifiedAccount(_ login: String) async throws -> ResolvedAccount {
        guard !login.isEmpty, case let .connected(account) = await connection.inspect(selectedLogin: login),
              sameLogin(account.login, login), account.hostname.lowercased() == "github.com" else {
            throw StaleDraftCleanupError.accountUnavailable
        }
        return account
    }

    private func read(_ key: PullRequestKey, account: ResolvedAccount) async throws -> Draft {
        do {
            let body = try JSONSerialization.data(withJSONObject: ["query": Self.query, "variables": [
                "owner": key.owner, "name": key.repository, "number": key.number]])
            let response = try await transport.execute(body: body, accessToken: account.accessToken)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(ReadResponse.self, from: response.data)
            guard response.statusCode == 200, payload.errors?.isEmpty != false,
                  let data = payload.data, sameLogin(data.viewer.login, account.login),
                  let pr = data.repository?.pullRequest, !pr.id.isEmpty, !pr.headRefOid.isEmpty,
                  let url = URL(string: pr.url), (try? PullRequestKey(url: url)) == key else {
                throw StaleDraftCleanupError.incompleteGitHubData
            }
            return pr
        } catch let error as StaleDraftCleanupError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw StaleDraftCleanupError.readUnavailable }
    }

    private func sameLogin(_ left: String, _ right: String) -> Bool { left.lowercased() == right.lowercased() }
    private func unconfirmed(_ candidate: StaleDraftCleanupCandidate) -> StaleDraftCleanupResult {
        .init(candidate: candidate, outcome: .unconfirmed,
              message: "GitHub did not confirm the close. It may have succeeded. Refresh and verify the PR before trying again.")
    }

    private static let query = """
    query StaleDraftCleanup($owner: String!, $name: String!, $number: Int!) {
      viewer { login }
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          id url title author { login } state isDraft headRefOid updatedAt viewerCanClose
        }
      }
    }
    """
    private static let closeMutation = """
    mutation CloseStaleDraft($id: ID!) {
      closePullRequest(input: { pullRequestId: $id }) { pullRequest { id state } }
    }
    """

    private struct Failure: Decodable { let message: String }
    private struct ReadResponse: Decodable { let data: Payload?; let errors: [Failure]? }
    private struct Payload: Decodable { let viewer: Login; let repository: Repository? }
    private struct Login: Decodable { let login: String }
    private struct Repository: Decodable { let pullRequest: Draft? }
    private struct Draft: Decodable {
        let id: String; let url: String; let title: String; let author: Login?
        let state: String; let isDraft: Bool; let headRefOid: String; let updatedAt: Date; let viewerCanClose: Bool
    }
    private struct CloseResponse: Decodable { let data: ClosePayload?; let errors: [Failure]? }
    private struct ClosePayload: Decodable { let closePullRequest: CloseMutation? }
    private struct CloseMutation: Decodable { let pullRequest: ClosedDraft? }
    private struct ClosedDraft: Decodable { let id: String; let state: String }
}
