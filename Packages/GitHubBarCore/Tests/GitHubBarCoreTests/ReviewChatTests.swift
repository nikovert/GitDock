import Darwin
import Foundation
import XCTest
@testable import GitHubBarCore

final class ReviewChatTests: XCTestCase, @unchecked Sendable {
    private let request = ReviewChatRequest(
        accountLogin: "reviewer", prURL: "https://github.com/example/repo/pull/7",
        headSHA: "abc123", question: "Explain this change", context: "diff context",
        policy: "Advisory only; do not edit files or publish comments.",
        messages: [ReviewChatMessage(role: .user, text: "Earlier question")]
    )

    func testConfigurationRejectsMissingRelativeAndInvalidPaths() throws {
        XCTAssertThrowsError(try ReviewChatConfiguration().validated())
        XCTAssertThrowsError(try ReviewChatConfiguration(executable: "agent").validated())
        XCTAssertThrowsError(try ReviewChatConfiguration(executable: "/does/not/exist").validated())
        let fixture = try fixture("exit 0;")
        defer { fixture.remove() }
        XCTAssertEqual(try fixture.configuration.validated(), fixture.configuration)
        var config = fixture.configuration
        config.workingDirectory = fixture.executable.path
        XCTAssertThrowsError(try config.validated())
        config.workingDirectory = "relative"
        XCTAssertThrowsError(try config.validated())
        config = fixture.configuration
        config.arguments = ["bad\0argument"]
        XCTAssertThrowsError(try config.validated())
    }

