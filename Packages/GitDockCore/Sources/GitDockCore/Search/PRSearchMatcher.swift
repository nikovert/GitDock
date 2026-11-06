import Foundation

struct PRSearchQuery: Sendable {
    let terms: [String]
    let phrase: String
    init(_ raw: String) {
        var terms: [String] = []
        var current = ""
        var quoted = false
        for character in raw.lowercased() {
            if character == "\"" {
                if !current.isEmpty { terms.append(current); current = "" }
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { terms.append(current); current = "" }
            } else { current.append(character) }
        }
        if !current.isEmpty { terms.append(current) }
        self.terms = Array(Set(terms)).sorted { terms.firstIndex(of: $0)! < terms.firstIndex(of: $1)! }
        phrase = terms.joined(separator: " ")
    }
}

enum PRSearchMatcher {
    static func match(_ document: PRSearchDocument, query: PRSearchQuery) -> PRSearchResult? {
        guard !query.terms.isEmpty else { return nil }
        typealias Candidate = (text: String, source: PRSearchSource, path: String?, kind: PRSearchLineKind?, weight: Int)
        var candidates: [Candidate] = [
            (document.pullRequest.title, .title, nil, nil, 400),
            (document.body, .description, nil, nil, 300)
        ]
        for file in document.files ?? [] {
            candidates.append((file.path, .file, file.path, nil, 200))
            if let previous = file.previousPath { candidates.append((previous, .file, previous, nil, 200)) }
            candidates.append(contentsOf: file.lines.map { ($0.0, .code, file.path, $0.1, 100) })
        }
        var covered = Set<String>()
        var best: Candidate?
        var bestScore = 0
        for candidate in candidates {
            let folded = candidate.text.lowercased()
            let matched = query.terms.filter { folded.contains($0) }
            guard !matched.isEmpty else { continue }
            covered.formUnion(matched)
            let score = candidate.weight + (folded.contains(query.phrase) ? 50 : 0)
            if score > bestScore { best = candidate; bestScore = score }
        }
        guard let best else { return nil }
        return PRSearchResult(pullRequest: document.pullRequest, source: best.source,
                              excerpt: excerpt(best.text, terms: query.terms), path: best.path,
                              lineKind: best.kind, coverage: document.coverage,
                              score: covered.count * 1_000 + bestScore)
    }

    static func precedes(_ lhs: PRSearchResult, _ rhs: PRSearchResult) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.pullRequest.updatedAt != rhs.pullRequest.updatedAt {
            return lhs.pullRequest.updatedAt > rhs.pullRequest.updatedAt
        }
        return lhs.id < rhs.id
    }

    private static func excerpt(_ text: String, terms: [String]) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        let range = terms.compactMap { flattened.range(of: $0, options: .caseInsensitive) }
            .min { $0.lowerBound < $1.lowerBound }
        let start = range.map { flattened.index($0.lowerBound, offsetBy: -70, limitedBy: flattened.startIndex) ?? flattened.startIndex }
            ?? flattened.startIndex
        return (start > flattened.startIndex ? "…" : "") + String(flattened[start...].prefix(240))
    }
}
