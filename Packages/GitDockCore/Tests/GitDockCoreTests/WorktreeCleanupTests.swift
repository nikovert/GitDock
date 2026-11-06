import Foundation
import XCTest
@testable import GitDockCore

final class WorktreeCleanupTests: XCTestCase {
    func testUnlinkedExternalRegistrationIsDiscoveredAndManuallyRemovedWithoutDeletingBranch() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        let external = f.root.appendingPathComponent("external-topic").path
        _ = try await f.git(["worktree", "add", "-qb", "external-topic", external])
        _ = try await f.git(["push", "-q", f.runner.remote, "external-topic:refs/heads/external-topic"])
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        let row = try XCTUnwrap(preview.first { $0.path == WorktreeCleanupLocal.canonical(external) })
        XCTAssertTrue(row.isEligible, row.skipReason ?? "")
        let results = await f.coordinator.execute([row], accountLogin: "tester")
        XCTAssertEqual(results.map(\.outcome), [.removed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: external))
        let retained = try await f.git(["rev-parse", "refs/heads/external-topic"])
        XCTAssertEqual(retained, f.sha)
        let document = try await f.store.load()
        XCTAssertEqual(document.sessions.count, 1)
    }

    func testAutomaticCleanupRemovesCleanMergedManagedWorktreeWithoutStoppingAnything() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        XCTAssertTrue(try XCTUnwrap(preview.first).isAutomaticallyEligible)
        let result = await f.coordinator.execute(preview, accountLogin: "tester", intent: .automatic)
        XCTAssertEqual(result.map(\.outcome), [.removed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
        let kills = await f.runner.kills
        XCTAssertTrue(kills.isEmpty)
        let branch = try await f.git(["rev-parse", "refs/heads/topic"])
        XCTAssertEqual(branch, f.sha)
    }

    func testAutomaticCleanupNeverStopsLiveSessions() async throws {
        let f = try await CleanupFixture.make(running: true)
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        let row = try XCTUnwrap(preview.first)
        XCTAssertTrue(row.isEligible, "Manual approval is still available")
        XCTAssertFalse(row.isAutomaticallyEligible)
        let result = await f.coordinator.execute(preview, accountLogin: "tester", intent: .automatic)
        XCTAssertEqual(result.map(\.outcome), [.skipped])
        let kills = await f.runner.kills
        XCTAssertTrue(kills.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    func testAutomaticCleanupRetainsSessionAppearingAtEveryLateCheckWithoutKillingIt() async throws {
        for call in 2...5 {
            let f = try await CleanupFixture.make()
            defer { f.dispose() }
            let preview = try await f.coordinator.preview(accountLogin: "tester")
            await f.runner.appearBeforeStop(name: f.runner.name, atListCall: call)
            let result = await f.coordinator.execute(preview, accountLogin: "tester", intent: .automatic)
            XCTAssertNotEqual(result.map(\.outcome), [.removed], "list call \(call)")
            let kills = await f.runner.kills
            XCTAssertTrue(kills.isEmpty, "list call \(call)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.path), "list call \(call)")
        }
    }

    func testUnlinkedExternalRegistrationCannotBeAutomaticallyRemoved() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        let external = f.root.appendingPathComponent("external-topic").path
        _ = try await f.git(["worktree", "add", "-qb", "external-topic", external])
        _ = try await f.git(["push", "-q", f.runner.remote, "external-topic:refs/heads/external-topic"])
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        let row = try XCTUnwrap(preview.first { $0.path == WorktreeCleanupLocal.canonical(external) })
        XCTAssertEqual(row.provenance, .external)
        XCTAssertTrue(row.isEligible)
        XCTAssertFalse(row.isAutomaticallyEligible)
        let result = await f.coordinator.execute([row], accountLogin: "tester", intent: .automatic)
        XCTAssertEqual(result.map(\.outcome), [.skipped])
        XCTAssertTrue(FileManager.default.fileExists(atPath: external))
    }

    func testExternalRegistrationRetainsUnpushedDirtyLockedAndRemoteChangedWork() async throws {
        for change in ["unpushed", "dirty", "ignored", "locked", "remoteChanged", "unrelatedSession"] {
            let f = try await CleanupFixture.make()
            defer { f.dispose() }
            let external = f.root.appendingPathComponent("external-topic").path
            _ = try await f.git(["worktree", "add", "-qb", "external-topic", external])
            _ = try await f.git(["push", "-q", f.runner.remote, "external-topic:refs/heads/external-topic"])
            let preview = try await f.coordinator.preview(accountLogin: "tester")
            let row = try XCTUnwrap(preview.first { $0.path == WorktreeCleanupLocal.canonical(external) })
            switch change {
            case "unpushed": _ = try await f.git(["commit", "--allow-empty", "-qm", "Local work"], path: external)
            case "dirty": try Data("local".utf8).write(to: URL(fileURLWithPath: external + "/file"))
            case "ignored": try Data("secret".utf8).write(to: URL(fileURLWithPath: external + "/secret.env"))
            case "locked": _ = try await f.git(["worktree", "lock", external])
            case "remoteChanged":
                _ = try await f.git(["commit", "--allow-empty", "-qm", "Remote advanced"])
                _ = try await f.git(["push", "-q", f.runner.remote, "HEAD:refs/heads/external-topic"])
            default: await f.runner.addUnknownSession(path: external)
            }
            let result = await f.coordinator.execute([row], accountLogin: "tester", intent: .manual)
            XCTAssertEqual(result.map(\.outcome), [.skipped], change)
            XCTAssertTrue(FileManager.default.fileExists(atPath: external), change)
            let kills = await f.runner.kills
            XCTAssertTrue(kills.isEmpty, change)
        }
    }

    func testClosedDraftManagedWorktreeRequiresManualIntent() async throws {
        let f = try await CleanupFixture.make(metadata: CleanupMetadata(merged: false, closed: true, isDraft: true))
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        let row = try XCTUnwrap(preview.first)
        XCTAssertTrue(row.isEligible, row.skipReason ?? "")
        XCTAssertFalse(row.isAutomaticallyEligible)
        let automatic = await f.coordinator.execute(preview, accountLogin: "tester", intent: .automatic)
        XCTAssertEqual(automatic.map(\.outcome), [.skipped])
        let manual = await f.coordinator.execute(preview, accountLogin: "tester", intent: .manual)
        XCTAssertEqual(manual.map(\.outcome), [.removed])
    }

    func testClosedNonDraftAndOpenDraftRemainIneligible() async throws {
        for metadata in [CleanupMetadata(merged: false, closed: true), CleanupMetadata(merged: false, isDraft: true)] {
            let f = try await CleanupFixture.make(metadata: metadata)
            defer { f.dispose() }
            let preview = try await f.coordinator.preview(accountLogin: "tester")
            XCTAssertFalse(try XCTUnwrap(preview.first).isEligible)
        }
    }

    func testConfigurationHeadAndCleanlinessAreRecheckedAfterAwaitedSessionQueryBeforeStop() async throws {
        for change in ["config", "head", "dirty"] {
            let f = try await CleanupFixture.make(running: true)
            defer { f.dispose() }
            let preview = try await f.coordinator.preview(accountLogin: "tester")
            await f.runner.onList(call: 3) {
                switch change {
                case "config": try await f.store.update { $0.configuration.codexCommand = "Changed during session check" }
                case "head": _ = try await f.git(["commit", "--allow-empty", "-qm", "Late local work"], path: f.path)
                default: try Data("late local changes".utf8).write(to: URL(fileURLWithPath: f.path + "/file"))
                }
            }
            let results = await f.coordinator.execute(preview, accountLogin: "tester", intent: .manual)
            XCTAssertNotEqual(results.map(\.outcome), [.removed], change)
            let kills = await f.runner.kills
            XCTAssertTrue(kills.isEmpty, change)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.path), change)
        }
    }

    func testChangesDuringLastPreStopSessionQueryRetainSessionAndWorktree() async throws {
        // With a running fixture, query 4 is the last live-session check before kill-session.
        for change in ["dirty", "head", "account"] {
            let f = try await CleanupFixture.make(running: true)
            defer { f.dispose() }
            let preview = try await f.coordinator.preview(accountLogin: "tester")
            await f.runner.onList(call: 4) {
                switch change {
                case "head": _ = try await f.git(["commit", "--allow-empty", "-qm", "Work during final session query"], path: f.path)
                case "account": await f.github.invalidateAccount()
                default: try Data("local work during final query".utf8).write(to: URL(fileURLWithPath: f.path + "/file"))
                }
            }
            let result = await f.coordinator.execute(preview, accountLogin: "tester", intent: .manual)
            XCTAssertNotEqual(result.map(\.outcome), [.removed], change)
            let kills = await f.runner.kills
            XCTAssertTrue(kills.isEmpty, change)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.path), change)
        }
    }

    func testChangesDuringLastPreRemovalSessionQueryRetainWorktreeWithoutKills() async throws {
        // With no running sessions, query 5 is the last live-session check before Git removal.
        for change in ["dirty", "head", "account"] {
            let f = try await CleanupFixture.make()
            defer { f.dispose() }
            let preview = try await f.coordinator.preview(accountLogin: "tester")
            await f.runner.onList(call: 5) {
                switch change {
                case "head": _ = try await f.git(["commit", "--allow-empty", "-qm", "Extra commit during final query"], path: f.path)
                case "account": await f.github.invalidateAccount()
                default: try Data("local changes during final query".utf8).write(to: URL(fileURLWithPath: f.path + "/file"))
                }
            }
            let result = await f.coordinator.execute(preview, accountLogin: "tester", intent: .automatic)
            XCTAssertNotEqual(result.map(\.outcome), [.removed], change)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.path), change)
            let kills = await f.runner.kills
            XCTAssertTrue(kills.isEmpty, change)
        }
    }

    func testCancellationDuringFinalAwaitedSessionQueryRetainsWorktree() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        await f.runner.onList(call: 5) { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { await f.coordinator.execute(preview, accountLogin: "tester", intent: .automatic) }
        let result = await task.value
        XCTAssertNotEqual(result.map(\.outcome), [.removed])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    func testExternalWorktreeRequiresFreshAccountVerification() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        let external = f.root.appendingPathComponent("external-topic").path
        _ = try await f.git(["worktree", "add", "-qb", "external-topic", external])
        _ = try await f.git(["push", "-q", f.runner.remote, "external-topic:refs/heads/external-topic"])
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        let row = try XCTUnwrap(preview.first { $0.path == WorktreeCleanupLocal.canonical(external) })
        await f.github.invalidateAccount()
        let result = await f.coordinator.execute([row], accountLogin: "tester", intent: .manual)
        XCTAssertEqual(result.map(\.outcome), [.skipped])
        XCTAssertTrue(result.first?.message.contains("account") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external))
    }

    func testAccountChangeDuringAwaitedSessionCheckNeverStopsSession() async throws {
        let f = try await CleanupFixture.make(running: true)
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        await f.runner.onList(call: 3) { await f.github.invalidateAccount() }
        _ = await f.coordinator.execute(preview, accountLogin: "tester", intent: .manual)
        let kills = await f.runner.kills
        XCTAssertTrue(kills.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    func testFailedRepositoryDiscoveryRemainsVisibleAsIneligibleReason() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        try await f.store.update { $0.configuration.repositoryCheckouts["acme/unavailable"] = f.root.appendingPathComponent("missing").path }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        let error = try XCTUnwrap(preview.first { $0.repositoryNameWithOwner == "acme/unavailable" })
        XCTAssertFalse(error.isEligible)
        XCTAssertTrue(error.skipReason?.contains("enumerate registered worktrees") == true)
    }

    func testExternalSymlinkRegistrationCannotBecomeCleanupTarget() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        let external = f.root.appendingPathComponent("external-topic").path
        let alias = f.root.appendingPathComponent("alias-topic").path
        _ = try await f.git(["worktree", "add", "-qb", "external-topic", external])
        _ = try await f.git(["push", "-q", f.runner.remote, "external-topic:refs/heads/external-topic"])
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: external)
        try Data((alias + "/.git\n").utf8).write(to: URL(fileURLWithPath: f.checkout + "/.git/worktrees/external-topic/gitdir"))
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        let row = try XCTUnwrap(preview.first { WorktreeCleanupLocal.canonical($0.path) == WorktreeCleanupLocal.canonical(external) })
        XCTAssertFalse(row.isEligible)
        let result = await f.coordinator.execute([row], accountLogin: "tester", intent: .manual)
        XCTAssertEqual(result.map(\.outcome), [.skipped])
        XCTAssertTrue(FileManager.default.fileExists(atPath: external))
    }

    func testExternalLinkedOpenPRCanBeManuallyRemovedWhenExactRemoteBranchTipIsVerified() async throws {
        let f = try await CleanupFixture.make(metadata: CleanupMetadata(merged: false))
        defer { f.dispose() }
        _ = try await f.git(["push", "-q", f.runner.remote, "topic:refs/heads/topic"])
        try await f.store.update { doc in
            let session = doc.sessions[0]
            doc.sessions[0] = AgentSessionLink(id: session.id, subject: session.subject, agent: session.agent,
                worktreePath: session.worktreePath, tmuxSessionName: session.tmuxSessionName,
                managedWorktree: false, state: .stopped)
            doc.configuration.worktreeRoot = f.root.appendingPathComponent("another-managed-root").path
        }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        let row = try XCTUnwrap(preview.first)
        XCTAssertEqual(row.provenance, .external)
        XCTAssertTrue(row.isEligible, row.skipReason ?? "")
        XCTAssertFalse(row.isAutomaticallyEligible)
        let result = await f.coordinator.execute([row], accountLogin: "tester", intent: .manual)
        XCTAssertEqual(result.map(\.outcome), [.removed])
        let branch = try await f.git(["rev-parse", "refs/heads/topic"])
        XCTAssertEqual(branch, f.sha)
        let kills = await f.runner.kills
        XCTAssertTrue(kills.isEmpty)
    }

    func testOwnershipChangeWhileGitRemovesTreePreservesReassignedSessionLink() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        await f.runner.afterRemoval {
            try await f.store.update { doc in
                let session = doc.sessions[0]
                doc.sessions[0] = AgentSessionLink(id: session.id, subject: session.subject, agent: session.agent,
                    worktreePath: f.checkout, tmuxSessionName: session.tmuxSessionName,
                    managedWorktree: false, state: .stopped)
            }
        }
        let result = await f.coordinator.execute(preview, accountLogin: "tester", intent: .manual)
        XCTAssertEqual(result.map(\.outcome), [.failed])
        XCTAssertTrue(result.first?.message.contains("Worktree removed") == true)
        XCTAssertEqual(result.first?.worktreeWasRemoved, true, "A later link failure must not hide confirmed filesystem removal")
        let document = try await f.store.load()
        XCTAssertEqual(document.sessions.count, 1)
        XCTAssertEqual(document.sessions.first?.worktreePath, f.checkout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
    }

    func testLegacyCleanupServiceForwardsManualIntentAndFailsClosedForAutomaticIntent() async throws {
        let service = LegacyCleanupService()
        let candidate = WorktreeCleanupCandidate(path: "/controlled/fixture", sessions: [], title: "Fixture", headSHA: "",
            skipReason: nil, liveSessions: [:], accountLogin: "tester", configuration: WorkspaceConfiguration())
        let automatic = await service.execute([candidate], accountLogin: "tester", intent: .automatic)
        XCTAssertEqual(automatic.map(\.outcome), [.skipped])
        let beforeManual = await service.executions
        XCTAssertEqual(beforeManual, 0)
        let manual = await service.execute([candidate], accountLogin: "tester", intent: .manual)
        XCTAssertEqual(manual.map(\.outcome), [.removed])
        let afterManual = await service.executions
        XCTAssertEqual(afterManual, 1)
    }

    func testCleanFilterCannotHideLocalOnlyBytesFromAutomaticOrManualCleanup() async throws {
        for intent in [WorktreeCleanupIntent.automatic, .manual] {
            let f = try await CleanupFixture.make(running: intent == .manual)
            defer { f.dispose() }
            let preview = try await f.coordinator.preview(accountLogin: "tester")
            XCTAssertTrue(try XCTUnwrap(preview.first).isEligible)
            _ = try await f.git(["config", "filter.lower.clean", "/usr/bin/tr A-Z a-z"])
            try Data("file filter=lower\n".utf8).write(to: URL(fileURLWithPath: f.checkout + "/.git/info/attributes"))
            let localOnly = Data("ORIGINAL".utf8)
            try localOnly.write(to: URL(fileURLWithPath: f.path + "/file"))
            let deceptiveStatus = try await f.git(["status", "--porcelain", "--ignored", "--untracked-files=all"], path: f.path)
            XCTAssertTrue(deceptiveStatus.isEmpty, "Fixture must reproduce a clean filter hiding changed bytes")
            let unchangedHead = try await f.git(["rev-parse", "HEAD"], path: f.path)
            XCTAssertEqual(unchangedHead, f.sha)
            let result = await f.coordinator.execute(preview, accountLogin: "tester", intent: intent)
            XCTAssertNotEqual(result.map(\.outcome), [.removed])
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
            XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: f.path + "/file")), localOnly)
            let kills = await f.runner.kills
            XCTAssertTrue(kills.isEmpty)
        }
    }

    func testGitIgnoringExecutableModeCannotHideLocalModeChange() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        _ = try await f.git(["config", "core.fileMode", "false"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path + "/file")
        let deceptiveStatus = try await f.git(["status", "--porcelain"], path: f.path)
        XCTAssertTrue(deceptiveStatus.isEmpty)
        let result = await f.coordinator.execute(preview, accountLogin: "tester", intent: .automatic)
        XCTAssertNotEqual(result.map(\.outcome), [.removed])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    func testCachedGitStatMetadataCannotHideChangedBytes() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        _ = try await f.git(["config", "core.trustctime", "false"])
        _ = try await f.git(["config", "core.checkStat", "minimal"])
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: f.path + "/file")
        _ = try await f.git(["status", "--porcelain"], path: f.path)
        let localOnly = Data("ORIGINAL".utf8)
        try localOnly.write(to: URL(fileURLWithPath: f.path + "/file"))
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: f.path + "/file")
        let deceptiveStatus = try await f.git(["status", "--porcelain"], path: f.path)
        XCTAssertTrue(deceptiveStatus.isEmpty, "Fixture must exercise Git's cached stat metadata")
        let result = await f.coordinator.execute(preview, accountLogin: "tester", intent: .automatic)
        XCTAssertNotEqual(result.map(\.outcome), [.removed])
        XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: f.path + "/file")), localOnly)
    }

    func testOriginalHeadObjectsAreVerifiedDespiteReplacementRefs() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        try Data("ORIGINAL".utf8).write(to: URL(fileURLWithPath: f.checkout + "/file"))
        _ = try await f.git(["add", "file"])
        _ = try await f.git(["commit", "-qm", "Local replacement tree"])
        let replacement = try await f.git(["rev-parse", "HEAD"])
        _ = try await f.git(["replace", f.sha, replacement])
        try Data("ORIGINAL".utf8).write(to: URL(fileURLWithPath: f.path + "/file"))
        _ = try await f.git(["reset", "--mixed", "HEAD"], path: f.path)
        let deceptiveStatus = try await f.git(["status", "--porcelain"], path: f.path)
        XCTAssertTrue(deceptiveStatus.isEmpty)
        let result = await f.coordinator.execute(preview, accountLogin: "tester", intent: .automatic)
        XCTAssertNotEqual(result.map(\.outcome), [.removed])
        XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: f.path + "/file")), Data("ORIGINAL".utf8))
    }

    func testCleanOriginalSymlinkAndExecutableAreAttestedAndRemoved() async throws {
        let f = try await CleanupFixture.make(withSymlink: true, executable: true)
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        XCTAssertTrue(try XCTUnwrap(preview.first).isEligible, preview.first?.skipReason ?? "")
        let result = await f.coordinator.execute(preview, accountLogin: "tester", intent: .automatic)
        XCTAssertEqual(result.map(\.outcome), [.removed])
        let branch = try await f.git(["rev-parse", "refs/heads/topic"])
        XCTAssertEqual(branch, f.sha)
    }

    func testSymlinkReplacedWithRegularFileIsRetainedEvenIfGitIgnoresSymlinkType() async throws {
        let f = try await CleanupFixture.make(withSymlink: true)
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        _ = try await f.git(["config", "core.symlinks", "false"])
        try FileManager.default.removeItem(atPath: f.path + "/link")
        try Data("file".utf8).write(to: URL(fileURLWithPath: f.path + "/link"))
        let deceptiveStatus = try await f.git(["status", "--porcelain"], path: f.path)
        XCTAssertTrue(deceptiveStatus.isEmpty)
        let result = await f.coordinator.execute(preview, accountLogin: "tester", intent: .automatic)
        XCTAssertNotEqual(result.map(\.outcome), [.removed])
        XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: f.path + "/link")), Data("file".utf8))
    }

    func testRawContentAttestationRejectsOversizedSparseFileWithoutReadingIt() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        let tree = try await f.git(["ls-tree", "-r", "-z", "--full-tree", "HEAD"], path: f.path)
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: f.path + "/file"))
        try file.truncate(atOffset: 512 * 1_024 * 1_024 + 1)
        try file.close()
        XCTAssertThrowsError(try WorktreeCleanupContent.verify(path: f.path, rawTree: tree)) {
            XCTAssertTrue($0.localizedDescription.contains("512 MiB"))
        }
    }

    func testSkippedWorktreeStillShowsPRAndStackDescriptions() async throws {
        let f = try await CleanupFixture.make(stack: true)
        defer { f.dispose() }
        try Data("changed".utf8).write(to: URL(fileURLWithPath: f.path + "/file"))
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        let row = try XCTUnwrap(preview.first)
        XCTAssertFalse(row.isEligible)
        XCTAssertEqual(row.title, "A useful change")
        XCTAssertEqual(row.pullRequests.map(\.key.number), [12, 13])
        XCTAssertEqual(row.pullRequests.map(\.title), ["A useful change", "Follow-up change"])
        XCTAssertEqual(row.pullRequests.map(\.description), ["Handle missing inputs. Keep the fallback active.", "Update the caller."])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
        let kills = await f.runner.kills
        XCTAssertTrue(kills.isEmpty)
    }

    func testDescriptionExcerptHandlesEmptyMultilineAndLongUnicodeText() throws {
        let key = try PullRequestKey(url: URL(string: "https://github.com/acme/widget/pull/12")!)
        let empty = WorktreeCleanupPRSummary(key: key, title: "Empty", body: " \n\t")
        XCTAssertEqual(empty.description, "")
        let long = WorktreeCleanupPRSummary(key: key, title: "Long", body: String(repeating: "👨‍👩‍👧‍👦 ", count: 200))
        XCTAssertLessThanOrEqual(long.description.count, 280)
        XCTAssertTrue(long.description.hasSuffix("…"))
        XCTAssertFalse(long.description.contains("\n"))
    }

    func testOrdinaryPRLinkRespectsCurrentUnmergedStack() async throws {
        let f = try await CleanupFixture.make(metadata: CleanupMetadata(stackMerged: false))
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        XCTAssertFalse(try XCTUnwrap(preview.first).isEligible)
    }

    func testNewLinkedSessionBeforeFirstStopInvalidatesWholeApproval() async throws {
        let f = try await CleanupFixture.make(running: true)
        defer { f.dispose() }
        let id = UUID()
        let name = "githubbar-claude-widget-pr-12-\(id.uuidString.prefix(8).lowercased())"
        try await f.store.update { $0.setSession(AgentSessionLink(id: id, subject: f.subject, agent: .claude,
            worktreePath: f.path, tmuxSessionName: name, managedWorktree: true, state: .stopped)) }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        await f.runner.appearBeforeStop(name: name)
        _ = await f.coordinator.execute(preview, accountLogin: "tester")
        let kills = await f.runner.kills
        XCTAssertTrue(kills.isEmpty, "A changed full session set must stop no sessions")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    func testRestartedTmuxServerWithReusedIDInvalidatesApproval() async throws {
        let f = try await CleanupFixture.make(running: true)
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        await f.runner.restartServer()
        let results = await f.coordinator.execute(preview, accountLogin: "tester")
        XCTAssertEqual(results.map(\.outcome), [.skipped])
        let kills = await f.runner.kills
        XCTAssertTrue(kills.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }
    func testLingeringProcessRetainsWorktreeAfterApprovedStop() async throws {
        let f = try await CleanupFixture.make(running: true)
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        await f.runner.leaveLingeringProcess()
        let results = await f.coordinator.execute(preview, accountLogin: "tester")
        XCTAssertEqual(results.map(\.outcome), [.failed])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
        let doc = try await f.store.load()
        XCTAssertEqual(doc.sessions.count, 1)
    }
    func testSymlinkToAnotherWorktreeCannotBecomeCleanupTarget() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        let alias = f.root.appendingPathComponent("worktrees/alias").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: f.path)
        try await f.store.update { doc in
            let s = doc.sessions[0]
            doc.sessions[0] = AgentSessionLink(id: s.id, subject: s.subject, agent: s.agent,
                worktreePath: alias, tmuxSessionName: s.tmuxSessionName, managedWorktree: true)
        }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        XCTAssertFalse(try XCTUnwrap(preview.first).isEligible)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    func testRemovalFailureRetainsLinksAndDoesNotForce() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        await f.runner.refuseRemoval()
        let results = await f.coordinator.execute(preview, accountLogin: "tester")
        XCTAssertEqual(results.map(\.outcome), [.failed])
        let doc = try await f.store.load()
        XCTAssertEqual(doc.sessions.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    func testManagerRejectsRestartWhileCleanupOwnsLifecycle() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        let stored = try await f.store.load()
        let session = try XCTUnwrap(stored.sessions.first)
        let manager = AgentSessionManager(store: f.store, commandRunner: f.runner, tmuxURL: URL(fileURLWithPath: "/fake/tmux"))
        let gate = CleanupTestGate()
        let task = Task { try await manager.exclusively { await gate.pause() } }
        await gate.waitForStart()
        do { _ = try await manager.restart(id: session.id); XCTFail("Restart must not race cleanup") }
        catch { XCTAssertTrue(error.localizedDescription.contains("already in progress")) }
        await gate.resume()
        try await task.value
    }

    func testExistingRemoveDoesNotStopDirtySession() async throws {
        let f = try await CleanupFixture.make(running: true)
        defer { f.dispose() }
        try Data("changed".utf8).write(to: URL(fileURLWithPath: f.path + "/file"))
        let stored = try await f.store.load()
        let session = try XCTUnwrap(stored.sessions.first)
        let manager = AgentSessionManager(store: f.store, commandRunner: f.runner, tmuxURL: URL(fileURLWithPath: "/fake/tmux"))
        do { try await manager.removeManagedWorktree(id: session.id); XCTFail() }
        catch AgentSessionLaunchError.dirtyWorktree {}
        let kills = await f.runner.kills
        XCTAssertTrue(kills.isEmpty)
    }
    func testMergedSyncedWorktreeIsRemovedButBranchAndNotesRemain() async throws {
        let fixture = try await CleanupFixture.make()
        defer { fixture.dispose() }
        let preview = try await fixture.coordinator.preview(accountLogin: "tester")
        XCTAssertEqual(preview.count, 1)
        XCTAssertTrue(try XCTUnwrap(preview.first).isEligible, preview.first?.skipReason ?? "")
        XCTAssertEqual(preview.first?.pullRequests.first?.description, "Handle missing inputs. Keep the fallback active.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
        let results = await fixture.coordinator.execute(preview, accountLogin: "tester")
        XCTAssertEqual(results.map(\.outcome), [.removed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path))
        let document = try await fixture.store.load()
        XCTAssertTrue(document.sessions.isEmpty)
        XCTAssertEqual(document.entries.first?.note, "Keep this note")
        let branch = try await fixture.git(["rev-parse", "refs/heads/topic"])
        XCTAssertEqual(branch, fixture.sha)
        let refs = try await fixture.git(["for-each-ref", "--format=%(refname)", "refs/githubbar/cleanup"])
        XCTAssertTrue(refs.isEmpty)
    }

    func testUnsafeWorktreesAreSkippedWithoutStoppingSessions() async throws {
        for change in ["dirty", "staged", "untracked", "ignored", "ahead", "locked", "origin", "fetch", "external", "main", "missing", "hidden"] {
            let f = try await CleanupFixture.make(running: true)
            defer { f.dispose() }
            switch change {
            case "dirty": try Data("changed".utf8).write(to: URL(fileURLWithPath: f.path + "/file"))
            case "staged":
                try Data("changed".utf8).write(to: URL(fileURLWithPath: f.path + "/file"))
                _ = try await f.git(["add", "file"], path: f.path)
            case "untracked": try Data("keep".utf8).write(to: URL(fileURLWithPath: f.path + "/extra"))
            case "ignored": try Data("secret".utf8).write(to: URL(fileURLWithPath: f.path + "/local.env"))
            case "ahead": _ = try await f.git(["commit", "--allow-empty", "-qm", "Unpushed"], path: f.path)
            case "locked": _ = try await f.git(["worktree", "lock", f.path])
            case "origin": _ = try await f.git(["remote", "set-url", "origin", "https://github.com/other/repo.git"])
            case "fetch": await f.runner.setFetchFailure()
            case "external": try await f.store.update { doc in
                let s = doc.sessions[0]
                doc.sessions[0] = AgentSessionLink(id: s.id, subject: s.subject, agent: s.agent,
                    worktreePath: s.worktreePath, tmuxSessionName: s.tmuxSessionName, managedWorktree: false)
            }
            case "main": try await f.store.update { doc in
                let s = doc.sessions[0]
                doc.configuration.worktreeRoot = f.root.path
                doc.sessions[0] = AgentSessionLink(id: s.id, subject: s.subject, agent: s.agent,
                    worktreePath: f.checkout, tmuxSessionName: s.tmuxSessionName, managedWorktree: true)
            }
            case "missing": _ = try await f.git(["worktree", "remove", f.path])
            case "hidden": _ = try await f.git(["update-index", "--assume-unchanged", "file"], path: f.path)
            default: break
            }
            let preview = try await f.coordinator.preview(accountLogin: "tester")
            XCTAssertFalse(try XCTUnwrap(preview.first).isEligible, change)
            _ = await f.coordinator.execute(preview, accountLogin: "tester")
            let kills = await f.runner.kills
            XCTAssertTrue(kills.isEmpty, change)
            let sessions = try await f.store.load().sessions
            XCTAssertEqual(sessions.count, 1, change)
        }
    }

    func testChangedPreviewNeverStopsAgents() async throws {
        for change in ["dirty", "head", "config", "session", "account", "liveID"] {
            let f = try await CleanupFixture.make(running: true)
            defer { f.dispose() }
            let preview = try await f.coordinator.preview(accountLogin: "tester")
            XCTAssertTrue(try XCTUnwrap(preview.first).isEligible)
            switch change {
            case "dirty": try Data("changed".utf8).write(to: URL(fileURLWithPath: f.path + "/file"))
            case "head": _ = try await f.git(["commit", "--allow-empty", "-qm", "Late commit"], path: f.path)
            case "config": try await f.store.update { $0.configuration.codexCommand = "changed" }
            case "session": try await f.store.update { $0.setSession(AgentSessionLink(
                subject: f.subject, agent: .claude, worktreePath: f.path, tmuxSessionName: "external")) }
            case "liveID": await f.runner.replaceSessionID()
            default: break
            }
            let results = await f.coordinator.execute(preview, accountLogin: change == "account" ? "other" : "tester")
            XCTAssertEqual(results.map(\.outcome), [.skipped], change)
            let kills = await f.runner.kills
            XCTAssertTrue(kills.isEmpty, change)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.path), change)
        }
    }

    func testStopsApprovedSessionAndRechecksForWritesBeforeRemoval() async throws {
        let f = try await CleanupFixture.make(running: true)
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        await f.runner.writeOnStop()
        let results = await f.coordinator.execute(preview, accountLogin: "tester")
        XCTAssertNotEqual(results.map(\.outcome), [.removed])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path + "/late.txt"))
        let sessions = try await f.store.load().sessions
        XCTAssertEqual(sessions.count, 1)
        let kills = await f.runner.kills
        XCTAssertEqual(kills, ["$1"])
    }

    func testLiveApprovedSessionIsStoppedBeforeRemoval() async throws {
        let f = try await CleanupFixture.make(running: true)
        defer { f.dispose() }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        let results = await f.coordinator.execute(preview, accountLogin: "tester")
        XCTAssertEqual(results.map(\.outcome), [.removed])
        let kills = await f.runner.kills
        XCTAssertEqual(kills, ["$1"])
    }

    func testDuplicateLinksAreGroupedAndUnknownSessionsBlockCleanup() async throws {
        let f = try await CleanupFixture.make()
        defer { f.dispose() }
        try await f.store.update { $0.setSession(AgentSessionLink(subject: f.subject, agent: .claude,
            worktreePath: f.path, tmuxSessionName: nil, managedWorktree: true, state: .stopped)) }
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        XCTAssertEqual(preview.count, 1)
        XCTAssertEqual(preview.first?.sessions.count, 2)
        await f.runner.addUnknownSession()
        let blocked = try await f.coordinator.preview(accountLogin: "tester")
        XCTAssertFalse(try XCTUnwrap(blocked.first).isEligible)
    }

    func testUnmergedOrIncompleteStackIsBlocked() async throws {
        for metadata in [CleanupMetadata(merged: false), CleanupMetadata(merged: true, stackComplete: false),
                         CleanupMetadata(merged: true, stackMerged: false)] {
            let f = try await CleanupFixture.make(metadata: metadata, stack: true)
            defer { f.dispose() }
            let preview = try await f.coordinator.preview(accountLogin: "tester")
            XCTAssertFalse(try XCTUnwrap(preview.first).isEligible)
        }
    }

    func testSquashMergeWithDeletedBranchUsesRetainedPRHead() async throws {
        let f = try await CleanupFixture.make(stack: true)
        defer { f.dispose() }
        // Origin has only refs/pull/12/head; its branches are unrelated to this PR.
        _ = try await f.git(["commit", "--allow-empty", "-qm", "Squash merge on main"])
        let preview = try await f.coordinator.preview(accountLogin: "tester")
        XCTAssertTrue(try XCTUnwrap(preview.first).isEligible)
        let result = await f.coordinator.execute(preview, accountLogin: "tester")
        XCTAssertEqual(result.map(\.outcome), [.removed])
    }
}

