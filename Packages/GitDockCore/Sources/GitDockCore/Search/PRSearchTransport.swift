import Foundation

public protocol PRSearchTransport: Sendable {
    func get(path: String, account: ResolvedAccount) async throws -> GitHubTransportResponse
}

public enum PRSearchError: Error, Equatable, Sendable {
    case accessDenied, invalidResponse, invalidRepository, revisionChanged, responseTooLarge
    case rateLimited(until: Date?)
}

enum PRSearchHTTPPolicy {
    static func failure(status: Int, headers: [String: String], body: Data) -> PRSearchError? {
        let headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        let message = String(decoding: body.prefix(4_096), as: UTF8.self).lowercased()
        let throttled = status == 429 || (status == 403 && (
            headers["x-ratelimit-remaining"] == "0" || headers["retry-after"] != nil
                || message.contains("secondary rate limit") || message.contains("api rate limit")
        ))
        if throttled {
            let until = headers["x-ratelimit-reset"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            return .rateLimited(until: until)
        }
        if status == 401 || status == 403 || status == 404 { return .accessDenied }
        return (200..<300).contains(status) ? nil : .invalidResponse
    }
}

private final class PRSearchSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public actor URLSessionPRSearchTransport: PRSearchTransport {
    private let session: URLSession
    private var blockedUntil: [String: Date] = [:]
    private let quotaReserve: Int
    private let now: @Sendable () -> Date

    public init(quotaReserve: Int = 100, now: @escaping @Sendable () -> Date = { Date() }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration, delegate: PRSearchSessionDelegate(), delegateQueue: nil)
        self.quotaReserve = max(1, quotaReserve)
        self.now = now
    }

    deinit { session.invalidateAndCancel() }

    static func request(path: String, account: ResolvedAccount) throws -> URLRequest {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains(".."),
              account.hostname.range(of: #"^[a-zA-Z0-9.-]+$"#, options: .regularExpression) != nil else {
            throw PRSearchError.invalidResponse
        }
        let base = account.hostname.lowercased() == "github.com" ? "https://api.github.com" : "https://\(account.hostname)/api/v3"
        guard let url = URL(string: base + path) else { throw PRSearchError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(account.accessToken.rawValue)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GitDock-PRSearch", forHTTPHeaderField: "User-Agent")
        return request
    }

    public func get(path: String, account: ResolvedAccount) async throws -> GitHubTransportResponse {
        let identity = "\(account.hostname)/\(account.login)".lowercased()
        if let until = blockedUntil[identity], until > now() { throw PRSearchError.rateLimited(until: until) }
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: Self.request(path: path, account: account))
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw PRSearchError.invalidResponse }
        let headers = Dictionary(response.allHeaderFields.map { (String(describing: $0.key).lowercased(), String(describing: $0.value)) }, uniquingKeysWith: { _, last in last })
        if let error = PRSearchHTTPPolicy.failure(status: response.statusCode, headers: headers, body: data) {
            if case .rateLimited(let reset) = error {
                let retry = headers["retry-after"].flatMap(TimeInterval.init).map { now().addingTimeInterval($0) }
                let until = max(reset ?? now().addingTimeInterval(60), retry ?? now())
                blockedUntil[identity] = until
                throw PRSearchError.rateLimited(until: until)
            }
            throw error
        }
        if let remaining = headers["x-ratelimit-remaining"].flatMap(Int.init), remaining <= quotaReserve {
            blockedUntil[identity] = headers["x-ratelimit-reset"].flatMap(TimeInterval.init)
                .map(Date.init(timeIntervalSince1970:)) ?? now().addingTimeInterval(60)
        }
        guard data.count <= 16 * 1_024 * 1_024 else { throw PRSearchError.responseTooLarge }
        return GitHubTransportResponse(statusCode: response.statusCode, headers: headers, data: data)
    }
}

struct PRSearchRESTClient: Sendable {
    let transport: any PRSearchTransport
    let now: @Sendable () -> Date

    func list(repository: String, page: Int, account: ResolvedAccount, updated: Bool = false) async throws -> ([PRSearchDocument], Bool) {
        let order = updated ? "sort=updated&direction=desc" : "sort=created&direction=asc"
        let path = try prefix(repository) + "/pulls?state=all&\(order)&per_page=100&page=\(page)"
        let response = try await get(path, account)
        let pulls = try decoder().decode([Pull].self, from: response.data)
        let next = response.headers.first { $0.key.lowercased() == "link" }?.value.contains("rel=\"next\"") == true
        return (pulls.map { $0.document(now: now()) }, next || pulls.count == 100)
    }

