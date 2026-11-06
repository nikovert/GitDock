import Foundation

public struct PRDiffLine: Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case context, addition, deletion, hunk }
    public let id: Int
    public let oldLine: Int?
    public let newLine: Int?
    public let kind: Kind
    public let text: String

    public init(id: Int, oldLine: Int?, newLine: Int?, kind: Kind, text: String) {
        self.id = id; self.oldLine = oldLine; self.newLine = newLine
        self.kind = kind; self.text = text
    }
}

public enum PRDiffParser {
    public static func parse(_ patch: String) -> [PRDiffLine] {
        var result: [PRDiffLine] = []
        var old = 0, new = 0, oldRemaining = 0, newRemaining = 0
        var inHunk = false
        for (id, raw) in patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(raw)
            if raw.hasPrefix("@@") {
                inHunk = false
                result.append(.init(id: id, oldLine: nil, newLine: nil, kind: .hunk, text: text))
                let tokens = raw.split(separator: " ")
                guard tokens.count >= 4, tokens[0] == "@@", tokens[3] == "@@",
                      let left = range(tokens[1], prefix: "-"),
                      let right = range(tokens[2], prefix: "+") else { continue }
                old = left.start; oldRemaining = left.count
                new = right.start; newRemaining = right.count
                inHunk = true
                continue
            }
            guard inHunk, let prefix = raw.first else { continue }
            let kind: PRDiffLine.Kind
            let oldLine: Int?, newLine: Int?
            switch prefix {
            case " " where oldRemaining > 0 && newRemaining > 0:
                kind = .context; oldLine = old; newLine = new
                old += 1; new += 1; oldRemaining -= 1; newRemaining -= 1
            case "-" where oldRemaining > 0:
                kind = .deletion; oldLine = old; newLine = nil
                old += 1; oldRemaining -= 1
            case "+" where newRemaining > 0:
                kind = .addition; oldLine = nil; newLine = new
                new += 1; newRemaining -= 1
            case "\\": continue
            default: inHunk = false; continue
            }
            result.append(.init(id: id, oldLine: oldLine, newLine: newLine, kind: kind,
                                text: String(raw.dropFirst())))
        }
        return result
    }

    private static func range(_ token: Substring, prefix: Character) -> (start: Int, count: Int)? {
        guard token.first == prefix else { return nil }
        let parts = token.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let start = Int(parts[0]), start >= 0,
              let count = parts.count == 2 ? Int(parts[1]) : 1,
              count >= 0, start > 0 || count == 0, start <= Int.max - count else { return nil }
        return (start, count)
    }
}