private struct CleanupMetadata: Sendable {
    var merged = true
    var stackComplete = true
    var stackMerged = true
    var closed = false
    var isDraft = false
}

private actor CleanupGitHub: WorktreeCleanupGitHubChecking {
    let sha: String
    let metadata: CleanupMetadata
    var accountIsValid = true
    init(sha: String, metadata: CleanupMetadata) { self.sha = sha; self.metadata = metadata }
    func invalidateAccount() { accountIsValid = false }
    func verifyAccount(accountLogin: String) async throws {
        guard accountIsValid else { throw CleanupBlocked("The monitored account changed.") }
    }
    func check(_ subject: BoardSubject, accountLogin: String) async throws -> WorktreeCleanupPR {
        let memberKey = try PullRequestKey(url: URL(string: "https://github.com/acme/widget/pull/13")!)
        return WorktreeCleanupPR(title: "A useful change", headSHA: sha, merged: metadata.merged,
            hasStack: true, stackComplete: metadata.stackComplete, stackMerged: metadata.stackMerged,
            body: "Handle missing inputs.\n\nKeep the fallback active.", stackPullRequests: [
                WorktreeCleanupPRSummary(key: subject.key, title: "Root duplicate", body: "Duplicate"),
                WorktreeCleanupPRSummary(key: memberKey, title: "Follow-up change", body: "Update the caller."),
            ], closed: metadata.closed, isDraft: metadata.isDraft)
    }
}