    func detail(repository: String, number: Int, account: ResolvedAccount) async throws -> PRSearchDocument {
        let response = try await get(try prefix(repository) + "/pulls/\(number)", account)
        return try decoder().decode(Pull.self, from: response.data).document(now: now())
    }

    func hydrate(_ before: PRSearchDocument, account: ResolvedAccount) async throws -> PRSearchDocument {
        var document = before
        var files: [PRSearchFile] = []
        var more = true
        var bytes = 0
        var reasons: [String] = []
        for page in 1...30 {
            try Task.checkCancellation()
            let response = try await get(try prefix(before.pullRequest.repositoryNameWithOwner) + "/pulls/\(before.pullRequest.number)/files?per_page=100&page=\(page)", account)
            let values = try decoder().decode([File].self, from: response.data)
            bytes += response.data.count
            if bytes > 16 * 1_024 * 1_024 { reasons.append("Local diff size limit reached."); break }
            files.append(contentsOf: values.map { PRSearchFile(path: $0.filename, previousPath: $0.previousFilename, patch: $0.patch, additions: $0.additions, deletions: $0.deletions) })
            let next = response.headers.first { $0.key.lowercased() == "link" }?.value.contains("rel=\"next\"") == true
            more = next || values.count == 100
            if !more { break }
        }
        let after = try await detail(repository: before.pullRequest.repositoryNameWithOwner, number: before.pullRequest.number, account: account)
        guard before.headSHA == after.headSHA, before.baseSHA == after.baseSHA,
              before.changedFiles == after.changedFiles else { throw PRSearchError.revisionChanged }
        document = after
        let uniquePaths = Set(files.map(\.path)).count == files.count
        let complete = !more && uniquePaths && before.changedFiles >= 0 && files.count == before.changedFiles
        if !complete { reasons.append("File list is incomplete or changed during pagination (GitHub limit: 3,000 files).") }
        if files.contains(where: { !$0.hasCompletePatch }) { reasons.append("Some patches are omitted, binary, or truncated; code coverage is partial.") }
        document.files = files
        document.coverage = PRSearchCoverage(fileListComplete: complete, codeComplete: complete && files.allSatisfy(\.hasCompletePatch), reasons: reasons)
        return document
    }

    private func get(_ path: String, _ account: ResolvedAccount) async throws -> GitHubTransportResponse {
        try Task.checkCancellation()
        let response = try await transport.get(path: path, account: account)
        try Task.checkCancellation()
        if let failure = PRSearchHTTPPolicy.failure(status: response.statusCode, headers: response.headers, body: response.data) { throw failure }
        return response
    }

    private func prefix(_ repository: String) throws -> String {
        guard Self.validRepository(repository) else { throw PRSearchError.invalidRepository }
        return "/repos/" + repository
    }

    static func validRepository(_ repository: String) -> Bool {
        repository.range(of: #"^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
            && !repository.contains("..")
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase; decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private struct File: Decodable {
        let filename: String
        let previousFilename: String?
        let patch: String?
        let additions: Int
        let deletions: Int
    }

    private struct Pull: Decodable {
        let nodeId: String
        let number: Int
        let title: String
        let body: String?
        let htmlUrl: URL
        let draft: Bool?
        let state: String
        let mergedAt: Date?
        let user: User?
        let createdAt: Date?
        let updatedAt: Date
        let base: Ref
        let head: Ref
        let changedFiles: Int?

        struct User: Decodable { let login: String; let avatarUrl: URL? }
        struct Ref: Decodable { let sha: String; let repo: Repo? }
        struct Repo: Decodable { let nodeId: String; let fullName: String }

        func document(now: Date) -> PRSearchDocument {
            let repository = base.repo
            let presentation = PullRequestPresentation(id: nodeId, repositoryID: repository?.nodeId ?? "",
                repositoryNameWithOwner: repository?.fullName ?? "", number: number, title: title, url: htmlUrl,
                isDraft: draft ?? false, state: mergedAt != nil ? .merged : state == "closed" ? .closed : .open,
                author: user.map { PullRequestAuthorPresentation(id: $0.login, displayName: $0.login, avatarURL: $0.avatarUrl) },
                createdAt: createdAt, updatedAt: updatedAt, reviewers: [], headSHA: head.sha)
            return PRSearchDocument(pullRequest: presentation, body: body ?? "", baseSHA: base.sha, headSHA: head.sha,
                changedFiles: changedFiles ?? -1, files: nil,
                coverage: PRSearchCoverage(reasons: ["Changed files have not been indexed."]), refreshedAt: now)
        }
    }
}
