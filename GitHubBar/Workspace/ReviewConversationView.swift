import GitHubBarCore
import SwiftUI

/// Both Threads and Changes bind directly to the same persisted draft record.
struct ReviewInlineDraftCard: View {
    @Bindable var review: ReviewWorkspaceModel
    let draftID: UUID
    @State private var editing = false
    private var comment: WorkspaceInlineDraft? { review.draft.comments.first { $0.id == draftID } }

    private var anchorAvailable: Bool {
        guard let comment, let side = PRReviewDraftComment.Side(rawValue: comment.side) else { return false }
        return review.snapshot?.containsLine(path: comment.path, line: comment.line, side: side) == true
    }
    var body: some View {
        if let comment {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("Local draft", systemImage: "pencil").font(.caption.bold()).foregroundStyle(.orange)
                    Spacer()
                    Text("Not published").font(.caption).foregroundStyle(.secondary)
                }
                Text("\(comment.path):\(comment.line) · \(comment.side)").font(.caption.monospaced()).foregroundStyle(.secondary)
                if editing {
                    MultilineComposer(text: Binding(get: { self.comment?.body ?? "" }, set: { review.updateInlineDraft(draftID, body: $0) }),
                        placeholder: "Edit inline draft", isEnabled: !comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && review.local.canSave,
                        actionLabel: "Save draft") { editing = false }.frame(height: 95)
                    Button("Save draft") { editing = false }.disabled(comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    AgentMarkdownView(text: comment.body)
                }
                HStack {
                    Button("Show in diff") { review.showDraft(comment) }.disabled(!anchorAvailable)
                    Button(editing ? "Done" : "Edit") { editing.toggle() }.disabled(!review.local.canSave)
                    Button("Remove") { review.editDraft { $0.comments.removeAll { $0.id == draftID } } }.disabled(!review.local.canSave)
                    Spacer(minLength: 0)
                }.controlSize(.small)
                if !anchorAvailable { Text("This draft has no available current diff anchor. It remains saved here.").font(.caption).foregroundStyle(.secondary) }
                Button("Post to GitHub") {
                    if let identity = review.identity { review.submitDraft(draftID, target: identity) }
                }.controlSize(.small).disabled(!anchorAvailable || review.submitting || !review.local.canSave || review.sinceLastReview || comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.25)) }
        }
    }
}

struct ReviewConversationCard: View {
    @Bindable var review: ReviewWorkspaceModel
    let thread: PRReviewThread
    var showsNavigation = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let root = thread.root, let path = root.path {
                Text(path + (root.line ?? root.originalLine).map { ":\($0)" }.orEmpty + (root.side.map { " · \($0.rawValue)" } ?? ""))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let snapshot = review.snapshot, thread.isInline {
                if let reason = snapshot.anchorUnavailableReason(for: thread) {
                    Label(reason, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                } else if showsNavigation, let anchor = snapshot.anchor(for: thread) {
                    Button("Show in diff") { review.follow(ReviewChatCitation(path: anchor.path, line: anchor.line, side: anchor.side.rawValue)) }
                        .font(.caption)
                }
            }
            ForEach(thread.comments) { comment in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("@\(comment.author)").font(.subheadline.bold())
                        if let date = comment.createdAt { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if let url = comment.url { Link("GitHub ↗", destination: url).font(.caption) }
                    }
                    AgentMarkdownView(text: comment.body.isEmpty ? "Review submitted without a summary." : comment.body)
                }
                if comment.id != thread.comments.last?.id { Divider() }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)) }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
