import Darwin
import Foundation

public struct ReviewAgentProcessSnapshot: Equatable, Sendable {
    public enum State: Equatable, Sendable { case stopped, running, stopping, exited(Int32) }
    public let state: State
    public let events: [String]
}

/// Owns one foreground worker. Output is discarded; only lifecycle events are retained.
public actor ReviewAgentLauncher {
    private var process: Process?
    private var state: ReviewAgentProcessSnapshot.State = .stopped
    private var events: [String] = []
    private var stoppingTask: Task<Void, Never>?

    public init() {}

    deinit {
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    public func snapshot() -> ReviewAgentProcessSnapshot {
        refreshExit()
        return ReviewAgentProcessSnapshot(state: state, events: events)
    }

    public func start(connection: ReviewAgentConnection, workspaceCLI: URL, directoryURL: URL) throws {
        refreshExit()
        guard process == nil, state != .stopping else {
            throw AgentReviewError.invalid("Stop the current worker before starting another.")
        }
        _ = try connection.validated()
        guard connection.mode == .managed else {
            throw AgentReviewError.invalid("External workers are started and stopped outside GitDock.")
        }
        guard workspaceCLI.isFileURL, FileManager.default.isExecutableFile(atPath: workspaceCLI.path) else {
            throw AgentReviewError.invalid("The bundled workspace CLI is missing or not executable. Rebuild or reinstall GitDock.")
        }
        guard directoryURL.isFileURL, directoryURL.path.hasPrefix("/") else {
            throw AgentReviewError.invalid("The workspace data directory must be an absolute file path.")
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: connection.executable)
        child.arguments = connection.arguments
        child.currentDirectoryURL = URL(fileURLWithPath: connection.workingDirectory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GITHUBBAR_WORKSPACE_CLI"] = workspaceCLI.path
        environment["GITHUBBAR_WORKSPACE_DIR"] = directoryURL.path
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do { try child.run() }
        catch {
            record("Worker launch failed.")
            throw AgentReviewError.invalid("Could not start the worker. Check executable permissions and configuration.")
        }
        process = child
        state = .running
        record("Worker process started; protocol compatibility is not verified.")
    }

    public func stop() async {
        refreshExit()
        if let stoppingTask {
            await stoppingTask.value
            return
        }
        guard let child = process else { state = .stopped; return }
        state = .stopping
        let task = Task { await finishStopping(child) }
        stoppingTask = task
        await task.value
    }

    private func finishStopping(_ child: Process) async {
        defer { stoppingTask = nil }
        child.terminate()
        // Cancellation must not skip escalation during app shutdown.
        for _ in 0..<20 {
            if !child.isRunning { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        for _ in 0..<20 {
            if !child.isRunning { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !child.isRunning else {
            state = .running
            record("Worker did not stop; try Stop again.")
            return
        }
        process = nil
        state = .stopped
        record("Worker stopped. Queued requests are retained; active leases may expire.")
    }

    private func refreshExit() {
        guard state != .stopping, let child = process, !child.isRunning else { return }
        state = .exited(child.terminationStatus)
        record("Worker exited with status \(child.terminationStatus).")
        process = nil
    }

    private func record(_ event: String) {
        events.append(event)
        if events.count > 50 { events.removeFirst(events.count - 50) }
    }
}
