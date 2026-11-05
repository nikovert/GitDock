import SwiftUI

struct AutomaticCleanupActivityView: View {
    let model: WorktreeCleanupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Automatic worktree cleanup", systemImage: "folder.badge.minus")
                .workspaceFont(.subheadline.weight(.semibold))
            if let status = model.automaticStatus {
                Text(status).workspaceFont(.caption).foregroundStyle(.secondary)
            } else {
                Text(model.automaticEnabled ? "Automatic merged-worktree cleanup is enabled." : "Automatic worktree cleanup is off.")
                    .workspaceFont(.caption).foregroundStyle(.secondary)
            }
            if let latest = model.latestAutomaticActivity {
                Text("Last completed check: \(latest.completedAt.formatted(date: .abbreviated, time: .shortened))")
                    .workspaceFont(.caption).foregroundStyle(.secondary)
                if latest.removedCount == 0 {
                    Text("No confirmed removals recorded for that check.")
                        .workspaceFont(.caption.weight(.medium))
                }
            }
            if model.automaticRemovalActivity.isEmpty {
                Text("No automatic removals recorded yet.").workspaceFont(.caption).foregroundStyle(.secondary)
            } else {
                Text("Recently auto-removed").workspaceFont(.caption.bold())
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.automaticRemovalActivity) { run in
                            ForEach(run.removedEntries) { entry in
                                VStack(alignment: .leading, spacing: 3) {
                                    Label(URL(fileURLWithPath: entry.path).lastPathComponent, systemImage: "checkmark.circle.fill")
                                        .workspaceFont(.caption.bold()).foregroundStyle(.green)
                                    Text(entry.title).workspaceFont(.caption)
                                    Text(entry.path).workspaceFont(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text("Removed \(run.completedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .workspaceFont(.caption).foregroundStyle(.secondary)
                                    if entry.outcome != "removed" {
                                        Label("Follow-up needed: \(entry.message)", systemImage: "exclamationmark.triangle")
                                            .workspaceFont(.caption).foregroundStyle(.orange)
                                    }
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            }
                            if run.removedEntries.count < run.removedCount {
                                Text("\(run.removedCount - run.removedEntries.count) additional removals have no stored details in this run.")
                                    .workspaceFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 160)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
