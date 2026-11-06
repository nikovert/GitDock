import Foundation

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol CommandRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) async -> CommandResult
}

public actor ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:]
    ) async -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        var childEnvironment = ProcessInfo.processInfo.environment.merging(environment) {
            _, supplied in supplied
        }
        let path = childEnvironment["PATH"] ?? ""
        let existingDirectories = Set(path.split(separator: ":").map(String.init))
        let fallbackDirectories = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].filter { !existingDirectories.contains($0) }
        childEnvironment["PATH"] = ([path] + fallbackDirectories)
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        process.environment = childEnvironment

        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: -1, standardOutput: "", standardError: "Command could not be started")
        }

        async let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let error = String(decoding: await errorData, as: UTF8.self)
        return CommandResult(exitCode: process.terminationStatus, standardOutput: output, standardError: error)
    }
}
