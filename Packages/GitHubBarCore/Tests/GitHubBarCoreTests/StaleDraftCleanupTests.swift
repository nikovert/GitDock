import XCTest
@testable import GitHubBarCore

final class StaleDraftCleanupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var old: Date { now.addingTimeInterval(-31 * 86_400) }

    func testPreviewMatchesProjectedAuthorLoginRatherThanNamespacedID() async throws {
        let ownDraft = row(author: "TeStEr")
        XCTAssertEqual(ownDraft.author?.id, "user:tester")
        XCTAssertEqual(ownDraft.author?.displayName, "TeStEr")
        let transport = DraftTransport(reads: [payload()])
        let candidates = try await makeService(transport).preview(
            workload: [ownDraft, row(number: 2, author: "someone-else")], accountLogin: "tester")
        XCTAssertEqual(candidates.map(\.key.number), [1])
        let reads = await transport.readCount()
        XCTAssertEqual(reads, 1)
    }

    func testPreviewUsesScopedOwnOpenDraftsAndPositiveCutoff() async throws {
        let transport = DraftTransport(reads: [payload()])
        let service = makeService(transport)
        let rows = try await service.preview(workload: [row(), row(number: 2, author: "other"),
            row(number: 3, draft: false), row(number: 4, state: .closed), row(number: 5, updatedAt: now)],
            accountLogin: "tester", inactiveDays: 30)
        XCTAssertEqual(rows.map(\.key.number), [1])
        XCTAssertEqual(rows.first?.updatedAt, old)
        XCTAssertEqual(rows.first?.cutoff, now.addingTimeInterval(-30 * 86_400))
        let reads = await transport.readCount()
        XCTAssertEqual(reads, 1)
        do {
            _ = try await service.preview(workload: [row()], accountLogin: "tester", inactiveDays: 0)
            XCTFail("Zero is not a positive inactivity threshold")
        } catch { XCTAssertEqual(error.localizedDescription, "Choose a positive number of inactive days.") }
    }

    func testDefaultThresholdAndBoundaryIncludeExactlyThirtyDays() async throws {
        let atCutoff = now.addingTimeInterval(-30 * 86_400)
        let transport = DraftTransport(reads: [payload(updatedAt: atCutoff)])
        let service = makeService(transport)
        let rows = try await service.preview(workload: [row(updatedAt: atCutoff)], accountLogin: "tester")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.inactiveDays, 30)
    }

    func testChangedDraftEvidenceRejectsWithoutRemoteWrite() async throws {
        for change in ["head", "updatedAt", "author", "state", "draft", "permission", "viewer", "id", "url"] {
            let transport = DraftTransport(reads: [payload(), payload(change: change)])
            let service = makeService(transport)
            let candidate = try await firstCandidate(service)
            let result = await service.close(candidate, accountLogin: "tester")
            XCTAssertEqual(result.outcome, .retained, change)
            let writes = await transport.writeCount()
            XCTAssertEqual(writes, 0, change)
        }
    }

    func testAccountDriftRejectsBeforeFreshReadOrWrite() async throws {
        let transport = DraftTransport(reads: [payload()])
        let connection = DraftConnection()
        let service = makeService(transport, connection: connection)
        let candidate = try await firstCandidate(service)
        await connection.changeLogin("other")
        let result = await service.close(candidate, accountLogin: "tester")
        XCTAssertEqual(result.outcome, .retained)
        let writes = await transport.writeCount()
        XCTAssertEqual(writes, 0)
    }

    func testAccountChangesDuringRevalidationRejectsWrite() async throws {
        let connection = DraftConnection()
        let transport = DraftTransport(reads: [payload(), payload()], beforeSecondRead: { await connection.changeLogin("other") })
        let service = makeService(transport, connection: connection)
        let candidate = try await firstCandidate(service)
        let result = await service.close(candidate, accountLogin: "tester")
        XCTAssertEqual(result.outcome, .retained)
        let writes = await transport.writeCount()
        XCTAssertEqual(writes, 0)
    }

    func testFreshPermissionIsRequiredAndPreviewCannotSelectForbiddenDraft() async throws {
        let transport = DraftTransport(reads: [payload(change: "permission")])
        let service = makeService(transport)
        let candidate = try await firstCandidate(service)
        XCTAssertFalse(candidate.isEligible)
        let result = await service.close(candidate, accountLogin: "tester")
        XCTAssertEqual(result.outcome, .retained)
        let writes = await transport.writeCount()
        XCTAssertEqual(writes, 0)
    }

    func testSuccessfulCloseHasOneMutationAndDoesNotDeleteBranch() async throws {
        let transport = DraftTransport(reads: [payload(), payload()])
        let service = makeService(transport)
        let candidate = try await firstCandidate(service)
        let result = await service.close(candidate, accountLogin: "tester")
        XCTAssertEqual(result.outcome, .closed)
        let writeCount = await transport.writeCount()
        XCTAssertEqual(writeCount, 1)
        let writes = await transport.writes
        XCTAssertTrue(writes[0].contains("closePullRequest"))
        XCTAssertFalse(writes[0].contains("deleteRef"))
        XCTAssertFalse(writes[0].contains("deleteBranch"))
    }

    func testAmbiguousWriteIsNotRetriedAndRawErrorIsNeverExposed() async throws {
        for mode in [DraftTransport.WriteMode.timeout, .malformed, .graphqlFailure, .wrongResult] {
            let transport = DraftTransport(reads: [payload(), payload()], writeMode: mode)
            let service = makeService(transport)
            let candidate = try await firstCandidate(service)
            let result = await service.close(candidate, accountLogin: "tester")
            XCTAssertEqual(result.outcome, .unconfirmed)
            XCTAssertFalse(result.message.contains("SECRET"))
            let writeCount = await transport.writeCount()
        XCTAssertEqual(writeCount, 1)
        }
    }

    func testNewActivityDuringPreviewIsExcludedAndReadFailureIsSanitized() async throws {
        let activeTransport = DraftTransport(reads: [payload(updatedAt: now)])
        let rows = try await makeService(activeTransport).preview(workload: [row()], accountLogin: "tester")
        XCTAssertTrue(rows.isEmpty)
        let failedTransport = DraftTransport(reads: [Data("SECRET".utf8)])
        do {
            _ = try await makeService(failedTransport).preview(workload: [row()], accountLogin: "tester")
            XCTFail("Malformed response must fail closed")
        } catch { XCTAssertFalse(error.localizedDescription.contains("SECRET")) }
    }

    func testSamePreviewCannotRepeatAnAmbiguousMutation() async throws {
        let transport = DraftTransport(reads: [payload(), payload()], writeMode: .timeout)
        let service = makeService(transport)
        let candidate = try await firstCandidate(service)
        let first = await service.close(candidate, accountLogin: "tester")
        let second = await service.close(candidate, accountLogin: "tester")
        XCTAssertEqual(first.outcome, .unconfirmed)
        XCTAssertEqual(second.outcome, .retained)
        let writes = await transport.writeCount()
        XCTAssertEqual(writes, 1)
    }

    func testCancelledRevalidationNeverDispatchesMutation() async throws {
        let transport = DraftTransport(reads: [payload(), payload()])
        let service = makeService(transport)
        let candidate = try await firstCandidate(service)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.close(candidate, accountLogin: "tester")
        }
        let result = await task.value
        XCTAssertEqual(result.outcome, .retained)
        let writes = await transport.writeCount()
        XCTAssertEqual(writes, 0)
    }

    private func firstCandidate(_ service: StaleDraftCleanupService) async throws -> StaleDraftCleanupCandidate {
        let rows = try await service.preview(workload: [row()], accountLogin: "tester")
        return try XCTUnwrap(rows.first)
    }

    private func makeService(_ transport: DraftTransport, connection: DraftConnection = DraftConnection()) -> StaleDraftCleanupService {
        StaleDraftCleanupService(connection: connection, transport: transport, now: { [now] in now })
    }

    private func row(number: Int = 1, author: String = "tester", draft: Bool = true,
                     state: PullRequestState = .open, updatedAt: Date? = nil) -> PullRequestPresentation {
        PullRequestPresentation(id: "PR_\(number)", repositoryID: "R", repositoryNameWithOwner: "acme/widget",
            number: number, title: "Old draft", url: URL(string: "https://github.com/acme/widget/pull/\(number)")!,
            isDraft: draft, state: state, author: .init(id: "user:\(author.lowercased())", displayName: author, avatarURL: nil),
            updatedAt: updatedAt ?? old, reviewers: [], headSHA: "abc")
    }

    private func payload(change: String = "", updatedAt: Date? = nil) -> Data {
        let pr: [String: Any] = ["id": change == "id" ? "PR_other" : "PR_1", "title": "Old draft",
            "url": change == "url" ? "https://github.com/acme/elsewhere/pull/1" : "https://github.com/acme/widget/pull/1",
            "author": ["login": change == "author" ? "other" : "tester"],
            "headRefOid": change == "head" ? "def" : "abc", "state": change == "state" ? "CLOSED" : "OPEN",
            "isDraft": change != "draft", "viewerCanClose": change != "permission",
            "updatedAt": ISO8601DateFormatter().string(from: updatedAt ?? (change == "updatedAt" ? old.addingTimeInterval(1) : old))]
        return try! JSONSerialization.data(withJSONObject: ["data": ["viewer": ["login": change == "viewer" ? "other" : "tester"],
            "repository": ["pullRequest": pr]]])
    }
}

