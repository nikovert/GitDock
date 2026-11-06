import Foundation

public protocol PRReviewTransport: PRSearchTransport {
    func post(path: String, account: ResolvedAccount, body: Data) async throws -> GitHubTransportResponse
}

private final class PRReviewSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Ephemeral, bounded responses; mutations are sent once and never automatically retried.
public actor URLSessionPRReviewTransport: PRReviewTransport {
    private let session: URLSession
    private let maximumResponseBytes: Int
    private var blockedUntil: [String: Date] = [:]

    public init(maximumResponseBytes: Int = 16 * 1_024 * 1_024) {
        self.maximumResponseBytes = max(1, maximumResponseBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: PRReviewSessionDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    static func request(path: String, account: ResolvedAccount, body: Data?) throws -> URLRequest {
        // Reuse the credential headers, but permit GitHub's SHA...SHA compare segment.
        var request = try URLSessionPRSearchTransport.request(path: "/", account: account)
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              let decoded = path.removingPercentEncoding,
              !decoded.split(separator: "/").contains(".."),
              let base = request.url, let url = URL(string: String(base.absoluteString.dropLast()) + path),
              url.host == base.host, url.scheme == "https", url.user == nil, url.password == nil,
              url.fragment == nil else { throw PRReviewError.invalidResponse }
        request.url = url
        request.setValue("GitDock-PRReview", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    public func get(path: String, account: ResolvedAccount) async throws -> GitHubTransportResponse {
        try await send(path: path, account: account, body: nil)
    }

    public func post(path: String, account: ResolvedAccount, body: Data) async throws -> GitHubTransportResponse {
        try await send(path: path, account: account, body: body)
    }

    private func send(path: String, account: ResolvedAccount, body: Data?) async throws -> GitHubTransportResponse {
        let identity = "\(account.hostname)/\(account.login)".lowercased()
        if let until = blockedUntil[identity], until > Date() { throw PRSearchError.rateLimited(until: until) }
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: Self.request(path: path, account: account, body: body))
        guard let response = response as? HTTPURLResponse else { throw PRReviewError.invalidResponse }
        guard response.expectedContentLength <= maximumResponseBytes else { throw PRSearchError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            if data.count % 4096 == 0 { try Task.checkCancellation() }
            guard data.count < maximumResponseBytes else { throw PRSearchError.responseTooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        let headers = Dictionary(response.allHeaderFields.map {
            (String(describing: $0.key).lowercased(), String(describing: $0.value))
        }, uniquingKeysWith: { _, last in last })
        if case .rateLimited(let reset) = PRSearchHTTPPolicy.failure(status: response.statusCode, headers: headers, body: data) {
            let retry = headers["retry-after"].flatMap(TimeInterval.init).map { Date().addingTimeInterval($0) }
            let until = max(reset ?? Date().addingTimeInterval(60), retry ?? Date())
            blockedUntil[identity] = until
            throw PRSearchError.rateLimited(until: until)
        }
        return .init(statusCode: response.statusCode, headers: headers, data: data)
    }
}

/// Applies the same response validation to injected transports and reused REST hydration.
struct PRReviewReadTransport: PRSearchTransport {
    let transport: any PRReviewTransport
    let maximumResponseBytes: Int

    func get(path: String, account: ResolvedAccount) async throws -> GitHubTransportResponse {
        try Task.checkCancellation()
        let response = try await transport.get(path: path, account: account)
        try Task.checkCancellation()
        guard response.data.count <= maximumResponseBytes else { throw PRSearchError.responseTooLarge }
        if let error = PRSearchHTTPPolicy.failure(status: response.statusCode, headers: response.headers, body: response.data) {
            throw error
        }
        return response
    }
}
