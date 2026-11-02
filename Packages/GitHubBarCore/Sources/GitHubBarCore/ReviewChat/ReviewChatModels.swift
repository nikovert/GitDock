import Foundation

public struct ReviewChatConfiguration: Codable, Equatable, Sendable {
    public var provider: ReviewChatProvider
    public var displayName: String
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String

    public init(displayName: String = "", executable: String = "", arguments: [String] = [],
                workingDirectory: String = "", provider: ReviewChatProvider = .custom) {
        self.provider = provider
        self.displayName = displayName
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    private enum CodingKeys: String, CodingKey { case provider, displayName, executable, arguments, workingDirectory }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try values.decode(String.self, forKey: .displayName)
        executable = try values.decode(String.self, forKey: .executable)
        arguments = try values.decode([String].self, forKey: .arguments)
        workingDirectory = try values.decode(String.self, forKey: .workingDirectory)
        if let saved = try values.decodeIfPresent(ReviewChatProvider.self, forKey: .provider) {
            provider = saved
        } else if let index = arguments.firstIndex(of: "--provider"), arguments.indices.contains(index + 1) {
            provider = ReviewChatProvider(rawValue: arguments[index + 1]) ?? .custom
        } else {
            provider = .custom
        }
    }

    @discardableResult
    public func validated() throws -> ReviewChatConfiguration {
        guard displayName.utf8.count <= 200, !displayName.contains("\0"),
              arguments.count <= 256,
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 65_536,
              arguments.allSatisfy({ !$0.contains("\0") }),
              !executable.contains("\0"), !workingDirectory.contains("\0") else {
            throw ReviewChatError.invalidConfiguration("Chat settings exceed their limits or contain a NUL character.")
        }
        var isDirectory: ObjCBool = false
        guard executable.hasPrefix("/"),
              FileManager.default.fileExists(atPath: executable, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: executable) else {
            throw ReviewChatError.invalidConfiguration("Choose an existing chat executable using its absolute path.")
        }
        guard workingDirectory.hasPrefix("/"),
              FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ReviewChatError.invalidConfiguration("Choose an existing chat working directory using its absolute path.")
        }
        return self
    }
}

public struct ReviewChatMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id: UUID
    public var role: Role
    public var text: String

    public init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

public struct ReviewChatCitation: Codable, Equatable, Sendable {
    public var path: String
    public var line: Int
    public var side: String

    public init(path: String, line: Int, side: String = "RIGHT") {
        self.path = path
        self.line = line
        self.side = side
    }

    private enum CodingKeys: String, CodingKey { case path, line, side }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decode(String.self, forKey: .path)
        line = try values.decode(Int.self, forKey: .line)
        side = try values.decodeIfPresent(String.self, forKey: .side) ?? "RIGHT"
    }

    var isValid: Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") &&
            !path.split(separator: "/").contains("..") && line > 0 &&
            (side == "LEFT" || side == "RIGHT")
    }
}

public enum ReviewChatTask: String, Codable, Sendable {
    case review
}

/// Advisory comments only. Coordinates must be resolved against the exact PR snapshot before attachment.
public struct ReviewAgentFinding: Codable, Equatable, Sendable {
    public var body: String
    public var path: String?
    public var line: Int?
    public var side: String?

    public init(body: String, path: String? = nil, line: Int? = nil, side: String? = nil) {
        self.body = body
        self.path = path
        self.line = line
        self.side = side
    }

    public var isValid: Bool {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !body.contains("\0"), body.utf8.count <= 16_384 else { return false }
        if let path {
            guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.contains("\0"),
                  !path.split(separator: "/").contains("..") else { return false }
        }
        if let line, line <= 0 { return false }
        if let side, side != "LEFT" && side != "RIGHT" { return false }
        return true
    }

    public static func areValid(_ findings: [ReviewAgentFinding]) -> Bool {
        findings.count <= 100 && findings.allSatisfy(\.isValid) &&
            findings.reduce(0, { $0 + $1.body.utf8.count }) <= 262_144
    }
}

public struct ReviewChatRequest: Codable, Sendable {
    public var accountLogin: String
    public var prURL: String
    public var headSHA: String
    public var question: String
    public var context: String
    public var policy: String
    public var messages: [ReviewChatMessage]
    public var task: ReviewChatTask?

    public init(accountLogin: String, prURL: String, headSHA: String, question: String,
                context: String, policy: String, messages: [ReviewChatMessage], task: ReviewChatTask? = nil) {
        self.accountLogin = accountLogin
        self.prURL = prURL
        self.headSHA = headSHA
        self.question = question
        self.context = context
        self.policy = policy
        self.messages = messages
        self.task = task
    }
}