private actor DraftConnection: AccountConnection {
    private var login = "tester"
    func changeLogin(_ login: String) { self.login = login }
    func inspect(selectedLogin: String?) async -> AccountConnectionResult {
        .connected(.init(login: login, hostname: "github.com", scopes: [], accessCoverage: .init(isComplete: true),
                         accessToken: GitHubAccessToken("SECRET")))
    }
}

private actor DraftTransport: GitHubTransport {
    enum WriteMode { case success, timeout, malformed, graphqlFailure, wrongResult }
    private var reads: [Data]
    private var readsMade = 0
    private let writeMode: WriteMode
    private let beforeSecondRead: (@Sendable () async -> Void)?
    private(set) var writes: [String] = []
    init(reads: [Data], writeMode: WriteMode = .success, beforeSecondRead: (@Sendable () async -> Void)? = nil) {
        self.reads = reads; self.writeMode = writeMode; self.beforeSecondRead = beforeSecondRead
    }
    func readCount() -> Int { readsMade }
    func writeCount() -> Int { writes.count }
    func execute(body: Data, accessToken: GitHubAccessToken) async throws -> GitHubTransportResponse {
        let text = String(decoding: body, as: UTF8.self)
        if text.contains("closePullRequest") {
            writes.append(text)
            let data: Data
            switch writeMode {
            case .success: data = Data(#"{"data":{"closePullRequest":{"pullRequest":{"id":"PR_1","state":"CLOSED"}}}}"#.utf8)
            case .timeout: throw NSError(domain: "SECRET", code: 1)
            case .malformed: data = Data("SECRET".utf8)
            case .graphqlFailure: data = Data(#"{"errors":[{"message":"SECRET"}]}"#.utf8)
            case .wrongResult: data = Data(#"{"data":{"closePullRequest":{"pullRequest":{"id":"OTHER","state":"CLOSED"}}}}"#.utf8)
            }
            return .init(statusCode: 200, headers: [:], data: data)
        }
        readsMade += 1
        if readsMade == 2 { await beforeSecondRead?() }
        return .init(statusCode: 200, headers: [:], data: reads.removeFirst())
    }
}
