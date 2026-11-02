import Foundation
import GitHubBarCore

struct ReviewPublicationBatch {
    var summary = ""
    var includesSummary = false
    var comments: [WorkspaceInlineDraft] = []
    var generalComments: [WorkspaceGeneralDraft] = []
    var event: PRReviewEvent = .comment
    var body: String {
        ([summary] + generalComments.map(\.publicationBody))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n---\n\n")
    }
}

/// Each confirmed part can be retired independently; no part is ever retried automatically.
enum ReviewPublicationPlan {
    static func make(draft: WorkspaceReviewDraft, event: PRReviewEvent, selectedDraftIDs: Set<UUID>? = nil) throws -> [ReviewPublicationBatch] {
        let inline = selectedDraftIDs.map { ids in draft.comments.filter { ids.contains($0.id) } } ?? draft.comments
        let general = selectedDraftIDs.map { ids in draft.generalComments.filter { ids.contains($0.id) } } ?? draft.generalComments
        if let ids = selectedDraftIDs, ids.isEmpty || inline.count + general.count != ids.count { throw PRReviewError.invalidReview }
        let summary = selectedDraftIDs == nil ? draft.body : ""
        guard event != .requestChanges || !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PRReviewError.invalidReview }
        guard event.permits(body: ([summary] + general.map(\.publicationBody)).joined(separator: "\n"), commentCount: inline.count),
              inline.allSatisfy({ !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              general.allSatisfy({ !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw PRReviewError.invalidReview }
        guard summary.utf8.count <= 65_536, inline.allSatisfy({ $0.body.utf8.count <= 65_536 }),
              general.allSatisfy({ $0.publicationBody.utf8.count <= 65_536 }) else {
            throw NSError(domain: "GitHubBar", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "One summary or comment exceeds GitHub's 65,536-byte limit. Shorten that draft before publishing; all drafts remain local."])
        }
        var groups: [[WorkspaceGeneralDraft]] = []
        var current: [WorkspaceGeneralDraft] = []
        var currentBytes = 0
        for comment in general {
            let added = comment.publicationBody.utf8.count + (current.isEmpty ? 0 : 7)
            if currentBytes + added > 65_536 { groups.append(current); current = []; currentBytes = 0 }
            currentBytes += comment.publicationBody.utf8.count + (current.isEmpty ? 0 : 7)
            current.append(comment)
        }
        if !current.isEmpty { groups.append(current) }
        let count = max(1, groups.count, (inline.count + 99) / 100)
        var batches = (0..<count).map { index -> ReviewPublicationBatch in
            var batch = ReviewPublicationBatch()
            if index < groups.count { batch.generalComments = groups[index] }
            let start = min(inline.count, index * 100)
            let end = min(inline.count, start + 100)
            batch.comments = Array(inline[start..<end])
            return batch
        }
        // The selected decision and user summary belong to the final review.
        if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var last = batches.removeLast()
            last.summary = summary
            if last.body.utf8.count <= 65_536 { batches.append(last) }
            else {
                last.summary = ""; batches.append(last)
                var summaryBatch = ReviewPublicationBatch(); summaryBatch.summary = summary
                batches.append(summaryBatch)
            }
        }
        batches[batches.count - 1].event = event
        batches[batches.count - 1].includesSummary = selectedDraftIDs == nil
        guard batches.allSatisfy({ $0.event.permits(body: $0.body, commentCount: $0.comments.count) }) else { throw PRReviewError.invalidReview }
        return batches
    }
}
