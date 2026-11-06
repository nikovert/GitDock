import XCTest
@testable import GitDockCore

final class PRSearchTransportTests: XCTestCase {
    func testRateLimitEvidenceIsDistinctFromAuthorization() {
        XCTAssertEqual(PRSearchHTTPPolicy.failure(status: 403, headers: [:], body: Data()), .accessDenied)
        XCTAssertEqual(PRSearchHTTPPolicy.failure(status: 404, headers: [:], body: Data()), .accessDenied)
        XCTAssertEqual(PRSearchHTTPPolicy.failure(status: 403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "2000"], body: Data()), .rateLimited(until: Date(timeIntervalSince1970: 2000)))
        XCTAssertEqual(PRSearchHTTPPolicy.failure(status: 403, headers: [:], body: Data("{\"message\":\"You have exceeded a secondary rate limit\"}".utf8)), .rateLimited(until: nil))
    }

    func testRESTRequestUsesExactSelectedTokenAndAllStatePagination() throws {
        let account = ResolvedAccount(login: "alice", hostname: "github.com", scopes: [], accessCoverage: AccessCoverage(isComplete: true), accessToken: GitHubAccessToken("alice-token"))
        let request = try URLSessionPRSearchTransport.request(path: "/repos/org/repo/pulls?state=all&sort=created&direction=asc&per_page=100&page=2", account: account)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer alice-token")
        XCTAssertEqual(request.url?.host, "api.github.com")
        XCTAssertTrue(request.url!.absoluteString.contains("state=all"))
        XCTAssertTrue(request.url!.absoluteString.contains("page=2"))
        XCTAssertThrowsError(try URLSessionPRSearchTransport.request(path: "https://other.test/", account: account))
    }
}
