import Foundation
import XCTest
@testable import GitHubBarCore

final class ReviewRepositoryProtocolTests: XCTestCase, @unchecked Sendable {
    func testCoverageAddsMissingPathsAndRejectsFalseExecutionAndAmbiguity() throws {
        let partial = ReviewCoverage(reviewedPaths: ["a"], unreviewed: [], testsRun: [], limitations: [])
        let result = try partial.normalized(expectedPaths: ["a", "b"])
        XCTAssertEqual(result.reviewedPaths, ["a"])
        XCTAssertEqual(result.unreviewed.map(\.path), ["b"])
        XCTAssertFalse(result.unreviewed[0].reason.isEmpty)
        for coverage in [
            ReviewCoverage(reviewedPaths: ["unknown"], unreviewed: [], testsRun: [], limitations: []),
            ReviewCoverage(reviewedPaths: ["a", "a"], unreviewed: [], testsRun: [], limitations: []),
            ReviewCoverage(reviewedPaths: ["a"], unreviewed: [.init(path: "a", reason: "skip")], testsRun: [], limitations: []),
            ReviewCoverage(reviewedPaths: [], unreviewed: [.init(path: "a", reason: " ")], testsRun: [], limitations: []),
            ReviewCoverage(reviewedPaths: [], unreviewed: [], testsRun: ["swift test"], limitations: []),
            ReviewCoverage(reviewedPaths: ["../a"], unreviewed: [], testsRun: [], limitations: [])
        ] { XCTAssertThrowsError(try coverage.normalized(expectedPaths: ["a", "b"])) }
    }

    func testCoverageBoundsAndDuplicateExpectedPaths() throws {
        let coverage = ReviewCoverage(reviewedPaths: [], unreviewed: [], testsRun: [], limitations: [])
        XCTAssertThrowsError(try coverage.normalized(expectedPaths: ["a", "a"]))
        XCTAssertThrowsError(try coverage.normalized(expectedPaths: ["/a"]))
        XCTAssertThrowsError(try ReviewCoverage(reviewedPaths: [], unreviewed: [], testsRun: [],
            limitations: [String(repeating: "x", count: 16_385)]).normalized(expectedPaths: []))
    }

    func testWorktreeClientRequiresRepositoryFindingsCoverageAndBundledProvider() async throws {
        let fixture = try adapterFixture(delay: 0)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let client = ReviewChatClient()
        var request = repositoryRequest
        request.repository = nil
        do { _ = try await client.send(request, configuration: fixture.configuration); XCTFail("Missing repository accepted") }
        catch { XCTAssertEqual(error as? ReviewChatError, .invalidResponse) }
        var custom = fixture.configuration
        custom.provider = .custom
        do { _ = try await client.send(repositoryRequest, configuration: custom); XCTFail("Custom provider accepted") }
        catch { XCTAssertEqual(error as? ReviewChatError, .invalidResponse) }
        for invalid in ["missingCoverage", "missingFindings", "testsRun", "overlap"] {
            var configuration = fixture.configuration
            configuration.arguments = [invalid]
            do { _ = try await client.send(repositoryRequest, configuration: configuration); XCTFail("Accepted \(invalid)") }
            catch { XCTAssertEqual(error as? ReviewChatError, .invalidResponse) }
        }
        let response = try await client.send(repositoryRequest, configuration: fixture.configuration)
        XCTAssertEqual(response.coverage?.reviewedPaths, ["a"])
    }

    func testWorktreeClientUsesItsSeparateDeadline() async throws {
        let fixture = try adapterFixture(delay: 0.15)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let response = try await ReviewChatClient(timeout: 0.01, worktreeTimeout: 2)
            .send(repositoryRequest, configuration: fixture.configuration)
        XCTAssertEqual(response.findings, [])
        do {
            _ = try await ReviewChatClient(timeout: 2, worktreeTimeout: 0.01)
                .send(repositoryRequest, configuration: fixture.configuration)
            XCTFail("Worktree timeout ignored")
        } catch { XCTAssertEqual(error as? ReviewChatError, .timedOut) }
    }

    private var repositoryRequest: ReviewChatRequest {
        let sha = String(repeating: "a", count: 40)
        return ReviewChatRequest(accountLogin: "me", prURL: "url", headSHA: sha, question: "review",
            context: "", policy: "", messages: [], task: .worktreeReview,
            repository: .init(worktreePath: "/tmp/tree", contextDirectory: "/tmp/context",
                              manifestPath: "/tmp/context/manifest.json", headSHA: sha, baseSHA: sha, mergeBaseSHA: sha))
    }

    private func adapterFixture(delay: Double) throws -> (directory: URL, configuration: ReviewChatConfiguration) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("review-protocol-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("adapter")
        let body = #"""
        #!/usr/bin/perl
        use strict; use warnings; use JSON::PP;
        my $request = decode_json(do { local $/; <STDIN> });
        select(undef, undef, undef, DELAY);
        my $coverage = {reviewedPaths => ['a'], unreviewed => [], testsRun => [], limitations => []};
        my $response = {prURL => $request->{prURL}, headSHA => $request->{headSHA}, answer => 'Inspected',
                        citations => [], findings => [], coverage => $coverage};
        my $mode = $ARGV[0] // '';
        delete $response->{coverage} if $mode eq 'missingCoverage';
        delete $response->{findings} if $mode eq 'missingFindings';
        $coverage->{testsRun} = ['swift test'] if $mode eq 'testsRun';
        $coverage->{unreviewed} = [{path => 'a', reason => 'skip'}] if $mode eq 'overlap';
        print encode_json($response);
        """#.replacingOccurrences(of: "DELAY", with: String(delay))
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (directory, ReviewChatConfiguration(displayName: "Fixture", executable: script.path,
                                                    workingDirectory: directory.path, provider: .codex))
    }

    func testRepositoryAndCoverageRoundTripAndLegacyDefaults() throws {
        let context = ReviewRepositoryContext(worktreePath: "/tmp/tree", contextDirectory: "/tmp/context",
            manifestPath: "/tmp/context/manifest.json", headSHA: String(repeating: "a", count: 40),
            baseSHA: String(repeating: "b", count: 40), mergeBaseSHA: String(repeating: "c", count: 40))
        XCTAssertEqual(try JSONDecoder().decode(ReviewRepositoryContext.self, from: JSONEncoder().encode(context)), context)
        let request = ReviewChatRequest(accountLogin: "me", prURL: "url", headSHA: context.headSHA,
            question: "review", context: "", policy: "", messages: [], task: .worktreeReview, repository: context)
        XCTAssertEqual(try JSONDecoder().decode(ReviewChatRequest.self, from: JSONEncoder().encode(request)).repository, context)
        let legacy = Data(#"{"prURL":"url","headSHA":"sha","answer":"answer","citations":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ReviewChatResponse.self, from: legacy).coverage)
    }
}