    func testRoundTripPassesLiteralArgumentsContextAndOnlySafeEnvironment() async throws {
        let fixture = try fixture("""
        my $request = decode_json(do { local $/; <STDIN> });
        print encode_json({prURL => $request->{prURL}, headSHA => $request->{headSHA},
          answer => encode_json({request => $request, arguments => \\@ARGV,
            directory => getcwd(), environment => \\%ENV}),
          citations => [{path => 'src/file.swift', line => 12}]});
        """)
        defer { fixture.remove() }
        var config = fixture.configuration
        config.arguments = ["a b", "$(touch should-not-exist)", ";", ""]
        let response = try await ReviewChatClient().send(request, configuration: config)
        XCTAssertEqual(response.prURL, request.prURL)
        XCTAssertEqual(response.headSHA, "abc123")
        XCTAssertEqual(response.citations, [ReviewChatCitation(path: "src/file.swift", line: 12)])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.answer.utf8)) as? [String: Any])
        XCTAssertEqual(payload["arguments"] as? [String], config.arguments)
        XCTAssertEqual(payload["directory"] as? String, fixture.directory.path)
        let sent = try XCTUnwrap(payload["request"] as? [String: Any])
        XCTAssertEqual(Set(sent.keys), ["accountLogin", "prURL", "headSHA", "question", "context", "policy", "messages"])
        XCTAssertEqual(sent["accountLogin"] as? String, "reviewer")
        XCTAssertEqual(sent["context"] as? String, "diff context")
        XCTAssertEqual(sent["policy"] as? String, request.policy)
        let decoded = try JSONDecoder().decode(ReviewChatRequest.self, from: JSONSerialization.data(withJSONObject: sent))
        XCTAssertEqual(decoded.messages, request.messages)
        let environment = try XCTUnwrap(payload["environment"] as? [String: String])
        XCTAssertTrue(Set(environment.keys).isSubset(of: ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"]))
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("should-not-exist").path))
    }

    func testMalformedMultipleAndInvalidCitationResponsesAreRejected() async throws {
        for output in ["not json", "{}", validJSON + validJSON,
                       validJSON.replacingOccurrences(of: "[]", with: "[{\"path\":\"file\",\"line\":0,\"side\":\"RIGHT\"}]"),
                       validJSON.replacingOccurrences(of: "[]", with: "[{\"path\":\"file\",\"line\":1,\"side\":\"OTHER\"}]"),
                       validJSON.replacingOccurrences(of: "[]", with: "[{\"path\":\"../secret\",\"line\":1}]")] {
            let fixture = try outputFixture(output)
            defer { fixture.remove() }
            await assertError(.invalidResponse, fixture: fixture)
        }
    }

    func testWrongPRAndHeadAreRejected() async throws {
        for output in [validJSON.replacingOccurrences(of: "/pull/7", with: "/pull/8"),
                       validJSON.replacingOccurrences(of: "abc123", with: "stale")] {
            let fixture = try outputFixture(output)
            defer { fixture.remove() }
            await assertError(.mismatchedResponse, fixture: fixture)
        }
    }

    func testNonzeroExitDoesNotExposeRawDiagnostics() async throws {
        let fixture = try fixture("print STDERR 'SECRET diagnostic'; exit 23;")
        defer { fixture.remove() }
        await assertError(.processFailed(23), fixture: fixture)
        XCTAssertFalse(ReviewChatError.processFailed(23).localizedDescription.contains("SECRET"))
    }

    func testKnownAdapterFailureShowsSafeRecoveryWithoutRawDiagnostics() async throws {
        let fixture = try fixture(#"""
        print STDERR "SECRET provider output\n";
        print STDERR 'GITHUBBAR_ADAPTER_ERROR_V1:{"code":"providerTimedOut"}';
        print STDERR "\n"; exit 1;
        """#)
        defer { fixture.remove() }
        do {
            _ = try await ReviewChatClient().send(request, configuration: fixture.configuration)
            XCTFail("Expected provider timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("provider timed out"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("SECRET"))
        }
    }

    func testProtocolAndProviderLimitFailuresHaveSpecificSafeRecovery() async throws {
        for (code, expected) in [("invalidRequest", "request did not match"),
                                 ("invalidExecutable", "provider executable"),
                                 ("providerDiagnosticsLimit", "diagnostics exceeded")] {
            let fixture = try fixture("print STDERR 'GITHUBBAR_ADAPTER_ERROR_V1:{\"code\":\"\(code)\"}'; exit 1;")
            defer { fixture.remove() }
            do {
                _ = try await ReviewChatClient().send(request, configuration: fixture.configuration)
                XCTFail("Expected \(code)")
            } catch { XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription) }
        }
    }

    func testUnknownAdapterFailureCannotInjectAnErrorMessage() async throws {
        let fixture = try fixture(#"""
        print STDERR 'GITHUBBAR_ADAPTER_ERROR_V1:{"code":"SECRET","message":"PRIVATE"}'; exit 1;
        """#)
        defer { fixture.remove() }
        await assertError(.processFailed(1), fixture: fixture)
    }

    func testExecutableThatCannotLaunchReportsRecoverableError() async throws {
        let fixture = try fixture("exit 0;")
        defer { fixture.remove() }
        try Data("not an executable format".utf8).write(to: fixture.executable)
        await assertError(.launchFailed, fixture: fixture)
    }

    func testStdoutAndStderrAreIndependentlyBounded() async throws {
        for (stream, error) in [("STDOUT", ReviewChatError.outputLimitExceeded),
                                ("STDERR", ReviewChatError.errorLimitExceeded)] {
            let fixture = try fixture("$| = 1; while (1) { print \(stream) 'x' x 8192; }")
            defer { fixture.remove() }
            await assertError(error, fixture: fixture,
                              client: ReviewChatClient(timeout: 2, maximumOutputBytes: 1024, maximumErrorBytes: 512))
        }
    }

    func testTimeoutKillsUncooperativeProcessEvenWhenInputPipeIsFull() async throws {
        let fixture = try fixture("$SIG{TERM} = 'IGNORE'; open(my $f, '>', 'pid'); print $f $$; close $f; sleep 30;")
        defer { fixture.remove() }
        let bigRequest = ReviewChatRequest(accountLogin: "reviewer", prURL: request.prURL,
            headSHA: "abc123", question: "q", context: String(repeating: "x", count: 500_000),
            policy: "advisory", messages: [])
        let start = Date()
        await assertError(.timedOut, fixture: fixture, client: ReviewChatClient(timeout: 0.3), request: bigRequest)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        try assertProcessExited(fixture)
    }

    func testCancellationKillsRunningProcessAndAllowsNextRequest() async throws {
        let fixture = try fixture("$SIG{TERM} = 'IGNORE'; open(my $f, '>', 'pid'); print $f $$; close $f; sleep 30;")
        defer { fixture.remove() }
        let client = ReviewChatClient(timeout: 5)
        let task = Task { try await client.send(request, configuration: fixture.configuration) }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("pid").path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation accepted a response") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected cancellation error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        try assertProcessExited(fixture)
        let success = try outputFixture(validJSON)
        defer { success.remove() }
        let response = try await client.send(request, configuration: success.configuration)
        XCTAssertEqual(response.answer, "Looks good")
    }

    func testBurstCancellationCompletesWithoutBlockingFoundationRunLoops() async throws {
        let count = 32
        let completed = expectation(description: "Every cancelled exchange returns")
        completed.expectedFulfillmentCount = count
        var fixtures: [Fixture] = []
        var jobs: [Task<ReviewChatResponse, Error>] = []
        defer { for fixture in fixtures { fixture.remove() } }
        for _ in 0..<count {
            let fixture = try fixture("$SIG{TERM} = 'IGNORE'; open(my $f, '>', 'pid'); print $f $$; close $f; sleep 30;")
            fixtures.append(fixture)
            let job = Task { try await ReviewChatClient(timeout: 10).send(request, configuration: fixture.configuration) }
            jobs.append(job)
            Task {
                defer { completed.fulfill() }
                do { _ = try await job.value; XCTFail("Expected cancellation") }
                catch is CancellationError {}
                catch { XCTFail("Unexpected error: \(error)") }
            }
        }
        for fixture in fixtures {
            let marker = fixture.directory.appendingPathComponent("pid")
            for _ in 0..<300 where !FileManager.default.fileExists(atPath: marker.path) {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        }
        for job in jobs { job.cancel() }
        // The expectation bounds the regression itself even if a job blocks a worker thread.
        await fulfillment(of: [completed], timeout: 5)
        for fixture in fixtures { try assertProcessExited(fixture) }
    }

    func testCancellationAlsoStopsAdapterChildProcess() async throws {
        let fixture = try fixture("""
        $SIG{TERM} = 'IGNORE';
        my $child = fork(); die unless defined $child;
        if ($child == 0) { close STDIN; close STDOUT; close STDERR; sleep 30; exit 0; }
        open(my $f, '>', 'child'); print $f $child; close $f;
        sleep 30;
        """)
        defer { fixture.remove() }
        let task = Task { try await ReviewChatClient(timeout: 5).send(request, configuration: fixture.configuration) }
        let childFile = fixture.directory.appendingPathComponent("child")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: childFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: childFile, encoding: .utf8)))
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected error: \(error)") }
        for _ in 0..<100 where kill(pid, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(kill(pid, 0), -1, "Backend child survived cancellation")
        XCTAssertEqual(errno, ESRCH)
    }

    func testClosedInputIsRecoverableWithoutSIGPIPE() async throws {
        let fixture = try fixture("close STDIN; select(undef, undef, undef, 0.1); exit 0;")
        defer { fixture.remove() }
        let bigRequest = ReviewChatRequest(accountLogin: "reviewer", prURL: request.prURL,
            headSHA: "abc123", question: "q", context: String(repeating: "x", count: 500_000),
            policy: "advisory", messages: [])
        await assertError(.inputClosed, fixture: fixture, request: bigRequest)
    }

    func testLargeDuplexExchangeDrainsBothOutputsBeforeInputCompletes() async throws {
        let fixture = try fixture("""
        $| = 1;
        print encode_json({prURL => 'https://github.com/example/repo/pull/7',
          headSHA => 'abc123', answer => ('x' x 100000), citations => []});
        print STDERR 'y' x 32000;
        local $/; <STDIN>;
        """)
        defer { fixture.remove() }
        let bigRequest = ReviewChatRequest(accountLogin: "reviewer", prURL: request.prURL,
            headSHA: "abc123", question: "q", context: String(repeating: "x", count: 500_000),
            policy: "advisory", messages: [])
        let response = try await ReviewChatClient(timeout: 3).send(bigRequest, configuration: fixture.configuration)
        XCTAssertEqual(response.answer.count, 100_000)
    }

    func testAlreadyCancelledRequestDoesNotLaunch() async throws {
        let fixture = try fixture("open(my $f, '>', 'started'); close $f;")
        defer { fixture.remove() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ReviewChatClient().send(request, configuration: fixture.configuration)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("started").path))
    }

    func testOversizedRequestDoesNotLaunch() async throws {
        let fixture = try fixture("open(my $f, '>', 'started'); close $f;")
        defer { fixture.remove() }
        await assertError(.requestLimitExceeded, fixture: fixture, client: ReviewChatClient(maximumRequestBytes: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("started").path))
    }

    private var validJSON: String {
        #"{"prURL":"https://github.com/example/repo/pull/7","headSHA":"abc123","answer":"Looks good","citations":[]}"#
    }

    private struct Fixture: Sendable {
        let directory: URL
        let executable: URL
        var configuration: ReviewChatConfiguration {
            ReviewChatConfiguration(displayName: "Fixture", executable: executable.path, workingDirectory: directory.path)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private func fixture(_ body: String) throws -> Fixture {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("review chat \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("adapter ; literal")
        let script = "#!/usr/bin/perl\nuse strict; use warnings; use JSON::PP; use Cwd;\n" + body + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return Fixture(directory: directory, executable: executable)
    }

    private func outputFixture(_ output: String) throws -> Fixture {
        let fixture = try fixture("local $/; <STDIN>; open(my $f, '<', 'response.json') or die; print <$f>;")
        try Data(output.utf8).write(to: fixture.directory.appendingPathComponent("response.json"))
        return fixture
    }

    private func assertError(_ expected: ReviewChatError, fixture: Fixture,
                             client: ReviewChatClient = ReviewChatClient(), request: ReviewChatRequest? = nil,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await client.send(request ?? self.request, configuration: fixture.configuration)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ReviewChatError, expected, file: file, line: line)
        }
    }

    private func assertProcessExited(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let pidText = try String(contentsOf: fixture.directory.appendingPathComponent("pid"), encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText))
        XCTAssertEqual(kill(pid, 0), -1, file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }
}
