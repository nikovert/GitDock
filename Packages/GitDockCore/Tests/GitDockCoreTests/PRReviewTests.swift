import XCTest
@testable import GitDockCore

final class PRReviewTests: XCTestCase, @unchecked Sendable {
    private let key = try! PullRequestKey(url: URL(string: "https://github.com/org/repo/pull/7")!)

    func testDiffNumbersMultipleHunksAndNoNewlineMarker() {
        let lines = PRDiffParser.parse("@@ -2,3 +2,3 @@ func\n same\n-old\n+new\n tail\n@@ -20 +30,0 @@\n-gone\n\\ No newline at end of file")
        XCTAssertEqual(lines.map(\.oldLine), [nil, 2, 3, nil, 4, nil, 20])
        XCTAssertEqual(lines.map(\.newLine), [nil, 2, nil, 3, 4, nil, nil])
        XCTAssertEqual(lines.map(\.kind), [.hunk, .context, .deletion, .addition, .context, .hunk, .deletion])
        XCTAssertEqual(lines.map(\.text), ["@@ -2,3 +2,3 @@ func", "same", "old", "new", "tail", "@@ -20 +30,0 @@", "gone"])
        XCTAssertEqual(Set(lines.map(\.id)).count, lines.count)
    }

    func testMalformedAndOverflowHunksNeverProduceCommentableLines() {
        let lines = PRDiffParser.parse("+outside\n@@ broken\n+bad\n@@ -0,0 +1,1 @@\n+ok\n+overflow\n@@ -999999999999999999999 +1 @@\n+bad")
        XCTAssertEqual(lines.filter { $0.newLine != nil }.map(\.text), ["ok"])
    }

