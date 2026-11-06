import Foundation

public struct ReviewAgentConnection: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case external, managed }

    public var displayName: String
    public var mode: Mode
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String

    public init(displayName: String = "Review agent", mode: Mode = .external,
                executable: String = "", arguments: [String] = [], workingDirectory: String = "") {
        self.displayName = displayName
        self.mode = mode
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name", mode, executable, arguments
        case workingDirectory = "working_directory"
    }

    public static func parseArguments(_ text: String) throws -> [String] {
        let values: [String]
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
            guard let parsed = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) else {
                throw AgentReviewError.invalid("Arguments must be a JSON array of strings or one argument per line.")
            }
            values = parsed
        } else {
            values = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }
        guard values.count <= 256, values.reduce(0, { $0 + $1.utf8.count }) <= 65_536,
              values.allSatisfy({ !$0.contains("\0") }) else {
            throw AgentReviewError.invalid("Arguments exceed the size limit or contain a NUL character.")
        }
        return values
    }

    @discardableResult
    public func validated() throws -> ReviewAgentConnection {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              displayName.utf8.count <= 200, !displayName.contains("\0") else {
            throw AgentReviewError.invalid("Enter a display name of at most 200 bytes.")
        }
        _ = try Self.parseArguments(String(decoding: JSONEncoder().encode(arguments), as: UTF8.self))
        guard !executable.contains("\0"), !workingDirectory.contains("\0") else {
            throw AgentReviewError.invalid("Paths cannot contain NUL characters.")
        }
        if mode == .managed {
            var isDirectory: ObjCBool = false
            guard executable.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: executable, isDirectory: &isDirectory),
                  !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: executable) else {
                throw AgentReviewError.invalid("Choose an existing executable using its absolute path.")
            }
            guard workingDirectory.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw AgentReviewError.invalid("Choose an existing working directory using its absolute path.")
            }
        }
        return self
    }

    public static func validatedPriorityAuthors(_ authors: [String]) throws -> [String] {
        guard authors.count <= 256, authors.allSatisfy({ login in
            !login.isEmpty && login.utf8.count <= 39 && login.utf8.allSatisfy {
                $0 == 45 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            }
        }) else { throw AgentReviewError.invalid("Priority authors must be GitHub logins, one per line (up to 256).") }
        return Array(Set(authors.map { $0.lowercased() })).sorted()
    }
}

public enum WorkspaceCLIExecutableLocator {
    public static func locate(bundleURL: URL) -> URL? {
        let url = bundleURL.appendingPathComponent("Contents/MacOS/GitDockWorkspaceCLI")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }
}
