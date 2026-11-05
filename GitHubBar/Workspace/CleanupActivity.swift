import Foundation
import GitHubBarCore

struct CleanupActivityRun: Codable, Equatable, Identifiable {
    struct Entry: Codable, Equatable, Identifiable {
        var id: String { path }
        let path: String
        let title: String
        let outcome: String
        let message: String
    }
    let id: UUID
    let completedAt: Date
    let automatic: Bool
    let entries: [Entry]
    let totalCount: Int
    let removedCount: Int
    var summary: String {
        "\(removedCount) removed · \(totalCount - removedCount) need review"
    }
}
