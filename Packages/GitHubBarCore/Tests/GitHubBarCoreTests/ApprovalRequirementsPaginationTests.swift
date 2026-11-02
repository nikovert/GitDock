import Foundation
import XCTest
@testable import GitHubBarCore

final class ApprovalRequirementsPaginationTests: XCTestCase {
    func testRulesBeyondFirstPageContributeTheirStricterMinimum() async throws {
        let (client, session) = makeClient(pages: [1: .init(body: fullNonReviewPage), 2: .init(body: stricterRulePage)])
        defer { session.invalidateAndCancel() }
        let rules = try await client.requirements(repository: "owner/repo", baseBranch: "release/next", account: account)
        XCTAssertEqual(rules.map(\.minimumApprovals), [2])
        let urls = ApprovalRulesURLProtocol.store.requestedURLs
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls.allSatisfy { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "per_page", value: "100")) == true })
        XCTAssertTrue(urls.allSatisfy { $0.absoluteString.contains("release%2Fnext") })
    }

    func testUnavailableLaterPageDoesNotReturnAnIncompletePolicy() async {
        let (client, session) = makeClient(pages: [1: .init(body: fullNonReviewPage), 2: .init(status: 403)])
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client.requirements(repository: "owner/repo", baseBranch: "main", account: account)
            XCTFail("An unavailable policy page must remain unknown")
        } catch { }
    }

    func testContinuationLinkUsesLocallyConstructedURLAndBoundedPagination() async {
        let (client, session) = makeClient(pages: [1: .init(headers: ["Link": "<https://evil.example/token>; rel=\"next\""], body: Data("[]".utf8)), 2: .init(body: stricterRulePage)])
        defer { session.invalidateAndCancel() }
        do {
            let rules = try await client.requirements(repository: "owner/repo", baseBranch: "main", account: account)
            XCTAssertEqual(rules.map(\.minimumApprovals), [2])
            XCTAssertTrue(ApprovalRulesURLProtocol.store.requestedURLs.allSatisfy { $0.host == "api.github.com" })
        } catch { XCTFail("A valid continuation should load safely: \(error)") }
    }

    func testPaginationLimitCannotReturnPartialPolicyAsComplete() async {
        let pages = Dictionary(uniqueKeysWithValues: (1...10).map { ($0, ApprovalRulesURLProtocol.Stub(body: fullNonReviewPage)) })
        let (client, session) = makeClient(pages: pages)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client.requirements(repository: "owner/repo", baseBranch: "main", account: account)
            XCTFail("Reaching the pagination bound must leave policy unknown")
        } catch { }
        XCTAssertEqual(ApprovalRulesURLProtocol.store.requestedURLs.count, 10)
    }

    private var account: ResolvedAccount {
        ResolvedAccount(login: "nikovert", hostname: "github.com", scopes: [], accessCoverage: AccessCoverage(isComplete: true), accessToken: GitHubAccessToken("fixture"))
    }
    private var fullNonReviewPage: Data { try! JSONSerialization.data(withJSONObject: Array(repeating: ["type": "required_signatures"], count: 100)) }
    private var stricterRulePage: Data { Data(#"[{"type":"pull_request","parameters":{"required_approving_review_count":2,"dismiss_stale_reviews_on_push":false,"require_code_owner_review":false,"require_last_push_approval":false}}]"#.utf8) }
    private func makeClient(pages: [Int: ApprovalRulesURLProtocol.Stub]) -> (RESTGitHubApprovalRequirementsClient, URLSession) {
        ApprovalRulesURLProtocol.store.reset(pages)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ApprovalRulesURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (RESTGitHubApprovalRequirementsClient(session: session), session)
    }
}

private final class ApprovalRulesURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data("[]".utf8)
    }
    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [Int: Stub] = [:]
        private var urls: [URL] = []
        var requestedURLs: [URL] { lock.withLock { urls } }
        func reset(_ pages: [Int: Stub]) { lock.withLock { self.pages = pages; urls = [] } }
        func stub(for url: URL) -> Stub {
            lock.withLock {
                urls.append(url)
                let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value.flatMap(Int.init) ?? 1
                return pages[page] ?? Stub(status: 500)
            }
        }
    }
    static let store = Store()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let stub = Self.store.stub(for: request.url!)
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
