import Foundation
import XCTest
@testable import GitDockCore

final class ReviewChatProviderTests: XCTestCase {
    func testLegacyConfigurationInfersProviderAndRoundTrips() throws {
        let raw = Data(#"{"displayName":"My agent","executable":"/usr/bin/python3","arguments":["adapter.py","--provider","claude","--cli","/usr/local/bin/claude"],"workingDirectory":"/tmp"}"#.utf8)
        let value = try JSONDecoder().decode(ReviewChatConfiguration.self, from: raw)
        XCTAssertEqual(value.provider, .claude)
        XCTAssertEqual(try JSONDecoder().decode(ReviewChatConfiguration.self, from: JSONEncoder().encode(value)), value)
    }

    func testLegacyCustomConfigurationRemainsCustom() throws {
        let raw = Data(#"{"displayName":"Codex custom adapter","executable":"/adapter","arguments":[],"workingDirectory":"/tmp"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ReviewChatConfiguration.self, from: raw).provider, .custom)
    }

    func testDetectionIgnoresNonexecutablesAndPrefersCodexWithoutOverridingSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["codex", "claude"] {
            let file = directory.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        var detection = ReviewChatProviderDetection(searchPaths: [directory.path])
        XCTAssertNil(detection.preferredProvider)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.appendingPathComponent("claude").path)
        detection = ReviewChatProviderDetection(searchPaths: [directory.path])
        XCTAssertEqual(detection.preferredProvider, .claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.appendingPathComponent("codex").path)
        detection = ReviewChatProviderDetection(searchPaths: [directory.path])
        XCTAssertEqual(detection.preferredProvider, .codex)
        XCTAssertEqual(detection.selection(persisted: .claude), .claude)
        XCTAssertEqual(detection.selection(persisted: .custom), .custom)
        XCTAssertEqual(detection.executable(for: .codex)?.path, directory.appendingPathComponent("codex").path)
    }
}