private struct CleanupFixture: Sendable {
    let root: URL
    let checkout: String
    let path: String
    let sha: String
    let subject: BoardSubject
    let store: LocalWorkspaceStore
    let runner: CleanupRunner
    let github: CleanupGitHub
    let coordinator: WorktreeCleanupCoordinator

    static func make(running: Bool = false, metadata: CleanupMetadata = CleanupMetadata(), stack: Bool = false,
                     withSymlink: Bool = false, executable: Bool = false) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-test-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let checkout = root.appendingPathComponent("checkout").path
        let path = root.appendingPathComponent("worktrees/pr12").path
        let remote = root.appendingPathComponent("origin.git").path
        try await runGit(["init", "-q", checkout])
        try await runGit(["-C", checkout, "config", "user.name", "Test"])
        try await runGit(["-C", checkout, "config", "user.email", "test@example.invalid"])
        try Data("original".utf8).write(to: URL(fileURLWithPath: checkout + "/file"))
        try Data("*.env\n".utf8).write(to: URL(fileURLWithPath: checkout + "/.gitignore"))
        if withSymlink { try FileManager.default.createSymbolicLink(atPath: checkout + "/link", withDestinationPath: "file") }
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: checkout + "/file") }
        try await runGit(["-C", checkout, "add", "."])
        try await runGit(["-C", checkout, "commit", "-qm", "Initial"])
        let sha = try await runGit(["-C", checkout, "rev-parse", "HEAD"])
        try await runGit(["init", "--bare", "-q", remote])
        try await runGit(["-C", checkout, "push", "-q", remote, "HEAD:refs/pull/12/head"])
        try await runGit(["-C", checkout, "remote", "add", "origin", "https://github.com/acme/widget.git"])
        try await runGit(["-C", checkout, "worktree", "add", "-qb", "topic", path])
        let key = try PullRequestKey(url: URL(string: "https://github.com/acme/widget/pull/12")!)
        let subject: BoardSubject = stack ? .stack(key) : .pullRequest(key)
        let id = UUID()
        let name = "githubbar-codex-widget-pr-12-\(id.uuidString.prefix(8).lowercased())"
        let session = AgentSessionLink(id: id, subject: subject, agent: .codex, worktreePath: path,
            tmuxSessionName: name, managedWorktree: true, state: running ? .running : .stopped)
        let store = LocalWorkspaceStore(directoryURL: root.appendingPathComponent("board"))
        var document = LocalWorkspaceDocument.empty
        document.configuration = WorkspaceConfiguration(repositoryCheckouts: ["acme/widget": checkout],
            worktreeRoot: root.appendingPathComponent("worktrees").path)
        document.setSession(session)
        document.setEntry(BoardEntry(subject: subject, note: "Keep this note"))
        try await store.save(document)
        let runner = CleanupRunner(remote: remote, path: path, name: name, running: running)
        let manager = AgentSessionManager(store: store, commandRunner: runner, tmuxURL: URL(fileURLWithPath: "/fake/tmux"))
        let github = CleanupGitHub(sha: sha, metadata: metadata)
        let coordinator = WorktreeCleanupCoordinator(store: store, sessions: manager,
            github: github, commandRunner: runner,
            tmuxURL: URL(fileURLWithPath: "/fake/tmux"))
        return Self(root: root, checkout: checkout, path: path, sha: sha, subject: subject,
            store: store, runner: runner, github: github, coordinator: coordinator)
    }

    func git(_ args: [String], path: String? = nil) async throws -> String {
        try await Self.runGit(["-C", path ?? checkout] + args)
    }
    func dispose() { try? FileManager.default.removeItem(at: root) }
    @discardableResult
    static func runGit(_ args: [String]) async throws -> String {
        let r = await ProcessCommandRunner().run(executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: args, environment: [:])
        guard r.exitCode == 0 else { throw NSError(domain: "TestGit", code: Int(r.exitCode), userInfo: [NSLocalizedDescriptionKey: r.standardError]) }
        return r.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private actor CleanupRunner: CommandRunning {
    let remote: String
    let path: String
    let name: String
    var running: Bool
    var liveID = "$1"
    var unknown = false
    var unknownPath: String?
    var failFetch = false
    var writesOnStop = false
    var removalFails = false
    var lingering = false
    var serverPID = 100
    var listCalls = 0
    var appearingName: String?
    var appearanceListCall = 3
    var removalMutation: (@Sendable () async throws -> Void)?
    var listMutation: (@Sendable () async throws -> Void)?
    var mutationListCall = 0
    private(set) var kills: [String] = []
    init(remote: String, path: String, name: String, running: Bool) {
        self.remote = remote; self.path = path; self.name = name; self.running = running
    }
    func afterRemoval(_ mutation: @escaping @Sendable () async throws -> Void) { removalMutation = mutation }
    func onList(call: Int, mutation: @escaping @Sendable () async throws -> Void) { mutationListCall = call; listMutation = mutation }
    func setFetchFailure() { failFetch = true }
    func replaceSessionID() { liveID = "$2" }
    func addUnknownSession(path: String? = nil) { unknown = true; unknownPath = path }
    func writeOnStop() { writesOnStop = true }
    func refuseRemoval() { removalFails = true }
    func leaveLingeringProcess() { lingering = true }
    func restartServer() { serverPID = 200 }
    func appearBeforeStop(name: String, atListCall: Int = 3) { appearingName = name; appearanceListCall = atListCall }
    func run(executableURL: URL, arguments: [String], environment: [String: String]) async -> CommandResult {
        if executableURL.lastPathComponent == "lsof" {
            return CommandResult(exitCode: 0, standardOutput: lingering ? "p123\nn\(path)\n" : "", standardError: "")
        }
        if executableURL.path == "/fake/tmux" {
            if arguments.first == "list-panes" {
                listCalls += 1
                if listCalls == mutationListCall, let operation = listMutation {
                    listMutation = nil
                    do { try await operation() }
                    catch { return CommandResult(exitCode: 2, standardOutput: "", standardError: error.localizedDescription) }
                }
                let suffix = arguments.last?.contains("#{pid}") == true ? "\t\(serverPID)\t1700000000\t1700000001" : ""
                return CommandResult(exitCode: 0, standardOutput:
                    (running ? "\(liveID)\t\(name)\t\(path)\(suffix)\n" : "") +
                    (unknown ? "$99\tunknown\t\(unknownPath ?? path)\(suffix)\n" : "") +
                    (listCalls >= appearanceListCall ? appearingName.map { "$2\t\($0)\t\(path)\(suffix)\n" } ?? "" : ""), standardError: "")
            }
            if arguments.first == "kill-session" {
                kills.append(arguments.last!); running = false
                if writesOnStop { try? Data("keep".utf8).write(to: URL(fileURLWithPath: path + "/late.txt")) }
            }
            return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        var args = arguments
        if args.contains("worktree"), args.contains("remove"), removalFails {
            return CommandResult(exitCode: 1, standardOutput: "", standardError: "Refused")
        }
        if (args.contains("fetch") || args.contains("ls-remote")), let index = args.firstIndex(of: "origin") {
            if failFetch { return CommandResult(exitCode: 1, standardOutput: "", standardError: "Offline") }
            args[index] = remote
        }
        let result = await ProcessCommandRunner().run(executableURL: executableURL, arguments: args, environment: environment)
        if args.contains("worktree"), args.contains("remove"), result.exitCode == 0, let operation = removalMutation {
            removalMutation = nil
            do { try await operation() }
            catch { return CommandResult(exitCode: 2, standardOutput: "", standardError: error.localizedDescription) }
        }
        return result
    }
}

private actor LegacyCleanupService: WorktreeCleanupServicing {
    private(set) var executions = 0
    func preview(accountLogin: String) async throws -> [WorktreeCleanupCandidate] { [] }
    func execute(_ approved: [WorktreeCleanupCandidate], accountLogin: String) async -> [WorktreeCleanupResult] {
        executions += 1
        return approved.map { WorktreeCleanupResult(path: $0.path, outcome: .removed, message: "Controlled fake only") }
    }
}

private actor CleanupTestGate {
    var continuation: CheckedContinuation<Void, Never>?
    func pause() async { await withCheckedContinuation { continuation = $0 } }
    func waitForStart() async { while continuation == nil { await Task.yield() } }
    func resume() { continuation?.resume(); continuation = nil }
}
