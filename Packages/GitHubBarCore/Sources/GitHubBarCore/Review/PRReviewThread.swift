import Foundation

public struct PRReviewAnchor: Equatable, Sendable {
    public let path: String
    public let line: Int
    public let side: PRReviewDraftComment.Side
}

public struct PRReviewThread: Identifiable, Equatable, Sendable {
    public let id: String
    public let root: PRReviewComment?
    public let comments: [PRReviewComment]
    public var isInline: Bool { comments.contains { $0.path != nil || $0.id.hasPrefix("inline:") || $0.replyToID != nil } }

    public static func group(_ comments: [PRReviewComment]) -> [PRReviewThread] {
        var byID: [String: PRReviewComment] = [:]
        for comment in comments { byID[comment.id] = comment }
        func rootID(_ comment: PRReviewComment) -> String {
            var current = comment
            var seen = Set<String>()
            while let parent = current.replyToID {
                guard seen.insert(current.id).inserted else { return seen.sorted().first ?? current.id }
                guard let next = byID[parent] else { return parent }
                current = next
            }
            return current.id
        }
        return Dictionary(grouping: byID.values, by: rootID).map { id, values in
            // A missing root or a corrupt reply cycle never supplies coordinates.
            let root = byID[id].flatMap { $0.replyToID == nil ? $0 : nil }
            let ordered = values.sorted {
                if $0.id == $1.id { return false }
                if $0.id == root?.id { return true }
                if $1.id == root?.id { return false }
                return ($0.createdAt ?? .distantPast, $0.id) < ($1.createdAt ?? .distantPast, $1.id)
            }
            return PRReviewThread(id: id, root: root, comments: ordered)
        }.sorted {
            ($0.root?.createdAt ?? $0.comments.first?.createdAt ?? .distantPast, $0.id) <
            ($1.root?.createdAt ?? $1.comments.first?.createdAt ?? .distantPast, $1.id)
        }
    }
}

extension PRReviewSnapshot {
    public var threads: [PRReviewThread] { PRReviewThread.group(comments) }

    public func anchor(for thread: PRReviewThread) -> PRReviewAnchor? {
        guard comparisonBaseSHA == nil, let root = thread.root, !root.isOutdated,
              let path = root.path, let line = root.line, let side = root.side,
              containsLine(path: path, line: line, side: side) else { return nil }
        return PRReviewAnchor(path: path, line: line, side: side)
    }

    public func containsLine(path: String, line: Int, side: PRReviewDraftComment.Side) -> Bool {
        guard comparisonBaseSHA == nil, canDraftInlineComment(in: path),
              let patch = files.first(where: { $0.path == path })?.patch else { return false }
        return PRDiffParser.parse(patch).contains {
            $0.kind != .hunk && (side == .left ? $0.oldLine : $0.newLine) == line
        }
    }

    public func anchorUnavailableReason(for thread: PRReviewThread) -> String? {
        guard anchor(for: thread) == nil else { return nil }
        guard let root = thread.root else { return "The root comment is unavailable. Read the complete thread on GitHub." }
        if root.isOutdated { return "Outdated conversation: GitHub no longer provides a current diff anchor." }
        if comparisonBaseSHA != nil { return "PR conversations use the full diff. Switch off the commit comparison to show this thread." }
        if root.path == nil { return thread.isInline ? "This conversation has no file anchor." : nil }
        if root.side == nil || root.line == nil { return "GitHub did not provide a current side and line for this conversation." }
        return "This anchor is outside the available complete diff. Open the conversation on GitHub."
    }
}
