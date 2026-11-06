import Foundation

public struct ReviewWorktreeRequest: Equatable, Sendable {
    public let key: PullRequestKey
    public let accountLogin: String
    public let headSHA: String
    public let baseSHA: String

    public init(key: PullRequestKey, accountLogin: String, headSHA: String, baseSHA: String) {
        self.key = key
        self.accountLogin = accountLogin
        self.headSHA = headSHA
        self.baseSHA = baseSHA
    }
}

public struct ReviewWorktreeLease: Equatable, Sendable {
    public let id: UUID
    public let key: PullRequestKey
    public let accountLogin: String
    public let headSHA: String
    public let baseSHA: String
    public let mergeBaseSHA: String
    public let worktreePath: String
    public let contextDirectory: String
    public let manifestPath: String
    public let changedPaths: [String]

    public init(id: UUID, key: PullRequestKey, accountLogin: String, headSHA: String,
                baseSHA: String, mergeBaseSHA: String, worktreePath: String,
                contextDirectory: String, manifestPath: String, changedPaths: [String]) {
        self.id = id
        self.key = key
        self.accountLogin = accountLogin
        self.headSHA = headSHA
        self.baseSHA = baseSHA
        self.mergeBaseSHA = mergeBaseSHA
        self.worktreePath = worktreePath
        self.contextDirectory = contextDirectory
        self.manifestPath = manifestPath
        self.changedPaths = changedPaths
    }
}

public protocol ReviewWorktreeServicing: Sendable {
    func prepare(_ request: ReviewWorktreeRequest) async throws -> ReviewWorktreeLease
    func validate(_ lease: ReviewWorktreeLease) async throws
    func release(_ lease: ReviewWorktreeLease) async -> String?
}

public enum ReviewWorktreeError: Error, LocalizedError, Sendable {
    case failed(String)
    public var errorDescription: String? {
        switch self { case .failed(let message): message }
    }
}

struct ReviewWorktreeManifest: Codable, Equatable, Sendable {
    let version: Int
    let worktreePath: String
    let headSHA: String
    let baseSHA: String
    let mergeBaseSHA: String
    let files: [File]

    struct File: Codable, Equatable, Sendable {
        let path: String
        let previousPath: String?
        let status: String
        let patchFile: String
        let baseFile: String?
        let isBinary: Bool
        let isSymlink: Bool
    }
}
