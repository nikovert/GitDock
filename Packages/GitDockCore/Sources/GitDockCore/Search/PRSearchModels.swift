import Foundation

public enum PRSearchPhase: String, Equatable, Sendable {
    case idle, validating, indexing, paused, complete, rateLimited, connectionRequired, failed
}

public struct PRSearchProgress: Equatable, Sendable {
    public var discovered = 0
    public var indexed = 0
    public var partial = 0
    public var moreHistory = true
    public var lastRefresh: Date?
    public var scanStartedAt: Date?
    public var scanFinishedAt: Date?
    public var hasEvictedHistory = false
    public init() {}
}

public struct PRSearchState: Equatable, Sendable {
    public var accountLogin: String?
    public var repositoryNames: [String] = []
    public var query = ""
    public var submittedQuery: String?
    public var inYourList: [PRSearchResult] = []
    public var extendedResults: [PRSearchResult] = []
    public var phase: PRSearchPhase = .idle
    public var progress = PRSearchProgress()
    public var message: String?
    public init() {}
}

public enum PRSearchSource: String, Codable, Sendable {
    case title = "Title", description = "Description", file = "File", code = "Code"
}

public enum PRSearchLineKind: String, Codable, Sendable {
    case added = "Added", removed = "Removed", context = "Context"
}

public struct PRSearchCoverage: Codable, Equatable, Sendable {
    public var fileListComplete: Bool
    public var codeComplete: Bool
    public var reasons: [String]
    public init(fileListComplete: Bool = false, codeComplete: Bool = false, reasons: [String] = []) {
        self.fileListComplete = fileListComplete
        self.codeComplete = codeComplete
        self.reasons = reasons
    }
}

public struct PRSearchResult: Codable, Equatable, Identifiable, Sendable {
    public var id: String { PRSearchDocument.key(pullRequest) }
    public let pullRequest: PullRequestPresentation
    public let source: PRSearchSource
    public let excerpt: String
    public let path: String?
    public let lineKind: PRSearchLineKind?
    public let coverage: PRSearchCoverage
    public let score: Int
    public var filesURL: URL { pullRequest.url.appendingPathComponent("files") }
}

public struct PRSearchFile: Codable, Equatable, Sendable {
    public let path: String
    public let previousPath: String?
    public let patch: String?
    public let additions: Int
    public let deletions: Int
    public init(path: String, previousPath: String? = nil, patch: String?, additions: Int, deletions: Int) {
        self.path = path
        self.previousPath = previousPath
        self.patch = patch
        self.additions = additions
        self.deletions = deletions
    }

    var lines: [(String, PRSearchLineKind)] {
        guard let patch else { return [] }
        var inHunk = false
        return patch.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            if line.hasPrefix("@@") { inHunk = true; return nil }
            guard inHunk, let prefix = line.first else { return nil }
            let kind: PRSearchLineKind
            switch prefix {
            case "+": kind = .added
            case "-": kind = .removed
            case " ": kind = .context
            default: return nil
            }
            return (String(line.dropFirst()), kind)
        }
    }

    public var hasCompletePatch: Bool {
        guard let patch else { return false }
        var oldRemaining = 0
        var newRemaining = 0
        var added = 0
        var removed = 0
        var sawHunk = false
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@ ") {
                guard oldRemaining == 0, newRemaining == 0 else { return false }
                let parts = line.split(separator: " ")
                guard parts.count >= 4, parts[1].hasPrefix("-"), parts[2].hasPrefix("+"), parts[3] == "@@",
                      let old = Self.hunkCount(parts[1]), let new = Self.hunkCount(parts[2]) else { return false }
                oldRemaining = old; newRemaining = new; sawHunk = true
                continue
            }
            guard sawHunk else { return false }
            switch line.first {
            case "+": newRemaining -= 1; added += 1
            case "-": oldRemaining -= 1; removed += 1
            case " ": oldRemaining -= 1; newRemaining -= 1
            case "\\": break // Git's "No newline at end of file" marker.
            case nil: break
            default: return false
            }
            guard oldRemaining >= 0, newRemaining >= 0 else { return false }
        }
        return sawHunk && oldRemaining == 0 && newRemaining == 0 && added == additions && removed == deletions
    }

    private static func hunkCount(_ token: Substring) -> Int? {
        let range = token.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
        guard let start = range.first.flatMap({ Int($0) }), start >= 0, range.count <= 2 else { return nil }
        let count = range.count == 2 ? Int(range[1]) : 1
        return count.flatMap { $0 >= 0 ? $0 : nil }
    }
}

public struct PRSearchDocument: Codable, Equatable, Sendable {
    public var pullRequest: PullRequestPresentation
    public var body: String
    public var baseSHA: String
    public var headSHA: String
    public var changedFiles: Int
    public var files: [PRSearchFile]?
    public var coverage: PRSearchCoverage
    public var refreshedAt: Date
    public var id: String { Self.key(pullRequest) }

    public init(pullRequest: PullRequestPresentation, body: String, baseSHA: String, headSHA: String,
                changedFiles: Int, files: [PRSearchFile]?, coverage: PRSearchCoverage, refreshedAt: Date) {
        self.pullRequest = pullRequest
        self.body = body
        self.baseSHA = baseSHA
        self.headSHA = headSHA
        self.changedFiles = changedFiles
        self.files = files
        self.coverage = coverage
        self.refreshedAt = refreshedAt
    }

    static func key(_ pr: PullRequestPresentation) -> String {
        "\(pr.repositoryID)#\(pr.number)"
    }
}
