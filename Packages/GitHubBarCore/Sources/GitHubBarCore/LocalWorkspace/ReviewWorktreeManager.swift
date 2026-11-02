import Darwin
import Foundation
import CryptoKit

/// Owns only its freshly-created detached trees and unique private refs. Never resets
/// a checkout or forces removal; suspicious artifacts are left in place for recovery.
public actor ReviewWorktreeManager: ReviewWorktreeServicing {
    private let store: LocalWorkspaceStore
    private let commandRunner: any CommandRunning
    private let gitURL: URL
    private var owned: [UUID: OwnedReview] = [:]
    private var busy = false
    private static let maximumContextBytes = 256 * 1_024 * 1_024
    private static let maximumFiles = 20_000
    // A reported commit SHA must denote its original objects and ancestry, even
    // when the configured checkout has local replacement refs or legacy grafts.
    private static let environment = [
        "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_LITERAL_PATHSPECS": "1",
        "GIT_NO_REPLACE_OBJECTS": "1", "GIT_GRAFT_FILE": "/dev/null",
    ]
    private static let safety = [
        "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
        "-c", "diff.external=", "-c", "core.autocrlf=false", "-c", "core.symlinks=true",
        "-c", "core.sshCommand=/usr/bin/ssh", "-c", "protocol.ext.allow=never",
        "-c", "submodule.recurse=false", "-c", "fetch.recurseSubmodules=false",
    ]

    public init(store: LocalWorkspaceStore = LocalWorkspaceStore(),
                commandRunner: any CommandRunning = ReviewWorktreeCommandRunner(),
                gitURL: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.store = store
        self.commandRunner = commandRunner
        self.gitURL = gitURL
    }

    public func prepare(_ request: ReviewWorktreeRequest) async throws -> ReviewWorktreeLease {
        guard !busy else { throw failure("Another review worktree operation is in progress.") }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        guard Self.validSHA(request.headSHA), Self.validSHA(request.baseSHA),
              !request.accountLogin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure("Review requires the captured account, head and base commit identities.")
        }
        let document = try await store.load()
        try Task.checkCancellation()
        guard let configuredCheckout = document.configuration.repositoryCheckouts[request.key.repositoryNameWithOwner],
              configuredCheckout.hasPrefix("/"), FileManager.default.fileExists(atPath: configuredCheckout) else {
            throw failure("Configure a local checkout for this repository in Workspace before reviewing.")
        }
        let checkout = URL(fileURLWithPath: configuredCheckout).resolvingSymlinksInPath().standardizedFileURL.path
        let root = try safeRoot(document.configuration.worktreeRoot, checkout: checkout)
        let flags = try await filterSafety(checkout)
        let origin = try await git(checkout, ["remote", "get-url", "origin"], flags: flags)
        guard AgentSessionManager.repositoryNameWithOwner(fromRemoteURL: origin) == request.key.repositoryNameWithOwner else {
            throw failure("The checkout's origin must point to \(request.key.repositoryNameWithOwner) on github.com.")
        }
        let top = try await git(checkout, ["rev-parse", "--show-toplevel"], flags: flags).trimmingCharacters(in: .newlines)
        guard URL(fileURLWithPath: top).resolvingSymlinksInPath().path == checkout else {
            throw failure("The configured checkout must be the repository root.")
        }
        let shallow = try await git(checkout, ["rev-parse", "--is-shallow-repository"], flags: flags)
        guard shallow.trimmingCharacters(in: .whitespacesAndNewlines) == "false" else {
            throw failure("A shallow checkout cannot establish complete review history. Fetch full history first.")
        }
        let common = try await git(checkout, ["rev-parse", "--path-format=absolute", "--git-common-dir"], flags: flags)
            .trimmingCharacters(in: .newlines)
        guard common.hasPrefix("/") else { throw failure("Could not establish checkout ownership.") }
        let id = UUID()
        let container = URL(fileURLWithPath: root).appendingPathComponent("review-\(id.uuidString)")
        let tree = container.appendingPathComponent("worktree")
        let context = container.appendingPathComponent("context")
        let prefix = "refs/githubbar/reviews/\(id.uuidString.lowercased())"
        var record = OwnedReview(id: id, checkout: checkout, container: container.path,
            worktree: tree.path, context: context.path, commonDirectory: common,
            refs: [prefix + "/head", prefix + "/base"], flags: flags)
        // Record ownership before any command can mutate refs or create a worktree.
        owned[id] = record
        do {
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            record.containerIdentity = try identity(container.path, directory: true)
            owned[id] = record
            try FileManager.default.createDirectory(at: context, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            owned[id]!.contextIdentity = try identity(context.path, directory: true)
            for ref in record.refs {
                guard !FileManager.default.fileExists(atPath: common + "/" + ref) else { throw failure("Review private reference already exists.") }
                let existing = await commandRunner.run(executableURL: gitURL,
                    arguments: ["-C", checkout] + flags + ["show-ref", "--verify", "--quiet", ref], environment: Self.environment)
                try Task.checkCancellation()
                guard existing.exitCode == 1 else { throw failure("Review private reference already exists or cannot be verified.") }
            }
            try await fetch(checkout, ["fetch", "--no-tags", "--no-recurse-submodules", "--no-write-fetch-head", "origin",
                "refs/pull/\(request.key.number)/head:\(record.refs[0])"], id: id)
            let head = try await git(checkout, ["rev-parse", "--verify", record.refs[0] + "^{commit}"], flags: flags).trimmingCharacters(in: .newlines)
            guard head == request.headSHA else { throw failure("The pull-request head changed. Refresh the PR and retry review.") }
            try await fetch(checkout, ["fetch", "--no-tags", "--no-recurse-submodules", "--no-write-fetch-head", "origin",
                "\(request.baseSHA):\(record.refs[1])"], id: id)
            let base = try await git(checkout, ["rev-parse", "--verify", record.refs[1] + "^{commit}"], flags: flags).trimmingCharacters(in: .newlines)
            guard base == request.baseSHA else { throw failure("The pull-request base changed. Refresh the PR and retry review.") }
            let mergeBases = try await git(checkout, ["merge-base", "--all", base, head], flags: flags)
                .split(separator: "\n").map(String.init)
            guard mergeBases.count == 1, let mergeBase = mergeBases.first, Self.validSHA(mergeBase) else {
                throw failure("A unique complete PR merge base could not be resolved.")
            }
            // A failed/cancelled add can still create files. Cleanup knows its intended
            // path before launch and captures filesystem identity immediately afterward.
            owned[id]!.addAttempted = true
            let add = await commandRunner.run(executableURL: gitURL,
                arguments: ["-C", checkout] + flags + ["worktree", "add", "--detach", "--", tree.path, head], environment: Self.environment)
            captureTreeIdentity(id)
            try Task.checkCancellation()
            guard add.exitCode == 0 else { throw failure("Could not create a detached review worktree. Check Workspace paths and Git access.") }
            owned[id]!.treeSnapshot = try treeSnapshot(tree.path)
            let files = try await makeManifestFiles(id: id, head: head, mergeBase: mergeBase)
            let lease = ReviewWorktreeLease(id: id, key: request.key, accountLogin: request.accountLogin,
                headSHA: head, baseSHA: base, mergeBaseSHA: mergeBase, worktreePath: tree.path,
                contextDirectory: context.path, manifestPath: context.appendingPathComponent("manifest.json").path,
                changedPaths: files.map(\.path))
            let manifest = ReviewWorktreeManifest(version: 1, worktreePath: tree.path,
                headSHA: head, baseSHA: base, mergeBaseSHA: mergeBase, files: files)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let manifestData = try encoder.encode(manifest)
            guard manifestData.count <= 4 * 1_024 * 1_024 else { throw failure("Complete review manifest exceeds the 4 MiB resource limit.") }
            try write(manifestData, name: "manifest.json", id: id)
            owned[id]!.lease = lease
            try await validateOwned(lease)
            try Task.checkCancellation()
            return lease
        } catch {
            // The cancelled caller cannot cancel safety checks or leave partially-owned
            // mutations behind. Never force a removal if those checks are inconclusive.
            let warning = await Task.detached { await self.cleanup(id) }.value
            if let warning { throw failure("\(error.localizedDescription) \(warning)") }
            throw error
        }
    }

    public func validate(_ lease: ReviewWorktreeLease) async throws {
        guard !busy else { throw failure("Another review worktree operation is in progress.") }
        busy = true
        defer { busy = false }
        try await validateOwned(lease)
    }

    public func release(_ lease: ReviewWorktreeLease) async -> String? {
        guard let record = owned[lease.id], record.lease == lease else {
            return "Review artifacts were retained at \(lease.worktreePath): ownership could not be verified."
        }
        // Do not share the UI task's cancellation with cleanup.
        return await Task.detached { await self.cleanup(lease.id) }.value
    }

    private func validateOwned(_ lease: ReviewWorktreeLease) async throws {
        try Task.checkCancellation()
        guard let record = owned[lease.id], record.lease == lease else { throw failure("Review worktree ownership could not be verified.") }
        try verifyFiles(record)
        let flags = try await filterSafety(record.worktree)
        try await verifyTree(record, expectedHead: lease.headSHA, flags: flags)
        for (index, ref) in record.refs.enumerated() {
            let value = try await git(record.checkout, ["rev-parse", "--verify", ref + "^{commit}"], flags: flags).trimmingCharacters(in: .newlines)
            guard value == (index == 0 ? lease.headSHA : lease.baseSHA) else { throw failure("Review private commit reference changed.") }
        }
        try verifyFiles(record)
    }

    private func makeManifestFiles(id: UUID, head: String, mergeBase: String) async throws -> [ReviewWorktreeManifest.File] {
        guard let record = owned[id] else { throw failure("Review ownership lost.") }
        let inventory = try await git(record.checkout, ["diff", "--name-status", "-z", "--find-renames", "--no-ext-diff", "--no-textconv", mergeBase, head, "--"], flags: record.flags)
        let tokens = inventory.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard tokens.last == "" else { throw failure("Git returned an incomplete changed-file inventory.") }
        var index = 0
        var files: [ReviewWorktreeManifest.File] = []
        var seen = Set<String>()
        while index < tokens.count - 1 {
            guard files.count < Self.maximumFiles, index + 1 < tokens.count - 1 else { throw failure("Review changed-file inventory exceeds its resource limit or is invalid.") }
            let status = tokens[index]
            index += 1
            guard let kind = status.first, "AMDRCT".contains(kind) else { throw failure("Review contains an unsupported Git change type.") }
            let first = tokens[index]
            index += 1
            let previous: String?
            let path: String
            if kind == "R" || kind == "C" {
                guard index < tokens.count - 1 else { throw failure("Git rename inventory is incomplete.") }
                previous = first
                path = tokens[index]
                index += 1
            } else { previous = nil; path = first }
            guard Self.validPath(path), previous.map(Self.validPath) ?? true, seen.insert(path).inserted else {
                throw failure("Review contains an unsupported or duplicate path.")
            }
            let paths = previous.map { [$0, path] } ?? [path]
            let patch = try await git(record.checkout, ["diff", "--patch", "--binary", "--full-index", "--find-renames", "--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", mergeBase, head, "--"] + paths, flags: record.flags)
            let statistics = try await git(record.checkout, ["diff", "--numstat", "-z", "--no-ext-diff", "--no-textconv", mergeBase, head, "--"] + paths, flags: record.flags)
            let binary = statistics.split(separator: "\0").contains { $0.hasPrefix("-\t-\t") }
            let basePath = previous ?? path
            let baseEntry = try await git(record.checkout, ["ls-tree", "-z", mergeBase, "--", basePath], flags: record.flags)
            let headEntry = try await git(record.checkout, ["ls-tree", "-z", head, "--", path], flags: record.flags)
            guard !baseEntry.hasPrefix("160000 "), !headEntry.hasPrefix("160000 ") else {
                throw failure("Submodule changes require a separate repository review.")
            }
            let isSymlink = baseEntry.hasPrefix("120000 ") || headEntry.hasPrefix("120000 ")
            let patchName = String(format: "%05d.patch", files.count)
            try write(Data(patch.utf8), name: patchName, id: id)
            var baselineName: String?
            if !baseEntry.isEmpty, !binary {
                let baseline = try await git(record.checkout, ["cat-file", "blob", "\(mergeBase):\(basePath)"], flags: record.flags)
                baselineName = String(format: "%05d.base", files.count)
                try write(Data(baseline.utf8), name: baselineName!, id: id)
            }
            files.append(.init(path: path, previousPath: previous, status: String(kind),
                patchFile: record.context + "/" + patchName,
                baseFile: baselineName.map { record.context + "/" + $0 }, isBinary: binary, isSymlink: isSymlink))
        }
        return files
    }

    private func write(_ data: Data, name: String, id: UUID) throws {
        guard var record = owned[id], data.count <= Self.maximumContextBytes - record.contextBytes else {
            throw failure("Complete review context exceeds the 256 MiB resource limit. No partial review was created.")
        }
        let path = record.context + "/" + name
        try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path)
        record.contextBytes += data.count
        record.contextFiles[name] = .init(identity: try identity(path, directory: false), hash: Data(SHA256.hash(data: data)), count: data.count)
        owned[id] = record
    }

    private func fetch(_ checkout: String, _ arguments: [String], id: UUID) async throws {
        guard let record = owned[id] else { throw failure("Review ownership lost.") }
        let result = await commandRunner.run(executableURL: gitURL, arguments: ["-C", checkout] + record.flags + arguments, environment: Self.environment)
        // Fetch may mutate refs before returning cancellation. Synchronously capture
        // only freshly-owned loose refs before observing cancellation.
        for ref in record.refs {
            let path = record.commonDirectory + "/" + ref
            if let data = try? regularData(path, maximum: 128), let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines), Self.validSHA(value) {
                owned[id]!.refValues[ref] = value
            }
        }
        try Task.checkCancellation()
        guard result.exitCode == 0 else { throw failure("Could not fetch the captured PR commits. Refresh the PR and check Git access.") }
    }

    private func captureTreeIdentity(_ id: UUID) {
        guard let record = owned[id] else { return }
        owned[id]!.treeIdentity = try? identity(record.worktree, directory: true, ownerOnly: false)
        owned[id]!.gitFile = try? regularData(record.worktree + "/.git", maximum: 16 * 1_024)
    }

    private func cleanup(_ id: UUID) async -> String? {
        guard let record = owned[id] else { return nil }
        func warning() -> String { "Review artifacts were retained at \(record.worktree) (context: \(record.context)): ownership or unchanged contents could not be verified." }
        do {
            try verifyFiles(record)
            let flags = try await filterSafety(FileManager.default.fileExists(atPath: record.worktree) ? record.worktree : record.checkout)
            if record.addAttempted, FileManager.default.fileExists(atPath: record.worktree) {
                guard record.treeIdentity != nil, record.gitFile != nil else { return warning() }
                let expected = record.lease?.headSHA ?? record.refValues[record.refs[0]]
                guard let expected else { return warning() }
                try await verifyTree(record, expectedHead: expected, flags: flags)
                try verifyFiles(record)
                _ = try await git(record.checkout, ["worktree", "remove", "--", record.worktree], flags: flags)
            }
            for ref in record.refs {
                guard let expected = record.refValues[ref] else { continue }
                _ = try await git(record.checkout, ["update-ref", "-d", ref, expected], flags: flags)
            }
            // Worktree removal should leave only the context directory we created.
            let children = try FileManager.default.contentsOfDirectory(atPath: record.container)
            guard children == ["context"] || children.isEmpty else { return warning() }
            try verifyFiles(record)
            if FileManager.default.fileExists(atPath: record.context) {
                // Delete only known regular files, then rmdir rather than a recursive
                // removal that could consume a concurrently-created user artifact.
                for name in try FileManager.default.contentsOfDirectory(atPath: record.context) {
                    guard record.contextFiles[name] != nil || name == "discussion.json" else { return warning() }
                    guard unlink(record.context + "/" + name) == 0 else { return warning() }
                }
                guard rmdir(record.context) == 0 else { return warning() }
            }
            guard rmdir(record.container) == 0 else { return warning() }
            owned.removeValue(forKey: id)
            return nil
        } catch { return warning() }
    }

    private func verifyTree(_ record: OwnedReview, expectedHead: String, flags: [String]) async throws {
        guard try identity(record.worktree, directory: true, ownerOnly: false) == record.treeIdentity,
              try regularData(record.worktree + "/.git", maximum: 16 * 1_024) == record.gitFile else {
            throw failure("The review worktree was replaced. Its files have been retained.")
        }
        let actual = try await git(record.worktree, ["rev-parse", "--verify", "HEAD^{commit}"], flags: flags).trimmingCharacters(in: .newlines)
        let branch = await commandRunner.run(executableURL: gitURL,
            arguments: ["-C", record.worktree] + flags + ["symbolic-ref", "-q", "HEAD"], environment: Self.environment)
        try Task.checkCancellation()
        guard actual == expectedHead, branch.exitCode == 1 else { throw failure("The review worktree commit or detached state changed.") }
        let indexFlags = try await git(record.worktree, ["ls-files", "-v", "-z"], flags: flags)
        guard indexFlags.split(separator: "\0").allSatisfy({ $0.first == "H" }) else {
            throw failure("The review worktree index has hidden or unsupported entries.")
        }
        if let expected = record.treeSnapshot, try treeSnapshot(record.worktree) != expected {
            throw failure("The review worktree contents changed. Its files have been retained.")
        }
        let status = try await git(record.worktree, ["status", "--porcelain=v1", "-z", "--ignored", "--untracked-files=all", "--ignore-submodules=none"], flags: flags)
        guard status.isEmpty else { throw failure("The review worktree has local changes. Its files have been retained.") }
        guard try identity(record.worktree, directory: true, ownerOnly: false) == record.treeIdentity,
              try regularData(record.worktree + "/.git", maximum: 16 * 1_024) == record.gitFile else { throw failure("The review worktree was replaced.") }
    }

    private func verifyFiles(_ record: OwnedReview) throws {
        guard try identity(record.container, directory: true) == record.containerIdentity else { throw failure("Review artifact directory was replaced.") }
        if let contextIdentity = record.contextIdentity {
            guard try identity(record.context, directory: true) == contextIdentity else { throw failure("Review context directory was replaced.") }
            let names = try FileManager.default.contentsOfDirectory(atPath: record.context)
            guard Set(names).isSuperset(of: record.contextFiles.keys), names.allSatisfy({ record.contextFiles[$0] != nil || $0 == "discussion.json" }) else {
                throw failure("Review context contents changed.")
            }
            for (name, file) in record.contextFiles {
                let path = record.context + "/" + name
                let contents = try regularData(path, maximum: file.count)
                guard try identity(path, directory: false) == file.identity,
                      contents.count == file.count,
                      Data(SHA256.hash(data: contents)) == file.hash else { throw failure("Review context contents changed.") }
            }
            if names.contains("discussion.json") {
                _ = try identity(record.context + "/discussion.json", directory: false)
                let attrs = try FileManager.default.attributesOfItem(atPath: record.context + "/discussion.json")
                guard (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 16 * 1_024 * 1_024 else { throw failure("Review discussion exceeds its resource limit.") }
            }
        }
    }

    private func filterSafety(_ checkout: String) async throws -> [String] {
        let result = await commandRunner.run(executableURL: gitURL,
            arguments: ["-C", checkout] + Self.safety + ["config", "--null", "--name-only", "--get-regexp", "^filter\\..*\\.(process|smudge|clean|required)$"], environment: Self.environment)
        try Task.checkCancellation()
        guard result.exitCode == 0 || result.exitCode == 1, result.standardOutput.utf8.count < 1_024 * 1_024 else { throw failure("Could not safely enumerate Git content filters.") }
        var drivers = Set<String>()
        for key in result.standardOutput.split(separator: "\0").map(String.init) {
            guard key.hasPrefix("filter."), let dot = key.lastIndex(of: ".") else { throw failure("Unsupported Git filter configuration.") }
            drivers.insert(String(key[key.index(key.startIndex, offsetBy: 7)..<dot]))
        }
        guard drivers.count <= 1_024 else { throw failure("Git filter configuration exceeds its resource limit.") }
        return Self.safety + drivers.sorted().flatMap { name in
            ["-c", "filter.\(name).process=", "-c", "filter.\(name).clean=/bin/cat", "-c", "filter.\(name).smudge=/bin/cat", "-c", "filter.\(name).required=false"]
        }
    }

    private func git(_ directory: String, _ arguments: [String], flags: [String]) async throws -> String {
        let result = await commandRunner.run(executableURL: gitURL, arguments: ["-C", directory] + flags + arguments, environment: Self.environment)
        try Task.checkCancellation()
        guard result.exitCode == 0 else { throw failure("Review Git operation failed. Check the local checkout and captured PR history. No partial review was accepted.") }
        return result.standardOutput
    }

    /// Compare actual bytes rather than relying on Git's mutable index/stat cache.
    /// Symlinks are hashed as links and are never followed outside the leased tree.
    private func treeSnapshot(_ root: String) throws -> [String: Data] {
        var result: [String: Data] = [:]
        var pending = [""]
        var bytes = 0
        while let relative = pending.popLast() {
            try Task.checkCancellation()
            let parent = relative.isEmpty ? root : root + "/" + relative
            for name in try FileManager.default.contentsOfDirectory(atPath: parent).sorted() {
                if relative.isEmpty && name == ".git" { continue }
                let path = relative.isEmpty ? name : relative + "/" + name
                let absolute = root + "/" + path
                guard result.count < 200_000 else { throw failure("Review worktree exceeds the 200,000-entry verification resource limit.") }
                var info = stat()
                guard lstat(absolute, &info) == 0, info.st_uid == getuid() else { throw failure("Review worktree changed during verification.") }
                let kind = info.st_mode & S_IFMT
                var hasher = SHA256()
                hasher.update(data: Data(String(info.st_mode).utf8))
                if kind == S_IFDIR {
                    pending.append(path)
                } else if kind == S_IFLNK {
                    var target = [UInt8](repeating: 0, count: 16 * 1_024)
                    let count = readlink(absolute, &target, target.count)
                    guard count >= 0, count < target.count else { throw failure("Review symlink exceeds its verification resource limit.") }
                    hasher.update(data: Data(target.prefix(count)))
                } else if kind == S_IFREG {
                    guard info.st_size <= 512 * 1_024 * 1_024 else { throw failure("A review worktree file exceeds the 512 MiB verification resource limit.") }
                    let descriptor = open(absolute, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                    guard descriptor >= 0 else { throw failure("Review file could not be verified safely.") }
                    defer { close(descriptor) }
                    var opened = stat()
                    guard fstat(descriptor, &opened) == 0, opened.st_ino == info.st_ino,
                          opened.st_dev == info.st_dev, opened.st_mode & S_IFMT == S_IFREG else { throw failure("Review file changed during verification.") }
                    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
                    var readCount = 0
                    while true {
                        try Task.checkCancellation()
                        let count = Darwin.read(descriptor, &buffer, buffer.count)
                        if count == 0 { break }
                        if count == -1 && errno == EINTR { continue }
                        guard count > 0, bytes <= 2 * 1_024 * 1_024 * 1_024 - count,
                              readCount <= 512 * 1_024 * 1_024 - count else { throw failure("Review worktree exceeds its 2 GiB verification resource limit.") }
                        bytes += count
                        readCount += count
                        hasher.update(data: Data(buffer.prefix(count)))
                    }
                    var after = stat()
                    guard fstat(descriptor, &after) == 0, after.st_size == opened.st_size,
                          after.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
                          after.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec,
                          readCount == opened.st_size else { throw failure("Review file changed during verification.") }
                } else { throw failure("Review worktree contains an unsupported special file.") }
                result[path] = Data(hasher.finalize())
            }
        }
        return result
    }

    private func safeRoot(_ configured: String, checkout: String) throws -> String {
        guard configured.hasPrefix("/"), !configured.contains("\0") else { throw failure("Configure an absolute, safe worktree root in Workspace.") }
        let url = URL(fileURLWithPath: configured).standardizedFileURL
        var info = stat()
        if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { throw failure("The review worktree root must not be a symbolic link.") }
        let resolved = url.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        guard resolved != "/", resolved != home, resolved != checkout,
              !resolved.hasPrefix(checkout + "/"), !checkout.hasPrefix(resolved + "/") else { throw failure("The review worktree root must be outside the checkout and dedicated to worktrees.") }
        try FileManager.default.createDirectory(atPath: resolved, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try identity(resolved, directory: true, ownerOnly: false)
        guard lstat(resolved, &info) == 0, info.st_mode & 0o022 == 0 else { throw failure("The review worktree root must not be writable by other users.") }
        return resolved
    }

    private func identity(_ path: String, directory: Bool, ownerOnly: Bool = true) throws -> Identity {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              !ownerOnly || info.st_mode & 0o077 == 0,
              directory || info.st_nlink == 1 else { throw failure("Review artifact ownership could not be verified.") }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    private func regularData(_ path: String, maximum: Int) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw failure("Review artifact could not be read safely.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximum else { throw failure("Review artifact exceeds its resource limit or is not a regular file.") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0, errno == EINTR { continue }
            guard count > 0, data.count <= maximum - count else { throw failure("Review artifact changed while being read.") }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func validSHA(_ value: String) -> Bool {
        (value.utf8.count == 40 || value.utf8.count == 64) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func validPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && path.utf8.count <= 4_096 && !path.contains("\0")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" })
    }
    private func failure(_ message: String) -> ReviewWorktreeError { .failed(message) }

    private struct Identity: Equatable, Sendable { let device: dev_t; let inode: ino_t }
    private struct ContextFile: Sendable { let identity: Identity; let hash: Data; let count: Int }
    private struct OwnedReview: Sendable {
        let id: UUID
        let checkout: String
        let container: String
        let worktree: String
        let context: String
        let commonDirectory: String
        let refs: [String]
        let flags: [String]
        var containerIdentity: Identity?
        var contextIdentity: Identity?
        var treeIdentity: Identity?
        var treeSnapshot: [String: Data]?
        var gitFile: Data?
        var refValues: [String: String] = [:]
        var contextFiles: [String: ContextFile] = [:]
        var contextBytes = 0
        var addAttempted = false
        var lease: ReviewWorktreeLease?
    }
}
