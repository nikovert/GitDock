import Foundation

public enum AgentKind: String, Codable, CaseIterable, Hashable, Sendable {
    case codex
    case claude
}

public enum AgentSessionState: String, Codable, Sendable {
    case running
    case stopped
    case failed
}

public struct AgentSessionLink: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let subject: BoardSubject
    public let agent: AgentKind
    public let worktreePath: String
    public let tmuxSessionName: String?
    public let managedWorktree: Bool
    public var state: AgentSessionState
    public let createdAt: Date
    public var lastSeenAt: Date?

    public var tmuxSessionTarget: String? {
        tmuxSessionName.map { "=\($0):" }
    }

    public init(
        id: UUID = UUID(),
        subject: BoardSubject,
        agent: AgentKind,
        worktreePath: String,
        tmuxSessionName: String?,
        managedWorktree: Bool = false,
        state: AgentSessionState = .running,
        createdAt: Date = .now,
        lastSeenAt: Date? = nil
    ) {
        self.id = id
        self.subject = subject
        self.agent = agent
        self.worktreePath = worktreePath
        self.tmuxSessionName = tmuxSessionName
        self.managedWorktree = managedWorktree
        self.state = state
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }
}

public struct WorkspaceConfiguration: Codable, Equatable, Sendable {
    public var repositoryCheckouts: [String: String]
    public var worktreeRoot: String
    public var codexCommand: String
    public var claudeCommand: String

    public init(
        repositoryCheckouts: [String: String] = [:],
        worktreeRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/GitHub/.githubbar-worktrees").path,
        codexCommand: String = "codex",
        claudeCommand: String = "claude"
    ) {
        self.repositoryCheckouts = repositoryCheckouts
        self.worktreeRoot = worktreeRoot
        self.codexCommand = codexCommand
        self.claudeCommand = claudeCommand
    }
}
