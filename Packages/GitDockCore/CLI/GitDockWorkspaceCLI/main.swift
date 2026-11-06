import Foundation
import GitDockCore

@main
struct GitDockWorkspaceCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else { throw WorkspaceBoardUpdateError.usage(usage) }
            let directory = ProcessInfo.processInfo.environment["GITHUBBAR_WORKSPACE_DIR"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            let store = LocalWorkspaceStore(directoryURL: directory)
            if command == "agent" {
                let output = try await AgentReviewStore(directoryURL: directory).execute(
                    FileHandle.standardInput.readDataToEndOfFile(), workspace: store)
                print(String(decoding: output, as: UTF8.self))
                return
            }
            let document: LocalWorkspaceDocument
            switch command {
            case "set":
                let update = try WorkspaceBoardUpdate.parse(arguments)
                document = try await store.update { try update.apply(to: &$0) }
            case "show":
                document = try await store.load()
            default:
                throw WorkspaceBoardUpdateError.usage(usage)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let output = try encoder.encode(document)
            print(String(decoding: output, as: UTF8.self))
        } catch {
            fputs("githubbar-workspace: \(error.localizedDescription)\n", stderr)
            Foundation.exit(2)
        }
    }

    private static let usage = """
    Usage: githubbar-workspace show
           githubbar-workspace agent < request.json
           githubbar-workspace set --pr URL|--stack URL [--priority none|low|medium|high]
             [--tags id,id] [--note TEXT] [--by codex|claude|local]
    """
}
