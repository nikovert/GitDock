import Foundation
import GitDockCore

struct CleanupActivityRun: Codable, Equatable, Identifiable {
    struct Entry: Codable, Equatable, Identifiable {
        var id: String { path }
        let path: String
        let title: String
        let outcome: String
        let message: String
        var worktreeWasRemoved: Bool? = nil
        var confirmsRemoval: Bool { worktreeWasRemoved ?? (outcome == WorktreeCleanupResult.Outcome.removed.rawValue) }
        var outcomeLabel: String { confirmsRemoval && outcome != "removed" ? "Removed · follow-up needed" : outcome.capitalized }
    }
    let id: UUID
    let completedAt: Date
    let automatic: Bool
    let entries: [Entry]
    let totalCount: Int
    let removedCount: Int
    var needsReviewCount: Int? = nil
    var removedEntries: [Entry] { entries.filter(\.confirmsRemoval) }
    var summary: String {
        "\(removedCount) removed · \(needsReviewCount ?? (totalCount - removedCount)) need review"
    }
}
