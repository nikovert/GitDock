import Foundation
import GitHubBarCore

/// Context transport is bounded without inventing code coordinates or omitting local fix drafts.
enum ReviewAgentContext {
    /// Full discussion is written separately from code, which the reviewer reads in the worktree.
    static func writeDiscussion(snapshot: PRReviewSnapshot, draft: WorkspaceReviewDraft, lease: ReviewWorktreeLease) throws {
        let comments = try fixes(snapshot: snapshot, draft: draft)
        var document = try JSONSerialization.jsonObject(with: Data(comments.utf8)) as? [String: Any] ?? [:]
        document["prURL"] = snapshot.key.url.absoluteString
        document["title"] = snapshot.title
        document["description"] = snapshot.body
        document["accountLogin"] = lease.accountLogin
        document["headSHA"] = lease.headSHA
        document["baseSHA"] = lease.baseSHA
        document["mergeBaseSHA"] = lease.mergeBaseSHA
        document["sourceNotices"] = snapshot.notices
        // These notices mix API patch/check/discussion limits; native file coverage comes from the manifest.
        document.removeValue(forKey: "discussionMayBeIncomplete")
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        guard data.count <= 1_048_576 else {
            throw ReviewWorktreeError.failed("The PR discussion is too large for a review context. No discussion was silently omitted.")
        }
        let directory = URL(fileURLWithPath: lease.contextDirectory).resolvingSymlinksInPath()
        let file = directory.appendingPathComponent("discussion.json")
        guard !FileManager.default.fileExists(atPath: file.path) else {
            throw ReviewWorktreeError.failed("The private review discussion file already exists. Prepare a fresh worktree.")
        }
        try data.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
    }

    static func review(snapshot: PRReviewSnapshot, draft: WorkspaceReviewDraft, maximumBytes: Int = 96_000) -> (text: String, incomplete: Bool) {
        let incompleteNotice = "\nCONTEXT IS INCOMPLETE: do not infer missing code, review coverage or locations.\n"
        let contentLimit = max(0, maximumBytes - incompleteNotice.utf8.count)
        var text = "PR \(snapshot.key.url.absoluteString)\nHead \(snapshot.headSHA)\nBase \(snapshot.baseSHA)\n"
        let headerWasTruncated = text.utf8.count > contentLimit
        text = prefix(text, bytes: contentLimit)
        var incomplete = headerWasTruncated || !snapshot.fileListComplete || !snapshot.notices.isEmpty || snapshot.files.contains { !$0.hasCompletePatch }
        func append(_ label: String, _ value: String, budget: Int) {
            let heading = "\n\(label)\n"
            let available = contentLimit - text.utf8.count - heading.utf8.count - 1
            guard available >= 0 else { incomplete = true; return }
            let part = prefix(value, bytes: min(budget, available))
            if part.utf8.count < value.utf8.count { incomplete = true }
            text += heading + part + "\n"
        }
        append("Title and description", snapshot.title + "\n" + snapshot.body, budget: 8_000)
        for file in snapshot.files {
            guard text.utf8.count < 60_000 else { incomplete = true; break }
            let lines = file.patch.map { patch in
                PRDiffParser.parse(patch).map { line in
                    "LEFT:\(line.oldLine.map(String.init) ?? "-") RIGHT:\(line.newLine.map(String.init) ?? "-") \(line.kind) \(line.text)"
                }.joined(separator: "\n")
            } ?? "Patch unavailable"
            append("File \(file.path) (complete patch: \(file.hasCompletePatch))", lines, budget: 24_000)
        }
        for comment in snapshot.comments {
            guard text.utf8.count < 82_000 else { incomplete = true; break }
            append("Published discussion · @\(comment.author) · \(comment.path ?? "general"):\(comment.line.map(String.init) ?? "unavailable")", comment.body, budget: 6_000)
        }
        for comment in draft.comments {
            guard text.utf8.count < 92_000 else { incomplete = true; break }
            append("Existing local draft \(comment.path):\(comment.line) \(comment.side)", comment.body, budget: 4_000)
        }
        for comment in draft.generalComments {
            guard text.utf8.count < 94_000 else { incomplete = true; break }
            append("Existing general draft", comment.body, budget: 2_000)
        }
        if incomplete { text += prefix(incompleteNotice, bytes: max(0, maximumBytes - text.utf8.count)) }
        return (text, incomplete)
    }

    static func fixes(snapshot: PRReviewSnapshot, draft: WorkspaceReviewDraft) throws -> String {
        let published: [[String: Any]] = snapshot.comments.map { comment in
            ["id": comment.id, "author": comment.author, "body": comment.body,
             "path": comment.path as Any? ?? NSNull(), "line": comment.line as Any? ?? NSNull(),
             "side": comment.side?.rawValue as Any? ?? NSNull(), "outdated": comment.isOutdated,
             "replyToID": comment.replyToID as Any? ?? NSNull(), "url": comment.url?.absoluteString as Any? ?? NSNull()]
        }
        let inline: [[String: Any]] = draft.comments.map {
            ["body": $0.body, "path": $0.path, "line": $0.line, "side": $0.side, "source": $0.agentName ?? "You"]
        }
        let general: [[String: Any]] = draft.generalComments.map {
            ["body": $0.body, "source": $0.agentName ?? "You", "originalLocation": $0.anchorDescription as Any? ?? NSNull()]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "publishedComments": published, "localInlineDrafts": inline, "localGeneralDrafts": general,
            "localReviewSummary": draft.body, "coverageNotices": snapshot.notices,
            "discussionMayBeIncomplete": !snapshot.notices.isEmpty,
        ], options: [.sortedKeys])
        guard data.count <= AgentFixRequest.maximumCommentBytes else {
            throw NSError(domain: "GitHubBar", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The combined comment context is too large for a fix session. Reduce the local drafts or use a terminal session; no comments have been silently dropped."])
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func prefix(_ value: String, bytes maximum: Int) -> String {
        if value.utf8.count <= maximum { return value }
        var bytes = Array(value.utf8.prefix(max(0, maximum)))
        while !bytes.isEmpty {
            if let value = String(bytes: bytes, encoding: .utf8) { return value }
            bytes.removeLast()
        }
        return ""
    }
}
