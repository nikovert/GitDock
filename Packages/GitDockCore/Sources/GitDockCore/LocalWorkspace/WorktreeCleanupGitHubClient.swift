import Foundation

public struct WorktreeCleanupGitHubClient: WorktreeCleanupGitHubChecking {
    private let connection: any AccountConnection
    private let transport: any GitHubTransport

    public init(connection: any AccountConnection = GitHubCLIAccountConnection(),
                transport: any GitHubTransport = URLSessionGitHubTransport()) {
        self.connection = connection; self.transport = transport
    }

    public func verifyAccount(accountLogin: String) async throws {
        guard !accountLogin.isEmpty,
              case let .connected(account) = await connection.inspect(selectedLogin: accountLogin),
              account.login.lowercased() == accountLogin.lowercased(), account.hostname == "github.com" else {
            throw CleanupBlocked("Could not verify the monitored GitHub account.")
        }
    }

    public func check(_ subject: BoardSubject, accountLogin: String) async throws -> WorktreeCleanupPR {
        guard !accountLogin.isEmpty,
              case let .connected(account) = await connection.inspect(selectedLogin: accountLogin),
              account.login.lowercased() == accountLogin.lowercased(), account.hostname == "github.com" else {
            throw CleanupBlocked("Could not verify the monitored GitHub account.")
        }
        let key = subject.key
        let body = try JSONSerialization.data(withJSONObject: ["query": Self.query, "variables": [
            "owner": key.owner, "name": key.repository, "number": key.number,
        ]])
        let response = try await transport.execute(body: body, accessToken: account.accessToken)
        guard response.statusCode == 200,
              let payload = try? JSONDecoder().decode(Response.self, from: response.data),
              payload.errors?.isEmpty != false,
              let data = payload.data, data.viewer.login.lowercased() == accountLogin.lowercased(),
              let pr = data.repository?.pullRequest else {
            throw CleanupBlocked("GitHub did not return complete, authenticated PR information.")
        }
        let stack = pr.stack
        let members = stack?.entries.nodes.compactMap { $0?.pullRequest } ?? []
        let complete = stack.map {
            !$0.entries.pageInfo.hasNextPage && $0.size > 0 && members.count == $0.size &&
                Set(members.map(\.url)).count == $0.size &&
                members.contains { $0.url == key.url.absoluteString }
        } ?? false
        return WorktreeCleanupPR(title: pr.title, headSHA: pr.headRefOid, merged: pr.state == "MERGED",
            hasStack: stack != nil, stackComplete: complete, stackMerged: complete && members.allSatisfy { $0.state == "MERGED" },
            body: pr.bodyText, stackPullRequests: members.compactMap { member in
                guard let url = URL(string: member.url), let key = try? PullRequestKey(url: url) else { return nil }
                return WorktreeCleanupPRSummary(key: key, title: member.title, body: member.bodyText)
            }, closed: pr.state == "CLOSED", isDraft: pr.isDraft ?? false)
    }

    private static let query = """
    query CleanupPullRequest($owner: String!, $name: String!, $number: Int!) {
      viewer { login }
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          title bodyText state headRefOid isDraft
          stack {
            size
            entries(first: 100) {
              nodes { pullRequest { url title bodyText state } }
              pageInfo { hasNextPage }
            }
          }
        }
      }
    }
    """

    private struct Response: Decodable {
        let data: Payload?
        let errors: [Failure]?
    }
    private struct Failure: Decodable { let message: String }
    private struct Payload: Decodable {
        let viewer: Viewer
        let repository: Repository?
    }
    private struct Viewer: Decodable { let login: String }
    private struct Repository: Decodable { let pullRequest: PR? }
    private struct PR: Decodable {
        let title: String
        let bodyText: String
        let state: String
        let headRefOid: String
        let isDraft: Bool?
        let stack: Stack?
    }
    private struct Stack: Decodable { let size: Int; let entries: Entries }
    private struct Entries: Decodable { let nodes: [Entry?]; let pageInfo: PageInfo }
    private struct Entry: Decodable { let pullRequest: Member? }
    private struct Member: Decodable { let url: String; let title: String; let bodyText: String; let state: String }
    private struct PageInfo: Decodable { let hasNextPage: Bool }
}
