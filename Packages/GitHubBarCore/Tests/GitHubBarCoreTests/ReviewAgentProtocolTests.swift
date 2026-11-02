import Foundation
import XCTest
@testable import GitHubBarCore

final class ReviewAgentProtocolTests: XCTestCase, @unchecked Sendable {
    private func request(review: Bool = true) throws -> ReviewChatRequest {
        var value: [String: Any] = ["accountLogin": "reviewer", "prURL": "https://github.com/o/r/pull/7",
            "headSHA": "head", "question": "Review this PR", "context": "diff", "policy": "read only", "messages": []]
        if review { value["task"] = "review" }
        return try JSONDecoder().decode(ReviewChatRequest.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func response(findings: Any? = nil) -> [String: Any] {
        var value: [String: Any] = ["prURL": "https://github.com/o/r/pull/7", "headSHA": "head",
                                  "answer": "Reviewed supplied changes", "citations": []]
        if let findings { value["findings"] = findings }
        return value
    }

    func testLegacyChatRoundTripOmitsNewOptionalFields() throws {
        let legacy = try request(review: false)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertNil(encoded["task"])
        let decoded = try JSONDecoder().decode(ReviewChatResponse.self, from: JSONSerialization.data(withJSONObject: response()))
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertNil(wire["findings"])
    }

    func testReviewPreservesStructuredAndGeneralFindingsWithoutInventingCoordinates() async throws {
        let findings: [[String: Any]] = [["body": "Handle an empty batch", "path": "src/file.swift", "line": 12, "side": "LEFT"],
                                       ["body": "Document the migration"], ["body": "Inspect missing context", "path": "missing.swift"]]
        let result = try await exchange(response(findings: findings))
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        let actual = try XCTUnwrap(wire["findings"] as? [[String: Any]])
        XCTAssertEqual(actual.count, 3)
        XCTAssertEqual(actual[0]["side"] as? String, "LEFT")
        XCTAssertNil(actual[1]["path"])
        XCTAssertNil(actual[2]["line"])
    }

    func testExplicitEmptyFindingsMeansSuccessfulReview() async throws {
        let result = try await exchange(response(findings: []))
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertEqual((wire["findings"] as? [Any])?.count, 0)
    }

    func testReviewRejectsMissingMalformedAndUnboundedFindings() async throws {
        let invalid: [Any?] = [nil, NSNull(), "prose", [["path": "src/file.swift"]], [["body": "  \n"]],
            [["body": "x\0y"]], [["body": "x", "path": "../secret"]], [["body": "x", "path": "/absolute"]],
            [["body": "x", "line": 0]], [["body": "x", "line": true]], [["body": "x", "side": "OTHER"]],
            [["body": String(repeating: "é", count: 8_193)]], Array(repeating: ["body": "x"], count: 101),
            Array(repeating: ["body": String(repeating: "x", count: 16_384)], count: 17)]
        for findings in invalid {
            do { _ = try await exchange(response(findings: findings)); XCTFail("Accepted invalid findings: \(String(describing: findings).prefix(100))") }
            catch { XCTAssertEqual(error as? ReviewChatError, .invalidResponse) }
        }
    }

    func testReviewRejectsWrongIdentity() async throws {
        var output = response(findings: [])
        output["headSHA"] = "stale"
        do { _ = try await exchange(output); XCTFail("Accepted stale review") }
        catch { XCTAssertEqual(error as? ReviewChatError, .mismatchedResponse) }
    }

    private func exchange(_ value: [String: Any]) async throws -> ReviewChatResponse {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("review-protocol-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("response.json")
        try JSONSerialization.data(withJSONObject: value).write(to: output)
        let executable = directory.appendingPathComponent("adapter")
        try Data("#!/usr/bin/perl\nlocal $/; <STDIN>; open(my $f, '<', 'response.json') or die; print <$f>;\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return try await ReviewChatClient().send(request(), configuration: ReviewChatConfiguration(
            executable: executable.path, workingDirectory: directory.path))
    }
}
