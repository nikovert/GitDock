import Foundation

/// The pinned, private context prepared by the app. Repository contents remain untrusted.
public struct ReviewRepositoryContext: Codable, Equatable, Sendable {
    public var worktreePath: String
    public var contextDirectory: String
    public var manifestPath: String
    public var headSHA: String
    public var baseSHA: String
    public var mergeBaseSHA: String

    public init(worktreePath: String, contextDirectory: String, manifestPath: String,
                headSHA: String, baseSHA: String, mergeBaseSHA: String) {
        self.worktreePath = worktreePath
        self.contextDirectory = contextDirectory
        self.manifestPath = manifestPath
        self.headSHA = headSHA
        self.baseSHA = baseSHA
        self.mergeBaseSHA = mergeBaseSHA
    }

    @discardableResult
    public func validated() throws -> ReviewRepositoryContext {
        let paths = [worktreePath, contextDirectory, manifestPath]
        guard paths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.contains("\0") &&
            !$0.split(separator: "/").contains("..") }),
              worktreePath != "/", contextDirectory != "/",
              manifestPath == contextDirectory + "/manifest.json",
              contextDirectory != worktreePath, !contextDirectory.hasPrefix(worktreePath + "/"),
              !worktreePath.hasPrefix(contextDirectory + "/"),
              [headSHA, baseSHA, mergeBaseSHA].allSatisfy({ value in
                  (value.count == 40 || value.count == 64) && value.utf8.allSatisfy {
                      (48...57).contains($0) || (97...102).contains($0)
                  }
              }) else { throw ReviewChatError.invalidConfiguration("The repository review context is invalid. Prepare a fresh review worktree.") }
        return self
    }
}

public struct ReviewUnreviewedFile: Codable, Equatable, Sendable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// Agent-reported inspection coverage, never independent evidence of file reads.
public struct ReviewCoverage: Codable, Equatable, Sendable {
    public var reviewedPaths: [String]
    public var unreviewed: [ReviewUnreviewedFile]
    public var testsRun: [String]
    public var limitations: [String]

    public init(reviewedPaths: [String], unreviewed: [ReviewUnreviewedFile], testsRun: [String], limitations: [String]) {
        self.reviewedPaths = reviewedPaths
        self.unreviewed = unreviewed
        self.testsRun = testsRun
        self.limitations = limitations
    }

    @discardableResult
    public func validated() throws -> ReviewCoverage {
        guard testsRun.isEmpty, reviewedPaths.count + unreviewed.count <= 20_000,
              limitations.count <= 100, reviewedPaths.allSatisfy(Self.validPath),
              unreviewed.allSatisfy({ Self.validPath($0.path) && Self.validText($0.reason) }),
              limitations.allSatisfy(Self.validText) else { throw ReviewChatError.invalidResponse }
        let all = reviewedPaths + unreviewed.map(\.path)
        guard Set(all).count == all.count,
              all.reduce(0, { $0 + $1.utf8.count }) + unreviewed.reduce(0, { $0 + $1.reason.utf8.count }) +
                limitations.reduce(0, { $0 + $1.utf8.count }) <= 524_288 else {
            throw ReviewChatError.invalidResponse
        }
        return self
    }

    public func normalized(expectedPaths: [String]) throws -> ReviewCoverage {
        try validated()
        let expected = Set(expectedPaths)
        guard expectedPaths.count <= 20_000, expected.count == expectedPaths.count,
              expectedPaths.allSatisfy(Self.validPath),
              Set(reviewedPaths + unreviewed.map(\.path)).isSubset(of: expected) else {
            throw ReviewChatError.invalidResponse
        }
        var result = self
        let accounted = Set(reviewedPaths + unreviewed.map(\.path))
        result.unreviewed += expectedPaths.filter { !accounted.contains($0) }.map {
            ReviewUnreviewedFile(path: $0, reason: "The agent did not report coverage for this file.")
        }
        return try result.validated()
    }

    private static func validPath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4096 && !path.hasPrefix("/") && !path.contains("\0") &&
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." }
    }

    private static func validText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !text.contains("\0") && text.utf8.count <= 16_384
    }
}
