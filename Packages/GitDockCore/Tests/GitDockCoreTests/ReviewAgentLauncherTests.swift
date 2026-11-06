import Foundation
import XCTest
@testable import GitDockCore

final class ReviewAgentLauncherTests: XCTestCase, @unchecked Sendable {
    func testLaunchPassesLiteralArgumentsDirectoryAndBridgeEnvironment() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("worker ; literal")
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/usr/bin/perl"))
        let result = directory.appendingPathComponent("result")
        let script = """
        use Cwd; open(my $out, '>', shift @ARGV) or die;
        print $out join("\\n", @ARGV, getcwd(), $ENV{GITHUBBAR_WORKSPACE_CLI}, $ENV{GITHUBBAR_WORKSPACE_DIR});
        close $out; print "PRIVATE OUTPUT"; warn "PRIVATE ERROR";
        """
        let connection = ReviewAgentConnection(displayName: "Local", mode: .managed,
            executable: executable.path, arguments: ["-e", script, result.path, "a b", "$(touch nope)", ";", ""],
            workingDirectory: directory.path)
        let launcher = ReviewAgentLauncher()
        try await launcher.start(connection: connection, workspaceCLI: URL(fileURLWithPath: "/usr/bin/true"), directoryURL: directory)
        let snapshot = await waitForExit(launcher)
        XCTAssertEqual(snapshot.state, .exited(0))
        let output = try String(contentsOf: result, encoding: .utf8)
        XCTAssertEqual(output, "a b\n$(touch nope)\n;\n\n\(directory.path)\n/usr/bin/true\n\(directory.path)")
        XCTAssertFalse(snapshot.events.joined().contains("PRIVATE"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("nope").path))
    }

    func testStopEscalatesForUncooperativeWorkerAndAllowsRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        let connection = ReviewAgentConnection(mode: .managed, executable: "/usr/bin/perl",
            arguments: ["-e", "$SIG{TERM}='IGNORE'; open(my $f, '>', $ARGV[0]); close $f; sleep 30;", ready.path],
            workingDirectory: directory.path)
        let launcher = ReviewAgentLauncher()
        try await launcher.start(connection: connection, workspaceCLI: URL(fileURLWithPath: "/usr/bin/true"), directoryURL: directory)
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        do {
            try await launcher.start(connection: connection, workspaceCLI: URL(fileURLWithPath: "/usr/bin/true"), directoryURL: directory)
            XCTFail("Launched a second worker")
        } catch {}
        let before = Date()
        await launcher.stop()
        let stopped = await launcher.snapshot()
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertLessThan(Date().timeIntervalSince(before), 4)
        try await launcher.start(connection: ReviewAgentConnection(mode: .managed, executable: "/usr/bin/true", workingDirectory: directory.path),
            workspaceCLI: URL(fileURLWithPath: "/usr/bin/true"), directoryURL: directory)
        let restarted = await waitForExit(launcher)
        XCTAssertEqual(restarted.state, .exited(0))
        await launcher.stop()
        await launcher.stop()
    }

    func testExternalModeAndMissingBridgeDoNotLaunch() async throws {
        let launcher = ReviewAgentLauncher()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for connection in [ReviewAgentConnection(), ReviewAgentConnection(mode: .managed,
            executable: "/usr/bin/true", workingDirectory: directory.path)] {
            do {
                try await launcher.start(connection: connection, workspaceCLI: directory.appendingPathComponent("missing"), directoryURL: directory)
                XCTFail("Invalid launch accepted")
            } catch {}
        }
        let snapshot = await launcher.snapshot()
        XCTAssertEqual(snapshot.state, .stopped)
    }

    func testLocatorUsesCurrentBundleAndRejectsMissingCLI() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(WorkspaceCLIExecutableLocator.locate(bundleURL: directory))
        let cli = directory.appendingPathComponent("Contents/MacOS/GitDockWorkspaceCLI")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cli, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        XCTAssertEqual(WorkspaceCLIExecutableLocator.locate(bundleURL: directory), cli)
    }

    func testRepeatedFailuresRetainOnlyBoundedLifecycleEvents() async throws {
        let launcher = ReviewAgentLauncher()
        for _ in 0..<30 {
            try await launcher.start(connection: ReviewAgentConnection(mode: .managed,
                executable: "/usr/bin/false", workingDirectory: "/private/tmp"),
                workspaceCLI: URL(fileURLWithPath: "/usr/bin/true"), directoryURL: URL(fileURLWithPath: "/private/tmp"))
            let snapshot = await waitForExit(launcher)
            XCTAssertEqual(snapshot.state, .exited(1))
        }
        let snapshot = await launcher.snapshot()
        XCTAssertEqual(snapshot.events.count, 50)
    }

    func testConcurrentStopWaitsForTheInFlightShutdown() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        let launcher = ReviewAgentLauncher()
        try await launcher.start(connection: ReviewAgentConnection(mode: .managed, executable: "/usr/bin/perl",
            arguments: ["-e", "$SIG{TERM}='IGNORE'; open(my $f, '>', $ARGV[0]); close $f; sleep 30;", ready.path],
            workingDirectory: directory.path), workspaceCLI: URL(fileURLWithPath: "/usr/bin/true"), directoryURL: directory)
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let first = Task { await launcher.stop() }
        for _ in 0..<200 {
            if await launcher.snapshot().state == .stopping { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await launcher.stop()
        let snapshot = await launcher.snapshot()
        XCTAssertEqual(snapshot.state, .stopped)
        await first.value
    }

    private func temporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("review agent \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitForExit(_ launcher: ReviewAgentLauncher) async -> ReviewAgentProcessSnapshot {
        for _ in 0..<200 {
            let snapshot = await launcher.snapshot()
            if case .exited = snapshot.state { return snapshot }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await launcher.stop()
        XCTFail("Worker did not exit")
        return await launcher.snapshot()
    }
}
