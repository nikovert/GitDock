import Foundation

public enum WorkspaceBoardUpdateError: Error, LocalizedError, Sendable {
    case usage(String)
    case unknownTag(String)

    public var errorDescription: String? {
        switch self {
        case let .usage(message): message
        case let .unknownTag(tag): "Unknown tag: \(tag)"
        }
    }
}

public struct WorkspaceBoardUpdate: Sendable {
    public let subject: BoardSubject
    public let priority: BoardPriority?
    public let tagIDs: Set<String>?
    public let note: String?
    public let updatedBy: String

    public static func parse(_ arguments: [String]) throws -> WorkspaceBoardUpdate {
        guard arguments.first == "set" else {
            throw WorkspaceBoardUpdateError.usage("Expected 'set'")
        }
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard ["--pr", "--stack", "--priority", "--tags", "--note", "--by"].contains(flag),
                  index + 1 < arguments.count, values[flag] == nil else {
                throw WorkspaceBoardUpdateError.usage("Invalid or duplicate argument: \(flag)")
            }
            values[flag] = arguments[index + 1]
            index += 2
        }
        guard (values["--pr"] == nil) != (values["--stack"] == nil),
              let address = values["--pr"] ?? values["--stack"],
              let url = URL(string: address) else {
            throw WorkspaceBoardUpdateError.usage("Supply one --pr or --stack GitHub PR URL")
        }
        let key = try PullRequestKey(url: url)
        let subject: BoardSubject = values["--stack"] == nil ? .pullRequest(key) : .stack(key)
        let priority: BoardPriority?
        if let raw = values["--priority"] {
            guard let parsed = BoardPriority(rawValue: raw) else {
                throw WorkspaceBoardUpdateError.usage("Invalid priority: \(raw)")
            }
            priority = parsed
        } else {
            priority = nil
        }
        let tags = values["--tags"].map { raw in
            Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
        }
        let by = values["--by"] ?? "local"
        guard !by.isEmpty else { throw WorkspaceBoardUpdateError.usage("--by cannot be empty") }
        return WorkspaceBoardUpdate(
            subject: subject, priority: priority, tagIDs: tags,
            note: values["--note"], updatedBy: by
        )
    }

    public func apply(to document: inout LocalWorkspaceDocument) throws {
        if let tagIDs {
            let available = Set(document.tags.filter { !$0.isArchived }.map(\.id))
            if let unknown = tagIDs.subtracting(available).sorted().first {
                throw WorkspaceBoardUpdateError.unknownTag(unknown)
            }
        }
        var entry = document.entry(for: subject) ?? BoardEntry(subject: subject)
        if let priority { entry.priority = priority }
        if let tagIDs { entry.tagIDs = tagIDs }
        if let note { entry.note = note }
        entry.updatedAt = .now
        entry.updatedBy = updatedBy
        document.setEntry(entry)
    }
}
