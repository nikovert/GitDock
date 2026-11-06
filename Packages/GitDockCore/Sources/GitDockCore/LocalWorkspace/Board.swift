import Foundation

public enum PullRequestKeyError: Error, Sendable {
    case invalidURL
}

public struct PullRequestKey: Codable, Hashable, Sendable, CustomStringConvertible {
    public let owner: String
    public let repository: String
    public let number: Int

    public init(url: URL) throws {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.scheme == "https", url.host?.lowercased() == "github.com",
              parts.count == 4, parts[2] == "pull",
              let number = Int(parts[3]), number > 0,
              Self.validName(parts[0]), Self.validName(parts[1]) else {
            throw PullRequestKeyError.invalidURL
        }
        owner = parts[0].lowercased()
        repository = parts[1].lowercased()
        self.number = number
    }

    public var description: String { "\(owner)/\(repository)#\(number)" }
    public var repositoryNameWithOwner: String { "\(owner)/\(repository)" }
    public var url: URL { URL(string: "https://github.com/\(owner)/\(repository)/pull/\(number)")! }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) ||
                ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 46 || $0 == 95
        } && name != "." && name != ".."
    }
}

public enum BoardSubject: Codable, Hashable, Sendable {
    case pullRequest(PullRequestKey)
    case stack(PullRequestKey)

    public var key: PullRequestKey {
        switch self {
        case let .pullRequest(key), let .stack(key): key
        }
    }
}

public enum BoardPriority: String, Codable, CaseIterable, Sendable {
    case none
    case low
    case medium
    case high
}

public enum BoardTagColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, gray
}

public struct BoardTag: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var color: BoardTagColor
    public var isArchived: Bool
    public let isBuiltIn: Bool

    public init(id: String, name: String, color: BoardTagColor, isArchived: Bool = false, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.isArchived = isArchived
        self.isBuiltIn = isBuiltIn
    }

    public static let builtIns: [BoardTag] = [
        BoardTag(id: "blocked", name: "Blocked", color: .red, isBuiltIn: true),
        BoardTag(id: "waiting-on-review", name: "Waiting on review", color: .yellow, isBuiltIn: true),
        BoardTag(id: "needs-rework", name: "Needs rework", color: .orange, isBuiltIn: true),
        BoardTag(id: "ready-to-merge", name: "Ready to merge", color: .green, isBuiltIn: true),
        BoardTag(id: "agent-running", name: "Agent running", color: .blue, isBuiltIn: true),
        BoardTag(id: "agent-needs-attention", name: "Agent needs attention", color: .purple, isBuiltIn: true),
    ]
}

public struct BoardEntry: Codable, Equatable, Identifiable, Sendable {
    public let subject: BoardSubject
    public var priority: BoardPriority?
    public var tagIDs: Set<String>?
    public var note: String?
    public var updatedAt: Date
    public var updatedBy: String

    public var id: BoardSubject { subject }

    public init(
        subject: BoardSubject,
        priority: BoardPriority? = nil,
        tagIDs: Set<String>? = nil,
        note: String? = nil,
        updatedAt: Date = .now,
        updatedBy: String = "local"
    ) {
        self.subject = subject
        self.priority = priority
        self.tagIDs = tagIDs
        self.note = note
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }
}

public struct ResolvedBoardEntry: Equatable, Sendable {
    public let priority: BoardPriority
    public let tagIDs: Set<String>
    public let note: String
    public let updatedBy: String?
}

public struct LocalWorkspaceDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var entries: [BoardEntry]
    public var tags: [BoardTag]
    public var sessions: [AgentSessionLink]
    public var configuration: WorkspaceConfiguration

    public static var empty: LocalWorkspaceDocument {
        LocalWorkspaceDocument()
    }

    public init(
        schemaVersion: Int = currentSchemaVersion,
        entries: [BoardEntry] = [],
        tags: [BoardTag] = BoardTag.builtIns,
        sessions: [AgentSessionLink] = [],
        configuration: WorkspaceConfiguration = WorkspaceConfiguration()
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.tags = tags
        self.sessions = sessions
        self.configuration = configuration
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, entries, tags, sessions, configuration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        entries = try container.decode([BoardEntry].self, forKey: .entries)
        tags = try container.decodeIfPresent([BoardTag].self, forKey: .tags) ?? BoardTag.builtIns
        sessions = try container.decodeIfPresent([AgentSessionLink].self, forKey: .sessions) ?? []
        configuration = try container.decodeIfPresent(WorkspaceConfiguration.self, forKey: .configuration)
            ?? WorkspaceConfiguration()
    }

    public mutating func setEntry(_ entry: BoardEntry) {
        if let index = entries.firstIndex(where: { $0.subject == entry.subject }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    public func entry(for subject: BoardSubject) -> BoardEntry? {
        entries.first { $0.subject == subject }
    }

    public func resolvedEntry(for key: PullRequestKey, stackRoot: PullRequestKey? = nil) -> ResolvedBoardEntry {
        let parent = stackRoot.flatMap { entry(for: .stack($0)) }
        let child = entry(for: .pullRequest(key))
        let source = child?.updatedAt ?? parent?.updatedAt
        let updatedBy = source == child?.updatedAt ? child?.updatedBy : parent?.updatedBy
        return ResolvedBoardEntry(
            priority: child?.priority ?? parent?.priority ?? .none,
            tagIDs: child?.tagIDs ?? parent?.tagIDs ?? [],
            note: child?.note ?? parent?.note ?? "",
            updatedBy: updatedBy
        )
    }

    public func resolvedEntry(for subject: BoardSubject, stackRoot: PullRequestKey? = nil) -> ResolvedBoardEntry {
        switch subject {
        case let .pullRequest(key):
            return resolvedEntry(for: key, stackRoot: stackRoot)
        case let .stack(key):
            let entry = entry(for: .stack(key))
            return ResolvedBoardEntry(
                priority: entry?.priority ?? .none,
                tagIDs: entry?.tagIDs ?? [],
                note: entry?.note ?? "",
                updatedBy: entry?.updatedBy
            )
        }
    }

    public mutating func setTag(_ tag: BoardTag) {
        if let index = tags.firstIndex(where: { $0.id == tag.id }) {
            tags[index] = tag
        } else {
            tags.append(tag)
        }
    }

    public mutating func setSession(_ session: AgentSessionLink) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
    }

    public mutating func removeSession(id: UUID) {
        sessions.removeAll { $0.id == id }
    }

    public func sessions(for subject: BoardSubject) -> [AgentSessionLink] {
        sessions.filter { $0.subject == subject }
    }
}
