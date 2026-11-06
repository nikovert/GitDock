import XCTest
@testable import GitDock

@MainActor
final class ReviewWorkspaceStateTests: XCTestCase {
    func testSameHeadWithDifferentBaseKeepsDraftsSeparate() throws {
        let name = "ReviewBaseTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ReviewWorkspaceState(defaults: defaults)
        let original = ReviewIdentity(account: "alice", prURL: "https://github.com/acme/app/pull/1", headSHA: "head", baseSHA: "old-base")
        let retargeted = ReviewIdentity(account: "alice", prURL: original.prURL, headSHA: "head", baseSHA: "new-base")
        var draft = WorkspaceReviewDraft()
        draft.body = "Comment about the old base"
        store.save(draft, for: original)
        XCTAssertEqual(store.draft(for: retargeted).body, "")
        XCTAssertEqual(store.draft(for: original).body, "Comment about the old base")
        XCTAssertEqual(store.previousDraftIdentities(retargeted), [original])
    }

    func testDraftsAndViewedFilesSurviveRestartWithoutCrossingAccountOrHead() throws {
        let name = "ReviewWorkspaceTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ReviewWorkspaceState(defaults: defaults)
        let identity = ReviewIdentity(account: "Alice", prURL: "https://github.com/acme/app/pull/1", headSHA: "aaa")
        var draft = store.draft(for: identity)
        draft.body = "Check the fallback"
        draft.viewedFiles = ["src/controller.swift"]
        draft.selectedFile = "src/controller.swift"
        store.save(draft, for: identity)
        let reopened = ReviewWorkspaceState(defaults: defaults)
        XCTAssertEqual(reopened.draft(for: identity), draft)
        XCTAssertEqual(reopened.draft(for: ReviewIdentity(account: "alice", prURL: identity.prURL, headSHA: "aaa")), draft)
        XCTAssertEqual(reopened.draft(for: ReviewIdentity(account: "bob", prURL: identity.prURL, headSHA: "aaa")).body, "")
        XCTAssertEqual(reopened.draft(for: ReviewIdentity(account: "alice", prURL: identity.prURL, headSHA: "bbb")).body, "")
    }

    func testPinsSnoozeAndReviewedBaselineAreAccountScoped() throws {
        let name = "ReviewWorkspaceTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ReviewWorkspaceState(defaults: defaults)
        let id = ReviewIdentity(account: "alice", prURL: "https://github.com/acme/app/pull/1", headSHA: "aaa")
        store.setPinned(true, for: id)
        store.snooze(until: Date(timeIntervalSince1970: 100), for: id)
        store.markReviewed(id)
        let next = ReviewIdentity(account: "Alice", prURL: id.prURL, headSHA: "bbb")
        XCTAssertTrue(store.isPinned(next))
        XCTAssertTrue(store.isSnoozed(next, now: Date(timeIntervalSince1970: 99)))
        XCTAssertFalse(store.isSnoozed(next, now: Date(timeIntervalSince1970: 101)))
        XCTAssertEqual(store.lastReviewedSHA(next), "aaa")
        let other = ReviewIdentity(account: "bob", prURL: id.prURL, headSHA: "aaa")
        XCTAssertFalse(store.isPinned(other))
        XCTAssertNil(store.lastReviewedSHA(other))
    }

    func testInvalidPersistedStateIsNotOverwritten() throws {
        let name = "ReviewWorkspaceTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let invalid = Data("not valid JSON".utf8)
        defaults.set(invalid, forKey: ReviewWorkspaceState.storageKey)
        let store = ReviewWorkspaceState(defaults: defaults)
        XCTAssertNotNil(store.errorMessage)
        store.save(WorkspaceReviewDraft(), for: ReviewIdentity(account: "a", prURL: "url", headSHA: "a"))
        XCTAssertEqual(defaults.data(forKey: ReviewWorkspaceState.storageKey), invalid)
    }
}
