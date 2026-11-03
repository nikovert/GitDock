import GitHubBarCore
import SwiftUI

struct ReviewFileSidebar: View {
    @Bindable var review: ReviewWorkspaceModel
    @State private var filter = ""
    @State private var collapsed: Set<String> = []

    private var files: [PRSearchFile] { review.snapshot?.files ?? [] }
    private var tree: ReviewFileTree { ReviewFileTree(files: files, filter: filter) }
    private var isFiltering: Bool { !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let draftCounts = Dictionary(grouping: review.draft.comments, by: \.path).mapValues(\.count)
        let threadPaths = (review.snapshot?.threads ?? []).compactMap { $0.root?.path }
        let threadCounts = Dictionary(grouping: threadPaths, by: { $0 }).mapValues(\.count)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter files…", text: $filter).textFieldStyle(.plain)
                        .accessibilityLabel("Filter changed files")
                    if !filter.isEmpty {
                        Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear file filter")
                            .accessibilityLabel("Clear file filter")
                    }
                }.padding(6).background(.background, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                Menu {
                    Button("Expand all folders") { collapsed.removeAll() }
                    Button("Collapse all folders") {
                        collapsed = Set(ReviewFileTree(files: files).rows().filter { $0.file == nil }.map(\.path))
                    }.disabled(isFiltering)
                } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .menuStyle(.borderlessButton).fixedSize().help("Folder display options")
                    .accessibilityLabel("Folder display options")
            }.padding(10)

            ScrollViewReader { proxy in
                List(selection: Binding(get: { review.selectedFile?.path }, set: {
                    if let path = $0, files.contains(where: { $0.path == path }) { review.selectFile(path) }
                })) {
                    ForEach(tree.rows(collapsed: collapsed)) { row in
                        if let file = row.file {
                            fileRow(file, depth: row.depth, drafts: draftCounts[file.path] ?? 0, threads: threadCounts[file.path] ?? 0)
                                .tag(file.path).id(file.path)
                                .listRowSeparator(.hidden)
                                .listRowBackground(review.selectedFile?.path == file.path ? Color.accentColor.opacity(0.14) : Color.clear)
                        } else {
                            folderRow(row)
                                .listRowSeparator(.hidden)
                                .selectionDisabled()
                        }
                    }
                }.listStyle(.plain)
                    .overlay(alignment: .top) {
                        if tree.fileCount == 0 {
                            Text(files.isEmpty ? "No changed files" : "No matching files")
                                .font(.caption).foregroundStyle(.secondary).padding()
                        }
                    }
                    .onChange(of: review.selectedFile?.path) { _, path in reveal(path, proxy: proxy) }
                    .onChange(of: review.navigationRequest) { _, _ in reveal(review.selectedFile?.path, proxy: proxy) }
                    .onAppear { reveal(review.selectedFile?.path, proxy: proxy) }
            }
            Divider()
            Text(isFiltering ? "\(tree.fileCount) of \(files.count) files" : "\(files.count) changed files")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 7)
        }.background(Color(nsColor: .controlBackgroundColor))
    }

    private func folderRow(_ row: ReviewFileTree.Row) -> some View {
        let expanded = isFiltering || !collapsed.contains(row.path)
        return Button {
            if collapsed.contains(row.path) { collapsed.remove(row.path) } else { collapsed.insert(row.path) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 10)
                Image(systemName: "folder.fill").foregroundStyle(.blue)
                Text(row.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }.padding(.leading, CGFloat(row.depth) * 12).frame(minHeight: 23).contentShape(Rectangle())
        }.buttonStyle(.plain).font(.caption).help(row.path)
            .disabled(isFiltering)
            .accessibilityLabel("\(expanded ? "Collapse" : "Expand") folder \(row.path)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }

    private func fileRow(_ file: PRSearchFile, depth: Int, drafts: Int, threads: Int) -> some View {
        let viewed = review.draft.viewedFiles.contains(file.path)
        let name = file.path.split(separator: "/").last.map(String.init) ?? file.path
        let icon = Image(systemName: viewed ? "checkmark.circle.fill" : file.previousPath == nil ? "doc.text" : "doc.on.doc")
            .foregroundStyle(viewed ? Color.green : Color.secondary).frame(width: 14)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                icon
                Text(name).lineLimit(1).truncationMode(.middle).frame(minWidth: 70, alignment: .leading)
                Spacer(minLength: 2)
                if drafts > 0 { Label("\(drafts)", systemImage: "pencil").foregroundStyle(.orange).fixedSize() }
                if threads > 0 { Label("\(threads)", systemImage: "bubble.right").foregroundStyle(.secondary).fixedSize() }
            }
            HStack(spacing: 5) {
                icon
                Text(name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }.font(.caption).padding(.leading, CGFloat(depth) * 12 + 15).frame(minHeight: 23)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(file.path), \(drafts) local drafts, \(threads) discussion threads\(viewed ? ", viewed" : "")")
            .help(file.path + (file.previousPath.map { "\nRenamed from \($0)" } ?? "") + "\n+\(file.additions) −\(file.deletions)\n\(drafts) local drafts · \(threads) discussion threads")
    }

    private func reveal(_ path: String?, proxy: ScrollViewProxy) {
        guard let path else { return }
        collapsed = collapsed.filter { !path.hasPrefix($0 + "/") }
        // External thread/draft navigation must also reveal files hidden by a filter.
        if isFiltering && !tree.rows().contains(where: { $0.file?.path == path }) { filter = "" }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(path)
        }
    }
}
