import Foundation
import XCTest
@testable import GitDockCore

final class ReviewWorktreeTests: XCTestCase {
    func testPinnedManifestIncludesEveryFileAndMergeBaseBaselineWithoutExcerptLimits() async throws {
        let fixture = try await ReviewGitFixture.make()
        defer { fixture.remove() }
        let manager = ReviewWorktreeManager(store: fixture.store, commandRunner: fixture.router)
        let lease = try await manager.prepare(fixture.request)
        XCTAssertEqual(lease.headSHA, fixture.head)
        XCTAssertEqual(lease.baseSHA, fixture.base)
        XCTAssertEqual(lease.mergeBaseSHA, fixture.mergeBase)
        XCTAssertEqual(lease.changedPaths.count, 24)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: lease.manifestPath))) as! [String: Any]
        XCTAssertEqual(manifest["version"] as? Int, 1)
        let files = manifest["files"] as! [[String: Any]]
        XCTAssertEqual(files.count, 24)
        let large = try XCTUnwrap(files.first { $0["path"] as? String == "large.txt" })
        let patch = try String(contentsOfFile: large["patchFile"] as! String, encoding: .utf8)
        XCTAssertGreaterThan(patch.utf8.count, 96 * 1_024)
        XCTAssertTrue(patch.contains("LAST-LINE"))
        XCTAssertEqual(try String(contentsOfFile: large["baseFile"] as! String, encoding: .utf8), "BASE\n")
        XCTAssertEqual(files.first { $0["path"] as? String == "renamed.txt" }?["previousPath"] as? String, "old.txt")
        XCTAssertEqual(files.first { $0["path"] as? String == "deleted.txt" }?["status"] as? String, "D")
        XCTAssertEqual(files.first { $0["path"] as? String == "binary.dat" }?["isBinary"] as? Bool, true)
        XCTAssertEqual(files.first { $0["path"] as? String == "link" }?["isSymlink"] as? Bool, true)
        XCTAssertFalse(lease.changedPaths.contains("base-only.txt"), "Use merge-base…head, never base…head")
        for file in files {
            XCTAssertTrue((file["patchFile"] as! String).hasPrefix(lease.contextDirectory + "/"))
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: lease.contextDirectory)[.posixPermissions] as! NSNumber
        XCTAssertEqual(permissions.intValue & 0o777, 0o700)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: lease.contextDirectory).appendingPathComponent("discussion.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: lease.contextDirectory + "/discussion.json")
        try await manager.validate(lease)
        let warning = await manager.release(lease)
        XCTAssertNil(warning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.worktreePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.contextDirectory))
        let refs = try await fixture.git(["for-each-ref", "--format=%(refname)", "refs/githubbar/reviews/"])
        XCTAssertTrue(refs.isEmpty)
    }

    func testWrongOriginAndCapturedHeadOrBaseMismatchDoNotCreateReviewArtifacts() async throws {
        for mode in ["origin", "head", "base"] {
            let fixture = try await ReviewGitFixture.make()
            defer { fixture.remove() }
            if mode == "origin" { await fixture.router.setOrigin("https://github.com/other/widget.git") }
            let request = ReviewWorktreeRequest(key: fixture.request.key, accountLogin: "reviewer",
                headSHA: mode == "head" ? String(repeating: "a", count: 40) : fixture.head,
                baseSHA: mode == "base" ? String(repeating: "b", count: 40) : fixture.base)
            do {
                _ = try await ReviewWorktreeManager(store: fixture.store, commandRunner: fixture.router).prepare(request)
                XCTFail("Reject \(mode) mismatch")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
            let refs = try await fixture.git(["for-each-ref", "--format=%(refname)", "refs/githubbar/reviews/"])
        XCTAssertTrue(refs.isEmpty)
            let paths = (try? FileManager.default.contentsOfDirectory(atPath: fixture.root.path)) ?? []
            XCTAssertTrue(paths.isEmpty, "Failed preparation must clean its own artifacts: \(paths)")
        }
    }

    func testDirtyOrReplacedWorktreesAndModifiedContextAreRetained() async throws {
        for mode in ["dirty", "replaced", "context"] {
            let fixture = try await ReviewGitFixture.make()
            defer { fixture.remove() }
            let manager = ReviewWorktreeManager(store: fixture.store, commandRunner: fixture.router)
            let lease = try await manager.prepare(fixture.request)
            let tree = URL(fileURLWithPath: lease.worktreePath)
            if mode == "dirty" {
                try Data("keep me".utf8).write(to: tree.appendingPathComponent("ignored.env"))
            } else if mode == "replaced" {
                try FileManager.default.moveItem(at: tree, to: tree.appendingPathExtension("original"))
                try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
                try Data("unrelated".utf8).write(to: tree.appendingPathComponent("user.txt"))
            } else {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lease.manifestPath)
                try Data("tampered".utf8).write(to: URL(fileURLWithPath: lease.manifestPath))
            }
            do { try await manager.validate(lease); XCTFail("Reject changed \(mode)") } catch {}
            let warning = await manager.release(lease)
            XCTAssertNotNil(warning)
            XCTAssertTrue(warning?.contains(lease.worktreePath) == true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: lease.worktreePath))
        }
    }

    func testAssumeUnchangedCannotHideTrackedFileEditsFromValidationOrCleanup() async throws {
        let fixture = try await ReviewGitFixture.make()
        defer { fixture.remove() }
        let manager = ReviewWorktreeManager(store: fixture.store, commandRunner: fixture.router)
        let lease = try await manager.prepare(fixture.request)
        _ = try await ReviewGitFixture.git(["-C", lease.worktreePath, "update-index", "--assume-unchanged", "file-0.txt"])
        try Data("hidden edit\n".utf8).write(to: URL(fileURLWithPath: lease.worktreePath + "/file-0.txt"))
        do { try await manager.validate(lease); XCTFail("Index flags must not hide a changed tree") } catch {}
        let warning = await manager.release(lease)
        XCTAssertNotNil(warning)
        XCTAssertEqual(try String(contentsOfFile: lease.worktreePath + "/file-0.txt", encoding: .utf8), "hidden edit\n")
    }

    func testMaliciousConfiguredFilterNeverRunsAndWorktreeContainsRawBlobs() async throws {
        let fixture = try await ReviewGitFixture.make()
        defer { fixture.remove() }
        let marker = fixture.directory.appendingPathComponent("FILTER-RAN")
        for kind in ["process", "smudge", "clean"] {
            _ = try await fixture.git(["config", "filter.evil.\(kind)", "touch '\(marker.path)'; /bin/cat"])
        }
        _ = try await fixture.git(["config", "filter.evil.required", "true"])
        let manager = ReviewWorktreeManager(store: fixture.store, commandRunner: fixture.router)
        let lease = try await manager.prepare(fixture.request)
        XCTAssertEqual(try String(contentsOfFile: lease.worktreePath + "/filtered.txt", encoding: .utf8), "raw filtered contents\n")
        try await manager.validate(lease)
        let warning = await manager.release(lease)
        XCTAssertNil(warning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testUnsafeRootIsRejected() async throws {
        let fixture = try await ReviewGitFixture.make()
        defer { fixture.remove() }
        var document = try await fixture.store.load()
        document.configuration.worktreeRoot = fixture.checkout.path + "/unsafe"
        try await fixture.store.save(document)
        do {
            _ = try await ReviewWorktreeManager(store: fixture.store, commandRunner: fixture.router).prepare(fixture.request)
            XCTFail("Never create reviews inside the configured checkout")
        } catch {}
    }

    func testPreparedLeaseRoundTripsThroughBundledAdapterAndFakeCodexWithCompleteCoverage() async throws {
        let fixture = try await ReviewGitFixture.make()
        defer { fixture.remove() }
        let manager = ReviewWorktreeManager(store: fixture.store, commandRunner: fixture.router)
        let lease = try await manager.prepare(fixture.request)
        do {
            let discussion = URL(fileURLWithPath: lease.contextDirectory).appendingPathComponent("discussion.json")
            let discussionData = try JSONSerialization.data(withJSONObject: [
                "published": ["all published discussion"], "drafts": ["local unsent draft"],
            ])
            try discussionData.write(to: discussion, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: discussion.path)
            let cli = fixture.directory.appendingPathComponent("fake codex ; literal")
            let body = #"""
            #!/usr/bin/python3
            import json, os, stat, sys
            from pathlib import Path
            request = json.loads(sys.stdin.read().split('\nREQUEST_JSON:\n', 1)[1])
            repository = request['repository']
            assert Path.cwd().resolve() == Path(repository['worktreePath']).resolve()
            assert sys.argv[sys.argv.index('--sandbox') + 1] == 'read-only'
            assert 'web_search="disabled"' in sys.argv
            assert os.environ['GIT_NO_REPLACE_OBJECTS'] == '1'
            assert os.environ['GIT_GRAFT_FILE'] == '/dev/null'
            schema = json.loads(Path(sys.argv[sys.argv.index('--output-schema') + 1]).read_text())
            assert 'coverage' in schema['required']
            context = Path(repository['contextDirectory'])
            assert stat.S_IMODE(context.stat().st_mode) == 0o700
            manifest = json.loads(Path(repository['manifestPath']).read_text())
            assert manifest['version'] == 1 and len(manifest['files']) == 24
            assert manifest['headSHA'] == request['headSHA']
            discussion = json.loads((context / 'discussion.json').read_text())
            assert discussion['published'] == ['all published discussion']
            assert discussion['drafts'] == ['local unsent draft']
            assert Path('.gitignore').read_text() == '*.env\n'
            patches = {}
            baselines = {}
            for item in manifest['files']:
                patch = Path(item['patchFile'])
                assert patch.parent == context and stat.S_IMODE(patch.stat().st_mode) == 0o400
                patches[item['path']] = patch.read_bytes()
                if item.get('baseFile'):
                    baseline = Path(item['baseFile'])
                    assert baseline.parent == context and stat.S_IMODE(baseline.stat().st_mode) == 0o400
                    baselines[item['path']] = baseline.read_bytes()
                current = Path(item['path'])
                if item['status'] == 'D':
                    assert not current.exists()
                elif item['isSymlink']:
                    assert current.is_symlink() and os.readlink(current) == 'large.txt'
                else:
                    assert current.is_file()
                    contents = current.read_bytes()
                    if item['path'] == 'large.txt':
                        assert len(contents) > 96000 and contents.endswith(b'LAST-LINE\n')
                    if item['isBinary']:
                        assert contents == bytes([0, 1, 2, 255])
            assert len(patches['large.txt']) > 96000 and b'LAST-LINE' in patches['large.txt']
            assert baselines['large.txt'] == b'BASE\n'
            assert baselines['deleted.txt'] == b'deleted baseline\n'
            renamed = next(item for item in manifest['files'] if item['path'] == 'renamed.txt')
            assert renamed['previousPath'] == 'old.txt' and baselines['renamed.txt'] == b'rename preserved\n'
            payload = {'answer': 'Inspected all 24 manifest paths and surrounding context',
                       'citations': [], 'findings': [],
                       'coverage': {'reviewedPaths': [item['path'] for item in manifest['files']],
                                    'unreviewed': [], 'testsRun': [], 'limitations': []}}
            print(json.dumps({'type': 'item.completed', 'item': {'type': 'agent_message', 'text': json.dumps(payload)}}))
            print(json.dumps({'type': 'turn.completed'}))
            """#
            try Data(body.utf8).write(to: cli, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
            let adapter = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../../scripts/review-chat-adapter.py").standardizedFileURL
            XCTAssertTrue(FileManager.default.fileExists(atPath: adapter.path))
            let request = ReviewChatRequest(accountLogin: lease.accountLogin, prURL: lease.key.url.absoluteString,
                headSHA: lease.headSHA, question: "Review the entire PR", context: "Read private discussion.json",
                policy: "Read only; do not run repository code or tests", messages: [], task: .worktreeReview,
                repository: ReviewRepositoryContext(worktreePath: lease.worktreePath, contextDirectory: lease.contextDirectory,
                    manifestPath: lease.manifestPath, headSHA: lease.headSHA, baseSHA: lease.baseSHA, mergeBaseSHA: lease.mergeBaseSHA))
            let configuration = ReviewChatConfiguration(displayName: "Bundled adapter integration fixture",
                executable: "/usr/bin/python3", arguments: [adapter.path, "--provider", "codex", "--cli", cli.path, "--timeout", "10"],
                workingDirectory: lease.worktreePath, provider: .codex)
            let response = try await ReviewChatClient(worktreeTimeout: 15).send(request, configuration: configuration)
            XCTAssertEqual(response.prURL, lease.key.url.absoluteString)
            XCTAssertEqual(response.headSHA, lease.headSHA)
            XCTAssertEqual(response.answer, "Inspected all 24 manifest paths and surrounding context")
            XCTAssertEqual(response.findings, [])
            let coverage = try XCTUnwrap(response.coverage).normalized(expectedPaths: lease.changedPaths)
            XCTAssertEqual(Set(coverage.reviewedPaths), Set(lease.changedPaths))
            XCTAssertEqual(coverage.reviewedPaths.count, 24)
            XCTAssertTrue(coverage.unreviewed.isEmpty)
            XCTAssertTrue(coverage.testsRun.isEmpty)
            try await manager.validate(lease)
            let warning = await manager.release(lease)
            XCTAssertNil(warning)
            XCTAssertFalse(FileManager.default.fileExists(atPath: lease.worktreePath))
            XCTAssertFalse(FileManager.default.fileExists(atPath: lease.contextDirectory))
            let refs = try await fixture.git(["for-each-ref", "--format=%(refname)", "refs/githubbar/reviews/"])
            XCTAssertTrue(refs.isEmpty)
        } catch {
            _ = await manager.release(lease)
            throw error
        }
    }

    func testLocalReplacementRefsAndGraftsCannotChangeCapturedObjectsOrMergeBase() async throws {
        for mode in ["replace", "graft"] {
            let fixture = try await ReviewGitFixture.make()
            defer { fixture.remove() }
            if mode == "replace" {
                _ = try await fixture.git(["replace", fixture.head, fixture.base])
            } else {
                let info = fixture.checkout.appendingPathComponent(".git/info")
                try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
                try Data("\(fixture.head) \(fixture.base)\n".utf8).write(to: info.appendingPathComponent("grafts"))
            }
            let manager = ReviewWorktreeManager(store: fixture.store, commandRunner: fixture.router)
            let lease = try await manager.prepare(fixture.request)
            XCTAssertEqual(lease.headSHA, fixture.head, mode)
            XCTAssertEqual(lease.mergeBaseSHA, fixture.mergeBase, mode)
            XCTAssertEqual(lease.changedPaths.count, 24, mode)
            XCTAssertFalse(lease.changedPaths.contains("base-only.txt"), mode)
            XCTAssertTrue(try String(contentsOfFile: lease.worktreePath + "/large.txt", encoding: .utf8).contains("LAST-LINE"), mode)
            try await manager.validate(lease)
            let warning = await manager.release(lease)
            XCTAssertNil(warning, mode)
        }
    }

    func testShallowHistoryIsRejectedWithoutCreatingAReview() async throws {
        let fixture = try await ReviewGitFixture.make()
        defer { fixture.remove() }
        let shallow = fixture.directory.appendingPathComponent("shallow")
        _ = try await ReviewGitFixture.git(["clone", "-q", "--depth=1", fixture.directory.appendingPathComponent("source").absoluteString, shallow.path])
        var document = try await fixture.store.load()
        document.configuration.repositoryCheckouts["acme/widget"] = shallow.path
        try await fixture.store.save(document)
        do {
            _ = try await ReviewWorktreeManager(store: fixture.store, commandRunner: fixture.router).prepare(fixture.request)
            XCTFail("Incomplete history must not produce a whole-PR review")
        } catch { XCTAssertTrue(error.localizedDescription.contains("shallow")) }
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: fixture.root.path)) ?? []).isEmpty)
    }

    func testChangedSurroundingFileAndTamperedPrivateRefAreRejected() async throws {
        for mode in ["surrounding", "ref"] {
            let fixture = try await ReviewGitFixture.make()
            defer { fixture.remove() }
            let manager = ReviewWorktreeManager(store: fixture.store, commandRunner: fixture.router)
            let lease = try await manager.prepare(fixture.request)
            if mode == "surrounding" {
                let file = URL(fileURLWithPath: lease.worktreePath + "/.gitignore")
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                try Data("*.TXT\n".utf8).write(to: file)
                if let date = attributes[.modificationDate] { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path) }
            } else {
                let refs = try await fixture.git(["for-each-ref", "--format=%(refname)", "refs/githubbar/reviews/"])
                let ref = try XCTUnwrap(refs.split(separator: "\n").map(String.init).first { $0.hasSuffix("/head") })
                _ = try await fixture.git(["update-ref", ref, fixture.base])
            }
            do { try await manager.validate(lease); XCTFail("Reject changed \(mode)") } catch {}
            let warning = await manager.release(lease)
            XCTAssertNotNil(warning)
        }
    }

    func testCancellationAfterWorktreeMutationCleansOwnedArtifacts() async throws {
        let fixture = try await ReviewGitFixture.make()
        defer { fixture.remove() }
        await fixture.router.cancelAfterWorktreeAdd()
        let manager = ReviewWorktreeManager(store: fixture.store, commandRunner: fixture.router)
        let task = Task { try await manager.prepare(fixture.request) }
        await fixture.router.waitForWorktreeAdd()
        task.cancel()
        await fixture.router.resumeWorktreeAdd()
        do { _ = try await task.value; XCTFail("Cancellation must reject lease") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: fixture.root.path)) ?? []).isEmpty)
        let refs = try await fixture.git(["for-each-ref", "--format=%(refname)", "refs/githubbar/reviews/"])
        XCTAssertTrue(refs.isEmpty)
    }

    func testRunnerEnforcesRawObjectEnvironmentAgainstCallerOverrides() async throws {
        let result = await ReviewWorktreeCommandRunner().run(executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [], environment: ["GIT_NO_REPLACE_OBJECTS": "0", "GIT_GRAFT_FILE": "/tmp/untrusted-grafts"])
        XCTAssertEqual(result.exitCode, 0)
        let variables = Set(result.standardOutput.split(separator: "\n").map(String.init))
        XCTAssertTrue(variables.contains("GIT_NO_REPLACE_OBJECTS=1"))
        XCTAssertTrue(variables.contains("GIT_GRAFT_FILE=/dev/null"))
        XCTAssertFalse(variables.contains("GIT_GRAFT_FILE=/tmp/untrusted-grafts"))
    }

    func testBoundedRunnerKillsOwnedDescendantsBeforeReturningTimeoutOrCancellation() async throws {
        let runner = ReviewWorktreeCommandRunner(timeout: 0.15, maximumOutputBytes: 1_024)
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("review-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let start = Date()
        let descendant = "(sleep 0.5; /usr/bin/touch '\(marker.path)') & wait"
        let result = await runner.run(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", descendant], environment: [:])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let excess = await ReviewWorktreeCommandRunner(maximumOutputBytes: 1_024).run(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes x"], environment: [:])
        XCTAssertNotEqual(excess.exitCode, 0)
        let task = Task { await ReviewWorktreeCommandRunner().run(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & wait"], environment: [:]) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let cancelledResult = await task.value
        XCTAssertNotEqual(cancelledResult.exitCode, 0)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Timeout must kill the owned descendant before it can write")
        let success = await ReviewWorktreeCommandRunner().run(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "seq 1 10000; seq 1 10000 >&2"], environment: [:])
        XCTAssertEqual(success.exitCode, 0)
        XCTAssertTrue(success.standardOutput.hasSuffix("10000\n"))
        XCTAssertTrue(success.standardError.hasSuffix("10000\n"))
    }
}

private actor ReviewGitRouter: CommandRunning {
    let source: String
    var origin = "https://github.com/acme/widget.git"
    var pauseAdd = false
    var added = false
    var continuation: CheckedContinuation<Void, Never>?
    init(source: String) { self.source = source }
    func setOrigin(_ value: String) { origin = value }
    func cancelAfterWorktreeAdd() { pauseAdd = true }
    func waitForWorktreeAdd() async { while !added { try? await Task.sleep(for: .milliseconds(10)) } }
    func resumeWorktreeAdd() { continuation?.resume(); continuation = nil }
    func run(executableURL: URL, arguments: [String], environment: [String: String]) async -> CommandResult {
        if arguments.contains("get-url") { return .init(exitCode: 0, standardOutput: origin + "\n", standardError: "") }
        var routed = arguments
        if let fetch = routed.firstIndex(of: "fetch"), let remote = routed[(fetch + 1)...].firstIndex(of: "origin") { routed[remote] = source }
        let result = await ReviewWorktreeCommandRunner().run(executableURL: executableURL, arguments: routed, environment: environment)
        if pauseAdd, arguments.contains("worktree"), arguments.contains("add") {
            added = true
            await withCheckedContinuation { continuation = $0 }
        }
        return result
    }
}

private struct ReviewGitFixture: Sendable {
    let directory: URL
    let checkout: URL
    let root: URL
    let store: LocalWorkspaceStore
    let router: ReviewGitRouter
    let head: String
    let base: String
    let mergeBase: String
    let request: ReviewWorktreeRequest
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func git(_ arguments: [String]) async throws -> String { try await Self.git(["-C", checkout.path] + arguments) }
    static func git(_ arguments: [String]) async throws -> String {
        let result = await ProcessCommandRunner().run(executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments, environment: [:])
        guard result.exitCode == 0 else { throw NSError(domain: "ReviewGitFixture", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: result.standardError]) }
        return result.standardOutput.trimmingCharacters(in: .newlines)
    }
    static func make() async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("review-worktree-tests-\(UUID().uuidString)")
        let source = directory.appendingPathComponent("source")
        let checkout = directory.appendingPathComponent("checkout")
        let root = directory.appendingPathComponent("worktrees")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try await git(["init", "-q", source.path])
        func write(_ path: String, _ value: String) throws { try Data(value.utf8).write(to: source.appendingPathComponent(path)) }
        func commit() async throws {
            _ = try await git(["-C", source.path, "add", "-A"])
            _ = try await git(["-C", source.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "Fixture"])
        }
        try write("large.txt", "BASE\n")
        try write("old.txt", "rename preserved\n")
        try write("deleted.txt", "deleted baseline\n")
        try write(".gitignore", "*.env\n")
        try write(".gitattributes", "filtered.txt filter=evil\n")
        try await commit()
        let mergeBase = try await git(["-C", source.path, "rev-parse", "HEAD"])
        try write("base-only.txt", "base advanced\n")
        try await commit()
        let base = try await git(["-C", source.path, "rev-parse", "HEAD"])
        _ = try await git(["-C", source.path, "checkout", "-q", "--detach", mergeBase])
        try write("large.txt", (0..<8_000).map { "changed line \($0)\n" }.joined() + "LAST-LINE\n")
        try FileManager.default.moveItem(at: source.appendingPathComponent("old.txt"), to: source.appendingPathComponent("renamed.txt"))
        try FileManager.default.removeItem(at: source.appendingPathComponent("deleted.txt"))
        try Data([0, 1, 2, 255]).write(to: source.appendingPathComponent("binary.dat"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "large.txt")
        try write("filtered.txt", "raw filtered contents\n")
        for index in 0..<18 { try write("file-\(index).txt", "full file \(index)\n") }
        try await commit()
        let head = try await git(["-C", source.path, "rev-parse", "HEAD"])
        _ = try await git(["-C", source.path, "update-ref", "refs/pull/12/head", head])
        _ = try await git(["clone", "-q", source.path, checkout.path])
        let store = LocalWorkspaceStore(directoryURL: directory.appendingPathComponent("store"))
        var document = LocalWorkspaceDocument.empty
        document.configuration.repositoryCheckouts["acme/widget"] = checkout.path
        document.configuration.worktreeRoot = root.path
        try await store.save(document)
        return Self(directory: directory, checkout: checkout, root: root, store: store, router: ReviewGitRouter(source: source.path), head: head, base: base, mergeBase: mergeBase,
            request: ReviewWorktreeRequest(key: try PullRequestKey(url: URL(string: "https://github.com/acme/widget/pull/12")!), accountLogin: "reviewer", headSHA: head, baseSHA: base))
    }
}
