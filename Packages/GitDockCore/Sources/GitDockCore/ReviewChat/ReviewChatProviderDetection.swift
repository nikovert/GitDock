import Foundation

public enum ReviewChatProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, custom
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .custom: return "Custom adapter"
        }
    }
}

/// Looks for executables without starting a shell or making a provider request.
public struct ReviewChatProviderDetection: Sendable {
    public let searchPaths: [String]

    public init(searchPaths: [String]? = nil) {
        self.searchPaths = searchPaths ?? (
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) +
                ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin", "/bin"]
        )
    }

    public func executable(named name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else { return nil }
        for directory in searchPaths where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public func executable(for provider: ReviewChatProvider) -> URL? {
        provider == .custom ? nil : executable(named: provider.rawValue)
    }

    public var preferredProvider: ReviewChatProvider? {
        [.codex, .claude].first { executable(for: $0) != nil }
    }

    public func selection(persisted: ReviewChatProvider?) -> ReviewChatProvider {
        persisted ?? preferredProvider ?? .custom
    }
}
