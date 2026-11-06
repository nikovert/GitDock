import Darwin
import Foundation

/// Bounded Git transport. Each invocation owns a process group from spawn onward;
/// cancellation/limits kill and reap that group before returning a failure sentinel.
public struct ReviewWorktreeCommandRunner: CommandRunning {
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int

    public init(timeout: TimeInterval = 120, maximumOutputBytes: Int = 32 * 1_024 * 1_024) {
        self.timeout = max(0.01, timeout)
        self.maximumOutputBytes = max(1, maximumOutputBytes)
    }

    public func run(executableURL: URL, arguments: [String], environment: [String: String]) async -> CommandResult {
        let cancellation = ReviewCommandCancellation()
        return await withTaskCancellationHandler {
            if Task.isCancelled { cancellation.cancel() }
            return await Task.detached {
                Self.execute(executableURL: executableURL, arguments: arguments, environment: environment,
                             timeout: timeout, maximumOutputBytes: maximumOutputBytes, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func execute(executableURL: URL, arguments: [String], environment: [String: String],
                                timeout: TimeInterval, maximumOutputBytes: Int,
                                cancellation: ReviewCommandCancellation) -> CommandResult {
        func failure(_ text: String) -> CommandResult {
            .init(exitCode: -1, standardOutput: "", standardError: text)
        }
        guard !cancellation.isCancelled else { return failure("Review Git command cancelled.") }
        var outputFD: [Int32] = [0, 0]
        var errorFD: [Int32] = [0, 0]
        guard pipe(&outputFD) == 0 else { return failure("Could not start review Git command.") }
        guard pipe(&errorFD) == 0 else {
            close(outputFD[0]); close(outputFD[1])
            return failure("Could not start review Git command.")
        }
        defer { close(outputFD[0]); close(errorFD[0]) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outputFD[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errorFD[1], STDERR_FILENO)
        for descriptor in outputFD + errorFD { posix_spawn_file_actions_addclose(&actions, descriptor) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        // Do not inherit GIT_* overrides, dynamic-loader injection, or a caller's shell.
        var childEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
        if let home = ProcessInfo.processInfo.environment["HOME"] { childEnvironment["HOME"] = home }
        childEnvironment.merge(environment) { _, supplied in supplied }
        // Enforce original object identity for every invocation, including injected
        // callers: replace refs and info/grafts must never reinterpret a pinned SHA.
        childEnvironment["GIT_NO_REPLACE_OBJECTS"] = "1"
        childEnvironment["GIT_GRAFT_FILE"] = "/dev/null"
        let argv = ([executableURL.path] + arguments).map { strdup($0) } + [nil]
        let envp = childEnvironment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pid: pid_t = 0
        let spawned = argv.withUnsafeBufferPointer { argPointer in
            envp.withUnsafeBufferPointer { envPointer in
                posix_spawn(&pid, executableURL.path, &actions, &attributes,
                            UnsafeMutablePointer(mutating: argPointer.baseAddress!),
                            UnsafeMutablePointer(mutating: envPointer.baseAddress!))
            }
        }
        close(outputFD[1]); close(errorFD[1])
        guard spawned == 0 else { return failure("Could not start review Git command.") }
        _ = fcntl(outputFD[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(errorFD[0], F_SETFL, O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var output = Data()
        var errors = Data()
        var failureReason: String?
        var status: Int32 = 0
        var exited = false
        var outputClosed = false
        var errorClosed = false
        func drain(_ descriptor: Int32, into data: inout Data, closed: inout Bool, limit: Int) {
            guard !closed else { return }
            var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
            // A continuously writing child must not starve cancellation/deadline checks.
            for _ in 0..<16 {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    guard data.count <= limit - count else {
                        failureReason = "Review Git command exceeded the output resource limit."
                        return
                    }
                    data.append(contentsOf: buffer.prefix(count))
                } else if count == 0 { closed = true; return }
                else if errno == EINTR { continue }
                else if errno == EAGAIN { return }
                else { closed = true; return }
            }
        }
        while true {
            drain(outputFD[0], into: &output, closed: &outputClosed, limit: maximumOutputBytes)
            drain(errorFD[0], into: &errors, closed: &errorClosed, limit: min(maximumOutputBytes, 1_024 * 1_024))
            if cancellation.isCancelled { failureReason = "Review Git command cancelled." }
            if ProcessInfo.processInfo.systemUptime >= deadline { failureReason = "Review Git command timed out." }
            if !exited {
                var information = siginfo_t()
                let result = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
                if result == 0 && information.si_pid == pid { exited = true }
                else if result == -1 && errno != EINTR { failureReason = "Could not inspect review Git command." }
            }
            if failureReason != nil || exited {
                // Also kill descendants keeping stdout/stderr alive after the leader exits.
                kill(-pid, SIGKILL)
                // The leader is still unreaped, so its PID/group cannot be reused
                // by an unrelated process between inspection and group termination.
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                exited = true
                drain(outputFD[0], into: &output, closed: &outputClosed, limit: maximumOutputBytes)
                drain(errorFD[0], into: &errors, closed: &errorClosed, limit: min(maximumOutputBytes, 1_024 * 1_024))
                break
            }
            usleep(5_000)
        }
        if let failureReason { return failure(failureReason) }
        guard let outputString = String(data: output, encoding: .utf8),
              let errorString = String(data: errors, encoding: .utf8) else {
            return failure("Review Git command returned unsupported non-UTF-8 text.")
        }
        let exitCode: Int32 = (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : 128 + (status & 0x7f)
        return .init(exitCode: exitCode, standardOutput: outputString, standardError: errorString)
    }
}

private final class ReviewCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