    func testLoadPaginatesFilesAndAllCommentKindsWithMissingPatchNotice() async throws {
        let transport = ReviewFixtureTransport()
        await transport.set("/pulls/7/files?per_page=100&page=1", json: ReviewFixtureTransport.files, next: true)
        await transport.set("/pulls/7/files?per_page=100&page=2", json: #"[{"filename":"binary.png","additions":0,"deletions":0}]"#)
        await transport.setDetail(changedFiles: 2)
        await transport.set("/pulls/7/comments?per_page=100&page=1", json: #"[{"id":1,"user":{"login":"bob"},"body":"first","path":"a.swift","line":2,"html_url":"https://github.com/org/repo/pull/7#discussion_r1","created_at":"2026-10-25T12:00:00Z"}]"#, next: true)
        await transport.set("/pulls/7/comments?per_page=100&page=2", json: #"[{"id":2,"user":{"login":"alice"},"body":"reply","path":"a.swift","line":2,"in_reply_to_id":1}]"#)
        await transport.set("/issues/7/comments?per_page=100&page=1", json: #"[{"id":1,"user":{"login":"bob"},"body":"general"}]"#)
        await transport.set("/pulls/7/reviews?per_page=100&page=1", json: #"[{"id":1,"user":{"login":"bob"},"body":"review","submitted_at":"2026-10-25T12:00:00Z"}]"#)
        let snapshot = try await client(transport).load(key: key, accountLogin: "alice", sinceSHA: nil)
        XCTAssertEqual(snapshot.files.map(\.path), ["a.swift", "binary.png"])
        XCTAssertEqual(snapshot.comments.count, 4)
        XCTAssertEqual(Set(snapshot.comments.map(\.id)).count, 4)
        let reply = try XCTUnwrap(snapshot.comments.first { $0.body == "reply" })
        XCTAssertEqual(reply.replyToID, snapshot.comments.first { $0.body == "first" }?.id)
        XCTAssertNotNil(snapshot.createdAt)
        XCTAssertEqual(snapshot.author, "author")
        XCTAssertTrue(snapshot.notices.contains { $0.contains("omitted") })
        XCTAssertNil(snapshot.comparisonBaseSHA)
        XCTAssertTrue(snapshot.fileListComplete)
        XCTAssertTrue(snapshot.canDraftInlineComment(in: "a.swift"))
        XCTAssertFalse(snapshot.canDraftInlineComment(in: "binary.png"))
        XCTAssertFalse(snapshot.canDraftInlineComment(in: "missing.swift"))
        let writes = await transport.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testCommentPaginationLimitIsExplicit() async throws {
        let transport = ReviewFixtureTransport()
        await transport.set("/pulls/7/comments?per_page=100&page=1", json: "[]", next: true)
        let snapshot = try await PRReviewClient(accountConnection: ReviewFixtureAccount(), transport: transport, maximumPages: 1)
            .load(key: key, accountLogin: "alice", sinceSHA: nil)
        XCTAssertTrue(snapshot.notices.contains { $0.lowercased().contains("comments") && $0.lowercased().contains("limit") })
    }

    func testAccountAndHostMismatchRejectBeforeReadingOrWriting() async throws {
        for account in [ReviewFixtureAccount(login: "bob"), ReviewFixtureAccount(host: "other.test")] {
            let transport = ReviewFixtureTransport()
            let service = PRReviewClient(accountConnection: account, transport: transport)
            do { _ = try await service.load(key: key, accountLogin: "alice", sinceSHA: nil); XCTFail("accepted wrong account") }
            catch { XCTAssertEqual(error as? PRReviewError, .accountMismatch) }
            do { try await service.submit(key: key, accountLogin: "alice", headSHA: ReviewFixtureTransport.head, baseSHA: ReviewFixtureTransport.base, event: .approve, body: "", comments: []); XCTFail("wrote as wrong account") }
            catch { XCTAssertEqual(error as? PRReviewError, .accountMismatch) }
            let reads = await transport.reads
            let writes = await transport.writes
            XCTAssertTrue(reads.isEmpty)
            XCTAssertTrue(writes.isEmpty)
        }
    }

    func testChangingHeadDuringLoadIsRejected() async throws {
        let transport = ReviewFixtureTransport()
        await transport.changeHeadAfterFirstRead()
        do { _ = try await client(transport).load(key: key, accountLogin: "alice", sinceSHA: nil); XCTFail("accepted moving head") }
        catch { XCTAssertEqual(error as? PRReviewError, .revisionChanged) }
    }

    func testStaleHeadSubmissionNeverPosts() async throws {
        let transport = ReviewFixtureTransport()
        do { try await client(transport).submit(key: key, accountLogin: "alice", headSHA: ReviewFixtureTransport.baseline, baseSHA: ReviewFixtureTransport.base, event: .approve, body: "", comments: []); XCTFail("accepted stale head") }
        catch { XCTAssertEqual(error as? PRReviewError, .revisionChanged) }
        let writes = await transport.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testRetargetedBaseWithUnchangedHeadRejectsBeforeHydrationOrPost() async throws {
        let transport = ReviewFixtureTransport()
        let service = client(transport)
        let snapshot = try await service.load(key: key, accountLogin: "alice", sinceSHA: nil)
        let previousReads = await transport.reads.count
        await transport.setBaseSHA(ReviewFixtureTransport.baseline)
        do {
            try await service.submit(key: key, accountLogin: "alice", headSHA: snapshot.headSHA, baseSHA: snapshot.baseSHA,
                event: .comment, body: "Review", comments: [.init(path: "a.swift", line: 2, side: .left, body: "Old base line")])
            XCTFail("accepted retargeted base with unchanged head")
        } catch { XCTAssertEqual(error as? PRReviewError, .revisionChanged) }
        let reads = await transport.reads
        let writes = await transport.writes
        XCTAssertEqual(Array(reads.dropFirst(previousReads)), ["/repos/org/repo/pulls/7"])
        XCTAssertTrue(writes.isEmpty)
    }

    func testReviewPayloadPinsCommitAndUsesNewAndOldLineSides() async throws {
        let transport = ReviewFixtureTransport()
        let service = client(transport)
        let drafts = [PRReviewDraftComment(path: "a.swift", line: 2, side: .right, body: "new"),
                      PRReviewDraftComment(path: "a.swift", line: 2, side: .left, body: "old")]
        try await service.submit(key: key, accountLogin: "alice", headSHA: ReviewFixtureTransport.head, baseSHA: ReviewFixtureTransport.base, event: .requestChanges, body: "Please fix", comments: drafts)
        let writes = await transport.writes
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.path, "/repos/org/repo/pulls/7/reviews")
        XCTAssertEqual(writes.first?.login, "alice")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(writes.first?.body)) as? [String: Any])
        XCTAssertEqual(payload["commit_id"] as? String, ReviewFixtureTransport.head)
        XCTAssertEqual(payload["event"] as? String, "REQUEST_CHANGES")
        XCTAssertEqual(payload["body"] as? String, "Please fix")
        let comments = try XCTUnwrap(payload["comments"] as? [[String: Any]])
        XCTAssertEqual(comments.map { $0["side"] as? String }, ["RIGHT", "LEFT"])
        XCTAssertEqual(comments.map { $0["line"] as? Int }, [2, 2])
        XCTAssertNil(comments.first?["id"])
        XCTAssertNil(comments.first?["comparisonBaseSHA"])
    }

    func testInvalidLinesAndPersistedComparisonDraftsNeverPost() async throws {
        let drafts = [PRReviewDraftComment(path: "missing", line: 2, side: .right, body: "x"),
                      PRReviewDraftComment(path: "a.swift", line: 99, side: .right, body: "x"),
                      PRReviewDraftComment(path: "a.swift", line: 0, side: .left, body: "x"),
                      PRReviewDraftComment(path: "a.swift", line: 2, side: .right, body: "x", comparisonBaseSHA: ReviewFixtureTransport.baseline)]
        for draft in drafts {
            let transport = ReviewFixtureTransport()
            do { try await client(transport).submit(key: key, accountLogin: "alice", headSHA: ReviewFixtureTransport.head, baseSHA: ReviewFixtureTransport.base, event: .comment, body: "Review", comments: [draft]); XCTFail("accepted invalid draft") }
            catch { XCTAssertTrue(error is PRReviewError) }
            let writes = await transport.writes
            XCTAssertTrue(writes.isEmpty)
        }
    }

    func testCompareIsPinnedAndCannotSubmitInlineDrafts() async throws {
        let transport = ReviewFixtureTransport()
        let service = client(transport)
        let snapshot = try await service.load(key: key, accountLogin: "alice", sinceSHA: ReviewFixtureTransport.baseline)
        XCTAssertEqual(snapshot.comparisonBaseSHA, ReviewFixtureTransport.baseline)
        XCTAssertEqual(snapshot.files.first?.path, "since.swift")
        XCTAssertFalse(snapshot.fileListComplete)
        XCTAssertFalse(snapshot.canDraftInlineComment(in: "since.swift"))
        XCTAssertTrue(snapshot.notices.contains { $0.contains("300") })
        let reads = await transport.reads
        XCTAssertTrue(reads.contains { $0.contains("/compare/\(ReviewFixtureTransport.baseline)...\(ReviewFixtureTransport.head)") })
        do { try await service.submit(key: key, accountLogin: "alice", headSHA: snapshot.headSHA, baseSHA: snapshot.baseSHA, event: .comment, body: "Review", comments: [.init(path: "a.swift", line: 2, side: .right, body: "x")]); XCTFail("accepted compare draft") }
        catch { XCTAssertEqual(error as? PRReviewError, .comparisonDraft) }
    }

    func testTruncatedPatchCannotReceiveInlineComments() async throws {
        let transport = ReviewFixtureTransport()
        await transport.set("/pulls/7/files?per_page=100&page=1", json: #"[{"filename":"a.swift","patch":"@@ -1,3 +1,3 @@\n same\n-old\n+new","additions":1,"deletions":1}]"#)
        let snapshot = try await client(transport).load(key: key, accountLogin: "alice", sinceSHA: nil)
        XCTAssertTrue(snapshot.fileListComplete)
        XCTAssertFalse(snapshot.canDraftInlineComment(in: "a.swift"))
        do { try await client(transport).submit(key: key, accountLogin: "alice", headSHA: ReviewFixtureTransport.head, baseSHA: ReviewFixtureTransport.base, event: .comment, body: "Review", comments: [.init(path: "a.swift", line: 2, side: .right, body: "x")]); XCTFail("accepted truncated patch") }
        catch { XCTAssertEqual(error as? PRReviewError, .invalidComment) }
    }

    func testCheckFailuresAndUnavailableChecksAreNotReportedAsPassing() async throws {
        let transport = ReviewFixtureTransport()
        await transport.set("/commits/\(ReviewFixtureTransport.head)/check-runs?per_page=100&page=1", json: #"{"total_count":1,"check_runs":[{"status":"completed","conclusion":"failure"}]}"#)
        let snapshot = try await client(transport).load(key: key, accountLogin: "alice", sinceSHA: nil)
        XCTAssertTrue(snapshot.checksSummary.contains("1 failed"))
        await transport.set("/commits/\(ReviewFixtureTransport.head)/check-runs?per_page=100&page=1", json: "{}", status: 403)
        let unavailable = try await client(transport).load(key: key, accountLogin: "alice", sinceSHA: nil)
        XCTAssertTrue(unavailable.notices.contains { $0.lowercased().contains("checks") })
        XCTAssertTrue(unavailable.checksSummary.lowercased().contains("unavailable"))
    }

    func testHTTPFailuresArePreservedAndNeverRetriedAsWrites() async throws {
        let transport = ReviewFixtureTransport()
        await transport.setPostStatus(422)
        do { try await client(transport).submit(key: key, accountLogin: "alice", headSHA: ReviewFixtureTransport.head, baseSHA: ReviewFixtureTransport.base, event: .approve, body: "", comments: []); XCTFail("accepted failed submission") }
        catch { XCTAssertEqual(error as? PRReviewError, .submissionRejected) }
        let writes = await transport.writes
        XCTAssertEqual(writes.count, 1)
    }

    func testRequestUsesOnlyBoundAccountAndExplicitJSONPost() throws {
        let account = ReviewFixtureAccount().resolved
        let request = try URLSessionPRReviewTransport.request(path: "/repos/org/repo/pulls/7/reviews", account: account, body: Data("{}".utf8))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.url?.host, "api.github.com")
        XCTAssertThrowsError(try URLSessionPRReviewTransport.request(path: "//evil.test", account: account, body: nil))
    }

    func testCompareRequestAllowsSHARangeWithoutAllowingTraversalOrAnotherHost() throws {
        let path = "/repos/org/repo/compare/\(ReviewFixtureTransport.baseline)...\(ReviewFixtureTransport.head)?per_page=100&page=1"
        let request = try URLSessionPRReviewTransport.request(path: path, account: ReviewFixtureAccount().resolved, body: nil)
        XCTAssertEqual(request.url?.path, String(path.split(separator: "?")[0]))
        XCTAssertEqual(request.httpMethod, "GET")
        for invalid in ["https://evil.test/", "//evil.test/", "/repos/../user", "/repos/%2e%2e/user"] {
            XCTAssertThrowsError(try URLSessionPRReviewTransport.request(path: invalid, account: ReviewFixtureAccount().resolved, body: nil))
        }
    }

    func testOversizedResponseIsRejectedBeforeDecoding() async throws {
        let transport = ReviewFixtureTransport()
        let service = PRReviewClient(accountConnection: ReviewFixtureAccount(), transport: transport, maximumResponseBytes: 10)
        do { _ = try await service.load(key: key, accountLogin: "alice", sinceSHA: nil); XCTFail("accepted oversized data") }
        catch { XCTAssertEqual(error as? PRSearchError, .responseTooLarge) }
    }

    func testIncompleteFileListIsDisclosedAndCannotBeUsedForSubmission() async throws {
        let transport = ReviewFixtureTransport()
        await transport.setDetail(changedFiles: 2)
        let service = client(transport)
        let snapshot = try await service.load(key: key, accountLogin: "alice", sinceSHA: nil)
        XCTAssertTrue(snapshot.notices.contains { $0.contains("incomplete") })
        XCTAssertFalse(snapshot.fileListComplete)
        XCTAssertFalse(snapshot.canDraftInlineComment(in: "a.swift"))
        do { try await service.submit(key: key, accountLogin: "alice", headSHA: snapshot.headSHA, baseSHA: snapshot.baseSHA, event: .comment, body: "Review", comments: [.init(path: "a.swift", line: 2, side: .right, body: "x")]); XCTFail("accepted incomplete file list") }
        catch { XCTAssertEqual(error as? PRReviewError, .invalidComment) }
    }

    func testHeadChangeImmediatelyBeforePostRejectsEvenBodyOnlyApproval() async throws {
        let transport = ReviewFixtureTransport()
        await transport.changeHeadAfterFirstRead()
        do { try await client(transport).submit(key: key, accountLogin: "alice", headSHA: ReviewFixtureTransport.head, baseSHA: ReviewFixtureTransport.base, event: .approve, body: "", comments: []); XCTFail("posted after head change") }
        catch { XCTAssertEqual(error as? PRReviewError, .revisionChanged) }
        let writes = await transport.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testChecksPaginationCountsFailureOnSecondPage() async throws {
        let transport = ReviewFixtureTransport()
        await transport.set("/commits/\(ReviewFixtureTransport.head)/check-runs?per_page=100&page=1", json: #"{"total_count":2,"check_runs":[{"status":"completed","conclusion":"success"}]}"#, next: true)
        await transport.set("/commits/\(ReviewFixtureTransport.head)/check-runs?per_page=100&page=2", json: #"{"total_count":2,"check_runs":[{"status":"completed","conclusion":"failure"}]}"#)
        let snapshot = try await client(transport).load(key: key, accountLogin: "alice", sinceSHA: nil)
        XCTAssertTrue(snapshot.checksSummary.contains("1 passed, 1 failed"))
    }

    func testRateLimitAndDeniedResponsesAreNotEmptySuccessfulSnapshots() async throws {
        for (status, expected) in [(429, PRSearchError.rateLimited(until: nil)), (404, .accessDenied)] {
            let transport = ReviewFixtureTransport()
            await transport.set("/pulls/7", json: "{}", status: status)
            do { _ = try await client(transport).load(key: key, accountLogin: "alice", sinceSHA: nil); XCTFail("accepted HTTP error") }
            catch { XCTAssertEqual(error as? PRSearchError, expected) }
        }
    }

    func testComparisonStateDoesNotBleedBetweenAccounts() async throws {
        let transport = ReviewFixtureTransport()
        let service = PRReviewClient(accountConnection: SelectedReviewFixtureAccount(), transport: transport)
        _ = try await service.load(key: key, accountLogin: "alice", sinceSHA: ReviewFixtureTransport.baseline)
        try await service.submit(key: key, accountLogin: "bob", headSHA: ReviewFixtureTransport.head, baseSHA: ReviewFixtureTransport.base, event: .comment, body: "Review", comments: [.init(path: "a.swift", line: 2, side: .right, body: "x")])
        let writes = await transport.writes
        XCTAssertEqual(writes.first?.login, "bob")
    }

    func testPersistedDraftRoundTripKeepsComparisonProvenance() throws {
        let draft = PRReviewDraftComment(path: "a.swift", line: 2, side: .left, body: "Review", comparisonBaseSHA: ReviewFixtureTransport.baseline)
        let decoded = try JSONDecoder().decode(PRReviewDraftComment.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(decoded, draft)
        let legacy = Data(#"{"id":"00000000-0000-0000-0000-000000000001","path":"a.swift","line":2,"side":"RIGHT","body":"Review"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(PRReviewDraftComment.self, from: legacy).comparisonBaseSHA)
    }

    func testInlineEligibilityDefaultsToFalseAndRejectsEvenCompleteComparison() async throws {
        let loaded = try await client(ReviewFixtureTransport()).load(key: key, accountLogin: "alice", sinceSHA: nil)
        let unknown = PRReviewSnapshot(key: loaded.key, title: loaded.title, body: loaded.body,
            author: loaded.author, createdAt: loaded.createdAt, updatedAt: loaded.updatedAt,
            headSHA: loaded.headSHA, baseSHA: loaded.baseSHA, files: loaded.files, notices: [],
            comments: [], checksSummary: loaded.checksSummary)
        XCTAssertFalse(unknown.fileListComplete)
        XCTAssertFalse(unknown.canDraftInlineComment(in: "a.swift"))
        let comparison = PRReviewSnapshot(key: loaded.key, title: loaded.title, body: loaded.body,
            author: loaded.author, createdAt: loaded.createdAt, updatedAt: loaded.updatedAt,
            headSHA: loaded.headSHA, baseSHA: loaded.baseSHA, files: loaded.files, notices: [],
            comments: [], checksSummary: loaded.checksSummary,
            comparisonBaseSHA: ReviewFixtureTransport.baseline, fileListComplete: true)
        XCTAssertFalse(comparison.canDraftInlineComment(in: "a.swift"))
    }

    func testInvalidBaseSHAIsRejectedBeforeReadingOrWriting() async throws {
        for baseSHA in ["", "main", String(repeating: "g", count: 40), String(repeating: "b", count: 39), String(repeating: "b", count: 41)] {
            let transport = ReviewFixtureTransport()
            do {
                try await client(transport).submit(key: key, accountLogin: "alice",
                    headSHA: ReviewFixtureTransport.head, baseSHA: baseSHA, event: .approve, body: "", comments: [])
                XCTFail("accepted invalid base SHA")
            } catch { XCTAssertEqual(error as? PRReviewError, .invalidResponse) }
            let reads = await transport.reads
            let writes = await transport.writes
            XCTAssertTrue(reads.isEmpty)
            XCTAssertTrue(writes.isEmpty)
        }
    }

    func testBaseSHAAcceptsSame64DigitPolicyAsHead() async throws {
        let transport = ReviewFixtureTransport()
        let baseSHA = String(repeating: "d", count: 64)
        await transport.setBaseSHA(baseSHA)
        try await client(transport).submit(key: key, accountLogin: "alice",
            headSHA: ReviewFixtureTransport.head, baseSHA: baseSHA, event: .approve, body: "", comments: [])
        let writes = await transport.writes
        XCTAssertEqual(writes.count, 1)
    }

    func testStaleBaseRejectsBodyOnlyApproval() async throws {
        let transport = ReviewFixtureTransport()
        do {
            try await client(transport).submit(key: key, accountLogin: "alice",
                headSHA: ReviewFixtureTransport.head, baseSHA: ReviewFixtureTransport.baseline,
                event: .approve, body: "", comments: [])
            XCTFail("accepted stale base for body-only approval")
        } catch { XCTAssertEqual(error as? PRReviewError, .revisionChanged) }
        let reads = await transport.reads
        let writes = await transport.writes
        XCTAssertEqual(reads, ["/repos/org/repo/pulls/7"])
        XCTAssertTrue(writes.isEmpty)
    }

    func testInlineOnlyCommentReviewIsAcceptedButEmptyReviewAndChangesWithoutSummaryAreRejected() async throws {
        let transport = ReviewFixtureTransport()
        let inline = PRReviewDraftComment(path: "a.swift", line: 2, side: .right, body: "Check this")
        try await client(transport).submit(key: key, accountLogin: "alice", headSHA: ReviewFixtureTransport.head,
            baseSHA: ReviewFixtureTransport.base, event: .comment, body: "", comments: [inline])
        let writes = await transport.writes
        XCTAssertEqual(writes.count, 1)
        for event in [PRReviewEvent.comment, .requestChanges] {
            do {
                try await client(transport).submit(key: key, accountLogin: "alice", headSHA: ReviewFixtureTransport.head,
                    baseSHA: ReviewFixtureTransport.base, event: event, body: "  ", comments: event == .comment ? [] : [inline])
                XCTFail("accepted review without required content")
            } catch { XCTAssertEqual(error as? PRReviewError, .invalidReview) }
        }
    }

    func testAmbiguousSuccessfulHTTPResponseIsNotConfirmationAndIsNeverRetried() async throws {
        for response in ["{}", "not JSON", #"{"id":9,"commit_id":"wrong","state":"APPROVED"}"#,
                         "{\"id\":9,\"commit_id\":\"\(ReviewFixtureTransport.head)\",\"state\":\"PENDING\"}"] {
            let transport = ReviewFixtureTransport()
            await transport.setPostBody(response)
            do {
                try await client(transport).submit(key: key, accountLogin: "alice", headSHA: ReviewFixtureTransport.head,
                    baseSHA: ReviewFixtureTransport.base, event: .approve, body: "", comments: [])
                XCTFail("accepted ambiguous response")
            } catch { XCTAssertEqual(error as? PRReviewError, .invalidResponse) }
            let writes = await transport.writes
            XCTAssertEqual(writes.count, 1)
        }
    }

    func testSubmissionReceiptConfirmsCommitAndDecision() async throws {
        let receipt = try await client(ReviewFixtureTransport()).submit(key: key, accountLogin: "alice",
            headSHA: ReviewFixtureTransport.head, baseSHA: ReviewFixtureTransport.base,
            event: .approve, body: "", comments: [])
        XCTAssertEqual(receipt.id, 42)
        XCTAssertEqual(receipt.headSHA, ReviewFixtureTransport.head)
        XCTAssertEqual(receipt.event, .approve)
    }

    func testInlineCommentsDecodeSideAndOutdatedCoordinatesWithoutGuessing() async throws {
        let transport = ReviewFixtureTransport()
        await transport.set("/pulls/7/comments?per_page=100&page=1", json: #"[{"id":1,"body":"deleted","path":"a.swift","line":2,"side":"LEFT"},{"id":2,"body":"outdated","path":"a.swift","line":null,"original_line":2,"side":"RIGHT"}]"#)
        let snapshot = try await client(transport).load(key: key, accountLogin: "alice", sinceSHA: nil)
        let left = try XCTUnwrap(snapshot.comments.first { $0.id == "inline:1" })
        XCTAssertEqual(left.side, .left)
        XCTAssertFalse(left.isOutdated)
        let old = try XCTUnwrap(snapshot.comments.first { $0.id == "inline:2" })
        XCTAssertTrue(old.isOutdated)
        XCTAssertNil(old.line)
        XCTAssertEqual(old.originalLine, 2)
    }

    private func client(_ transport: ReviewFixtureTransport) -> PRReviewClient {
        PRReviewClient(accountConnection: ReviewFixtureAccount(), transport: transport)
    }
}

private struct SelectedReviewFixtureAccount: AccountConnection {
    func inspect(selectedLogin: String?) async -> AccountConnectionResult {
        .connected(ReviewFixtureAccount(login: selectedLogin ?? "").resolved)
    }
}

private struct ReviewFixtureAccount: AccountConnection {
    var login = "alice"
    var host = "github.com"
    var resolved: ResolvedAccount {
        ResolvedAccount(login: login, hostname: host, scopes: [], accessCoverage: .init(isComplete: true), accessToken: GitHubAccessToken("fixture-token"))
    }
    func inspect(selectedLogin: String?) async -> AccountConnectionResult { .connected(resolved) }
}

private actor ReviewFixtureTransport: PRReviewTransport {
    static let head = String(repeating: "a", count: 40)
    static let base = String(repeating: "b", count: 40)
    static let baseline = String(repeating: "c", count: 40)
    static let files = #"[{"filename":"a.swift","patch":"@@ -1,3 +1,3 @@\n same\n-old\n+new\n tail","additions":1,"deletions":1}]"#
    struct Write: Sendable { let path: String; let login: String; let body: Data }
    var reads: [String] = []
    var writes: [Write] = []
    private var routes: [String: GitHubTransportResponse] = [:]
    private var changedFiles = 1
    private var baseSHA = ReviewFixtureTransport.base
    private var movingHead = false
    private var detailReads = 0
    private var postStatus = 200
    private var postBody: String?
    func setPostBody(_ value: String) { postBody = value }

    func set(_ suffix: String, json: String, next: Bool = false, status: Int = 200) {
        routes[suffix] = .init(statusCode: status, headers: next ? ["Link": "<https://api.github.com/ignored>; rel=\"next\""] : [:], data: Data(json.utf8))
    }
    func setDetail(changedFiles: Int) { self.changedFiles = changedFiles }
    func setBaseSHA(_ value: String) { baseSHA = value }
    func changeHeadAfterFirstRead() { movingHead = true }
    func setPostStatus(_ value: Int) { postStatus = value }

    func get(path: String, account: ResolvedAccount) async throws -> GitHubTransportResponse {
        reads.append(path)
        let suffix = String(path.dropFirst("/repos/org/repo".count))
        if let response = routes[suffix] { return response }
        let json: String
        if suffix == "/pulls/7" {
            detailReads += 1
            let head = movingHead && detailReads > 1 ? Self.baseline : Self.head
            json = """
            {"node_id":"PR_7","number":7,"title":"Review me","body":"Description","html_url":"https://github.com/org/repo/pull/7","state":"open","draft":false,"user":{"login":"author"},"created_at":"2026-10-24T12:00:00Z","updated_at":"2026-10-25T12:00:00Z","head":{"sha":"\(head)"},"base":{"sha":"\(baseSHA)","repo":{"node_id":"R_1","full_name":"org/repo"}},"changed_files":\(changedFiles)}
            """
        } else if suffix.contains("/files?") { json = Self.files }
        else if suffix.contains("/compare/") { json = "{\"files\":\(Self.files.replacingOccurrences(of: "a.swift", with: "since.swift")),\"merge_base_commit\":{\"sha\":\"\(Self.baseline)\"}}" }
        else if suffix.contains("/check-runs?") { json = #"{"total_count":0,"check_runs":[]}"# }
        else if suffix.contains("/status") { json = #"{"state":"pending","total_count":0,"statuses":[]}"# }
        else if suffix.contains("/comments?") || suffix.contains("/reviews?") { json = "[]" }
        else { throw PRSearchError.invalidResponse }
        return .init(statusCode: 200, headers: [:], data: Data(json.utf8))
    }
    func post(path: String, account: ResolvedAccount, body: Data) async throws -> GitHubTransportResponse {
        writes.append(Write(path: path, login: account.login, body: body))
        return .init(statusCode: postStatus, headers: [:], data: Data((postBody ?? "{\"id\":42,\"commit_id\":\"\(Self.head)\",\"state\":\"\(reviewState(body))\"}").utf8))
    }
    private func reviewState(_ body: Data) -> String {
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        switch payload?["event"] as? String {
        case "APPROVE": return "APPROVED"
        case "REQUEST_CHANGES": return "CHANGES_REQUESTED"
        default: return "COMMENTED"
        }
    }
}