public struct ReviewChatResponse: Codable, Equatable, Sendable {
    public var prURL: String
    public var headSHA: String
    public var answer: String
    public var citations: [ReviewChatCitation]
    public var findings: [ReviewAgentFinding]?

    public init(prURL: String, headSHA: String, answer: String, citations: [ReviewChatCitation],
                findings: [ReviewAgentFinding]? = nil) {
        self.prURL = prURL
        self.headSHA = headSHA
        self.answer = answer
        self.citations = citations
        self.findings = findings
    }
}

public protocol ReviewChatServicing: Sendable {
    func send(_ request: ReviewChatRequest,
              configuration: ReviewChatConfiguration) async throws -> ReviewChatResponse
}

/// Only these fixed recovery messages may cross the adapter's diagnostic boundary.
/// Provider output and arbitrary adapter message strings are never displayed.
public enum ReviewChatAdapterFailure: String, Codable, Equatable, Sendable {
    case providerTimedOut, providerNotAuthenticated, providerFailed, invalidReviewResponse, adapterFailed
    case invalidRequest, invalidExecutable, invalidTimeout, invalidProviderResponse, providerOutputLimit
    case providerDiagnosticsLimit, requestLimitExceeded, responseLimitExceeded, cancelled

    public var recoveryMessage: String {
        switch self {
        case .invalidRequest: return "The app's review request did not match the adapter protocol. Update GitHubBar and report the PR URL if this persists."
        case .invalidExecutable: return "The configured provider executable is missing or cannot be run. Choose an installed Codex or Claude CLI in agent settings."
        case .invalidTimeout: return "The adapter timeout setting is invalid. Choose a value above zero and at most 110 seconds."
        case .invalidProviderResponse: return "The provider returned an empty or invalid-text response. Check its CLI output mode and retry."
        case .providerOutputLimit: return "The provider's answer exceeded the response limit. Request a smaller review or shorter answer."
        case .providerDiagnosticsLimit: return "The provider diagnostics exceeded the limit. Check the CLI's local logging and settings warnings."
        case .requestLimitExceeded: return "The review request exceeded the adapter's input limit. Reduce the PR context and retry."
        case .responseLimitExceeded: return "The encoded review response exceeded the adapter's limit. Request fewer findings or a shorter answer."
        case .cancelled: return "The local agent request was cancelled. Existing drafts are unchanged."
        case .providerTimedOut: return "The provider timed out while preparing its response. Try a smaller PR or check the provider connection."
        case .providerNotAuthenticated: return "The provider CLI is not signed in. Run codex login or claude auth login in Terminal for the selected provider, then retry."
        case .providerFailed: return "The provider CLI failed. Check its local sign-in, service availability, and CLI version, then retry."
        case .invalidReviewResponse: return "The agent did not return valid structured review findings. No drafts were imported. Retry the review or check custom adapter review support."
        case .adapterFailed: return "The local adapter could not complete the request. Check its interpreter, CLI installation, and configuration."
        }
    }
}

public enum ReviewChatError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration(String)
    case launchFailed
    case inputClosed
    case ioFailed
    case timedOut
    case requestLimitExceeded
    case outputLimitExceeded
    case errorLimitExceeded
    case processFailed(Int32)
    case adapterFailed(ReviewChatAdapterFailure)
    case invalidResponse
    case mismatchedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason): return reason
        case .launchFailed: return "The chat adapter could not start. Check its executable and interpreter."
        case .inputClosed: return "The chat adapter closed its input before receiving the request. Check its protocol support."
        case .ioFailed: return "Communication with the chat adapter failed. Retry the question."
        case .timedOut: return "The chat adapter timed out and was stopped. Retry with less context or check the adapter."
        case .requestLimitExceeded: return "The chat request is too large. Reduce the context or conversation and retry."
        case .outputLimitExceeded: return "The chat adapter exceeded its response limit and was stopped. Request a shorter answer."
        case .errorLimitExceeded: return "The chat adapter exceeded its diagnostic limit and was stopped. Check its logging settings."
        case .adapterFailed(let failure): return failure.recoveryMessage
        case .processFailed(let status): return "The chat adapter exited with status \(status). Check its local configuration and retry."
        case .invalidResponse: return "The chat adapter returned an invalid response. Check its JSON protocol, citations, and structured findings support for agent reviews."
        case .mismatchedResponse: return "The chat response belongs to another PR or revision. Reload the PR and ask again."
        }
    }
}
