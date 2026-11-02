import SwiftUI

struct AgentMarkdownView: View {
    let text: String

    var body: some View {
        let blocks = AgentMarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let prose):
                    Text((try? AttributedString(markdown: prose, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(prose))
                        .font(.subheadline).textSelection(.enabled)
                case .code(let language, let code):
                    VStack(alignment: .leading, spacing: 5) {
                        if !language.isEmpty { Text(language).font(.caption2).foregroundStyle(.secondary) }
                        ScrollView(.horizontal) {
                            Text(code).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum AgentMarkdownBlock: Equatable {
    case prose(String)
    case code(language: String, text: String)

    static func parse(_ text: String) -> [Self] {
        var result: [Self] = []
        var lines: [String] = []
        var fence: String?
        var language = ""
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let current = fence {
                if trimmed.hasPrefix(current), trimmed.dropFirst(current.count).allSatisfy({ $0 == current.first }) {
                    result.append(.code(language: language, text: lines.joined(separator: "\n")))
                    lines = []; fence = nil
                } else { lines.append(line) }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if !lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.prose(lines.joined(separator: "\n")))
                }
                let marker = trimmed.first!
                let count = trimmed.prefix(while: { $0 == marker }).count
                fence = String(repeating: String(marker), count: count)
                language = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
                lines = []
            } else { lines.append(line) }
        }
        if fence != nil { result.append(.code(language: language, text: lines.joined(separator: "\n"))) }
        else if !lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.prose(lines.joined(separator: "\n")))
        }
        return result
    }
}
