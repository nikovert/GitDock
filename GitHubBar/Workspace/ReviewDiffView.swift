import GitHubBarCore
import SwiftUI

struct ReviewDiffView: View {
    @Bindable var review: ReviewWorkspaceModel
    @Bindable var layout: WorkspaceLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Toggle("Since my last review", isOn: Binding(get: { review.sinceLastReview }, set: review.compareSinceLastReview))
                    .disabled(review.baseline == nil || review.loading)
                    .help(review.baseline == nil ? "Submit a review or mark this PR reviewed to save a baseline." : "Compare the last reviewed commit with the current head.")
                Spacer()
                Picker("Diff layout", selection: $review.splitDiff) {
                    Text("Unified").tag(false); Text("Split").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
            }.padding(12)
            if let notices = review.snapshot?.notices, !notices.isEmpty {
                Text(notices.joined(separator: " ")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            }
            if review.sinceLastReview {
                Text("Comparing commits. Switch to the full PR diff before drafting inline comments.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if layout.showsFileList {
                        ReviewFileSidebar(review: review).id(review.identity?.prKey)
                            .frame(width: layout.resolvedFileListWidth(availableWidth: geometry.size.width))
                        WorkspaceResizeDivider(width: Binding(get: { layout.resolvedFileListWidth(availableWidth: geometry.size.width) }, set: { layout.fileListWidth = $0 }),
                            minimum: 140, maximum: min(520, geometry.size.width - 300 - 10))
                            .frame(width: WorkspaceLayout.dividerWidth)
                    }
                    if let file = review.selectedFile {
                        fileContent(file).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("No changed files", systemImage: "doc.text.magnifyingglass",
                            description: Text("There may be no changes in this comparison. Check any coverage notice above."))
                    }
                }
            }
        }
    }

    private func fileContent(_ file: PRSearchFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.path).font(.caption.monospaced()).textSelection(.enabled)
                    if let previous = file.previousPath { Text("Renamed from \(previous)").font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                Toggle("Viewed", isOn: Binding(get: { review.draft.viewedFiles.contains(file.path) },
                    set: { review.markViewed(file.path, viewed: $0) })).controlSize(.small)
                    .disabled(review.sinceLastReview || review.submitting || !review.local.canSave)
            }.padding(10).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            if let patch = file.patch, !patch.isEmpty {
                GeometryReader { geometry in
                    let lines = PRDiffParser.parse(patch)
                    let textWidth = CGFloat(lines.filter { $0.kind != .hunk }.map { $0.text.count }.max() ?? 0) * 6.7
                    let columnWidth = max(geometry.size.width / 2, textWidth + 55, 280)
                    let contentWidth = review.splitDiff ? columnWidth * 2 + 1 : max(geometry.size.width, textWidth + 120)
                    ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if review.splitDiff {
                                ForEach(splitRows(lines)) { row in
                                    if let hunk = row.hunk { hunkRow(hunk) }
                                    else {
                                        VStack(alignment: .leading, spacing: 0) {
                                            HStack(spacing: 0) {
                                                splitCell(row.left, file: file, side: "LEFT", width: columnWidth)
                                                Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1)
                                                splitCell(row.right, file: file, side: "RIGHT", width: columnWidth)
                                            }.frame(height: 22)
                                            SplitDiffAnnotations(columnWidth: columnWidth) {
                                                lineConversations(file: file, oldLine: row.left?.oldLine, newLine: nil)
                                            } right: {
                                                lineConversations(file: file, oldLine: nil, newLine: row.right?.newLine)
                                            }
                                        }.id(row.id)
                                    }
                                }
                            } else {
                                ForEach(lines) { line in
                                    if line.kind == .hunk { hunkRow(line).id(line.id) }
                                    else {
                                        VStack(alignment: .leading, spacing: 0) {
                                            unifiedLine(line, file: file)
                                            lineConversations(file: file, oldLine: line.oldLine, newLine: line.newLine)
                                                .frame(width: min(geometry.size.width, contentWidth))
                                        }.id(line.id)
                                    }
                                }
                            }
                        }.frame(width: contentWidth, alignment: .leading)
                            .id("\(file.path)|\(review.splitDiff)")
                    }
                    .task(id: DiffScrollRequest(path: file.path, split: review.splitDiff, selection: review.selection, request: review.navigationRequest)) {
                        await Task.yield()
                        guard let selected = review.selection, selected.path == file.path,
                              let line = PRDiffParser.parse(patch).first(where: {
                                  selected.side == "LEFT" ? $0.oldLine == selected.line : $0.newLine == selected.line
                              }) else { return }
                        let target = review.splitDiff
                            ? splitRows(lines).first(where: { $0.left?.id == line.id || $0.right?.id == line.id })?.id ?? line.id
                            : line.id
                        proxy.scrollTo(target, anchor: .center)
                    }
                    }
                }
            } else {
                ContentUnavailableView("Patch unavailable", systemImage: "doc.questionmark",
                    description: Text("GitHub may omit binary or large patches. Open Files changed on GitHub to inspect this file."))
                if let key = review.snapshot?.key { Link("Open Files changed ↗", destination: key.url.appendingPathComponent("files")).padding() }
            }
        }
    }

    private func color(_ line: PRDiffLine) -> Color {
        switch line.kind {
        case .addition: .green.opacity(0.12)
        case .deletion: .red.opacity(0.12)
        case .hunk: .blue.opacity(0.08)
        default: .clear
        }
    }
    private func hunkRow(_ line: PRDiffLine) -> some View {
        Text(line.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
            .background(color(line))
    }
    private func unifiedLine(_ line: PRDiffLine, file: PRSearchFile) -> some View {
        let side = line.kind == .deletion ? "LEFT" : "RIGHT"
        return Button { select(line, file: file, side: side) } label: {
            HStack(spacing: 0) {
                Text(line.oldLine.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundStyle(.secondary)
                Text(line.newLine.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundStyle(.secondary)
                Text(line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " ").frame(width: 24)
                Text(line.text.isEmpty ? " " : line.text).fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11, design: .monospaced)).frame(height: 22).padding(.trailing, 12)
            .background(color(line)).contentShape(Rectangle())
            .overlay { if selected(line, side: side) { Rectangle().stroke(Color.accentColor, lineWidth: 1) } }
        }.buttonStyle(.plain)
    }
    @ViewBuilder private func splitCell(_ line: PRDiffLine?, file: PRSearchFile, side: String, width: CGFloat) -> some View {
        if let line {
            Button { select(line, file: file, side: side) } label: {
                HStack(spacing: 8) {
                    Text((side == "LEFT" ? line.oldLine : line.newLine).map(String.init) ?? "")
                        .frame(width: 35, alignment: .trailing).foregroundStyle(.secondary)
                    Text(line.text.isEmpty ? " " : line.text).fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 11, design: .monospaced)).padding(.trailing, 10)
                    .frame(width: width, height: 22).background(color(line)).contentShape(Rectangle())
                    .overlay { if selected(line, side: side) { Rectangle().stroke(Color.accentColor, lineWidth: 1) } }
            }.buttonStyle(.plain)
        } else { Color.secondary.opacity(0.05).frame(width: width, height: 22) }
    }
    @ViewBuilder private func lineConversations(file: PRSearchFile, oldLine: Int?, newLine: Int?) -> some View {
        if !review.sinceLastReview {
            let drafts = review.draft.comments.filter { $0.path == file.path &&
                (($0.side == "LEFT" && oldLine == $0.line) || ($0.side == "RIGHT" && newLine == $0.line)) }
            let threads = review.snapshot?.threads.filter { thread in
                guard let anchor = review.snapshot?.anchor(for: thread) else { return false }
                return anchor.path == file.path && (anchor.side == .left ? oldLine == anchor.line : newLine == anchor.line)
            } ?? []
            let selection = review.selection.flatMap { selected in
                selected.path == file.path && (selected.side == "LEFT" ? oldLine == selected.line : newLine == selected.line) ? selected : nil
            }
            if !drafts.isEmpty || !threads.isEmpty || selection != nil {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(drafts) { draft in ReviewInlineDraftCard(review: review, draftID: draft.id) }
                    ForEach(threads) { thread in ReviewConversationCard(review: review, thread: thread, showsNavigation: false) }
                    if let selection { selectionEditor(selection) }
                }.padding(10)
            }
        }
    }

    private func selectionEditor(_ selected: ReviewLineSelection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(selected.path):\(selected.line) · \(selected.side)").font(.caption.monospaced()).lineLimit(2)
                Spacer()
                Button { review.selection = nil } label: { Image(systemName: "xmark") }
            }
            Button("Ask agent about this line") {
                layout.showsInspector = true
                review.question = "Explain this change at \(selected.path):\(selected.line) and any risks."
            }.controlSize(.small)
            if review.snapshot?.canDraftInlineComment(in: selected.path) == true {
                MultilineComposer(text: $review.inlineBody, placeholder: "Draft an inline comment…",
                    isEnabled: canSaveInline, actionLabel: "Save draft") { review.addInlineDraft() }.frame(height: 85)
                HStack {
                    Button("Save draft") { review.addInlineDraft() }.disabled(!canSaveInline)
                    Text("Enter saves locally · Ctrl+Enter adds a newline").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("This diff is incomplete; comment on GitHub for this file.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
    private var canSaveInline: Bool { !review.inlineBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && review.local.canSave }

    private func selected(_ line: PRDiffLine, side: String) -> Bool {
        review.selection?.side == side && review.selection?.line == (side == "LEFT" ? line.oldLine : line.newLine)
    }
    private func select(_ line: PRDiffLine, file: PRSearchFile, side: String) {
        guard let number = side == "LEFT" ? line.oldLine : line.newLine else { return }
        review.selection = ReviewLineSelection(path: file.path, line: number, side: side, text: line.text)
    }
}

private struct SplitDiffRow: Identifiable {
    let id: Int
    var left: PRDiffLine?
    var right: PRDiffLine?
    var hunk: PRDiffLine?
}

private func splitRows(_ lines: [PRDiffLine]) -> [SplitDiffRow] {
    var result: [SplitDiffRow] = []
    var index = 0
    while index < lines.count {
        let line = lines[index]
        if line.kind == .hunk {
            result.append(SplitDiffRow(id: line.id, hunk: line)); index += 1
        } else if line.kind == .context {
            result.append(SplitDiffRow(id: line.id, left: line, right: line)); index += 1
        } else {
            var removed: [PRDiffLine] = [], added: [PRDiffLine] = []
            while index < lines.count && lines[index].kind != .hunk && lines[index].kind != .context {
                if lines[index].kind == .deletion { removed.append(lines[index]) }
                else if lines[index].kind == .addition { added.append(lines[index]) }
                index += 1
            }
            for offset in 0..<max(removed.count, added.count) {
                let left = offset < removed.count ? removed[offset] : nil
                let right = offset < added.count ? added[offset] : nil
                result.append(SplitDiffRow(id: left?.id ?? right!.id, left: left, right: right))
            }
        }
    }
    return result
}

private struct DiffScrollRequest: Hashable {
    let path: String
    let split: Bool
    let selection: ReviewLineSelection?
    let request: Int
}

struct SplitDiffAnnotations<Left: View, Right: View>: View {
    let columnWidth: CGFloat
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right
    var body: some View {
        HStack(alignment: .top, spacing: 1) {
            VStack(alignment: .leading, spacing: 0) { left }.frame(width: columnWidth, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 0) { right }.frame(width: columnWidth, alignment: .topLeading)
        }
    }
}
