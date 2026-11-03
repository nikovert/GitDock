import Foundation
import GitHubBarCore

/// Paths stay case sensitive and retain their Git spelling, including renamed files.
struct ReviewFileTree {
    struct Row: Identifiable {
        let path: String
        let name: String
        let depth: Int
        let file: PRSearchFile?
        var id: String { (file == nil ? "directory:" : "file:") + path }
    }

    private struct Node {
        let path: String
        let name: String
        let file: PRSearchFile?
        let children: [Node]
    }

    private let roots: [Node]
    private let isFiltering: Bool
    let fileCount: Int

    init(files: [PRSearchFile], filter: String = "") {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        isFiltering = !query.isEmpty
        let matches = files.filter {
            query.isEmpty || $0.path.localizedCaseInsensitiveContains(query)
                || ($0.previousPath?.localizedCaseInsensitiveContains(query) ?? false)
        }
        fileCount = matches.count
        roots = Self.nodes(matches.map { ($0, $0.path.split(separator: "/").map(String.init)) }, depth: 0)
    }

    func rows(collapsed: Set<String> = []) -> [Row] {
        var result: [Row] = []
        func append(_ nodes: [Node], depth: Int) {
            for node in nodes {
                result.append(Row(path: node.path, name: node.name, depth: depth, file: node.file))
                if isFiltering || !collapsed.contains(node.path) { append(node.children, depth: depth + 1) }
            }
        }
        append(roots, depth: 0)
        return result
    }

    private static func nodes(_ entries: [(PRSearchFile, [String])], depth: Int) -> [Node] {
        let groups = Dictionary(grouping: entries, by: { $0.1[depth] })
        return groups.flatMap { name, entries -> [Node] in
            let path = entries[0].1.prefix(depth + 1).joined(separator: "/")
            // A PR can replace a file with a directory (or vice versa). Both
            // the removed file and the new descendants belong in the diff tree.
            var result = entries.filter { $0.1.count == depth + 1 }.map {
                Node(path: path, name: name, file: $0.0, children: [])
            }
            let descendants = entries.filter { $0.1.count > depth + 1 }
            guard !descendants.isEmpty else { return result }
            let children = nodes(descendants, depth: depth + 1)
            if children.count == 1, let child = children.first, child.file == nil {
                result.append(Node(path: child.path, name: name + "/" + child.name, file: nil, children: child.children))
            } else {
                result.append(Node(path: path, name: name, file: nil, children: children))
            }
            return result
        }.sorted {
            if ($0.file == nil) != ($1.file == nil) { return $0.file == nil }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }
}
