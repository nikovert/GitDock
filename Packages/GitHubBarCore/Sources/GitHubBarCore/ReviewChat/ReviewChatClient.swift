import Darwin
import Foundation

/// One bounded, advisory JSON exchange per process. No shell or GitHub transport is used.
public struct ReviewChatClient: ReviewChatServicing {
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int
    private let maximumErrorBytes: Int
    private let maximumRequestBytes: Int

    public init(timeout: TimeInterval = 120, maximumOutputBytes: Int = 1_048_576,
                maximumErrorBytes: Int = 65_536, maximumRequestBytes: Int = 1_048_576) {
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumErrorBytes = maximumErrorBytes
        self.maximumRequestBytes = maximumRequestBytes
    }

    public func send(_ request: ReviewChatRequest,
                     configuration: ReviewChatConfiguration) async throws -> ReviewChatResponse {
        try Task.checkCancellation()
        try configuration.validated()
        guard timeout.isFinite, timeout > 0, maximumOutputBytes > 0,
              maximumErrorBytes > 0, maximumRequestBytes > 0 else {
            throw ReviewChatError.invalidConfiguration("Chat timeout and byte limits must be positive and finite.")
        }
        let input = try JSONEncoder().encode(request)
        guard input.count <= maximumRequestBytes else { throw ReviewChatError.requestLimitExceeded }
        let output = try await exchange(input, configuration: configuration)
        try Task.checkCancellation()
        guard let response = try? JSONDecoder().decode(ReviewChatResponse.self, from: output),
              !response.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              response.citations.allSatisfy(\.isValid) else {
            throw ReviewChatError.invalidResponse
        }
        guard response.prURL == request.prURL, response.headSHA == request.headSHA else {
            throw ReviewChatError.mismatchedResponse
        }
        if request.task == .review && response.findings == nil {
            throw ReviewChatError.invalidResponse
        }
        if let findings = response.findings, !ReviewAgentFinding.areValid(findings) {
            throw ReviewChatError.invalidResponse
        }
        return response
    }

    private func exchange(_ input: Data, configuration: ReviewChatConfiguration) async throws -> Data {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let handles = [stdin.fileHandleForReading, stdin.fileHandleForWriting,
                       stdout.fileHandleForReading, stdout.fileHandleForWriting,
                       stderr.fileHandleForReading, stderr.fileHandleForWriting]
        var ownedProcessGroup: Int32?
        defer {
            // Foundation launches a separate process group on macOS. Only signal a group
            // after verifying ownership, so the app's own process group is never targeted.
            if let group = ownedProcessGroup { kill(-group, SIGKILL) }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            for handle in handles { try? handle.close() }
        }
        process.executableURL = URL(fileURLWithPath: configuration.executable)
        process.arguments = configuration.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.workingDirectory)
        process.environment = Self.adapterEnvironment()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let inputFD = stdin.fileHandleForWriting.fileDescriptor
        let outputFD = stdout.fileHandleForReading.fileDescriptor
        let errorFD = stderr.fileHandleForReading.fileDescriptor
        for fd in [inputFD, outputFD, errorFD] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw ReviewChatError.ioFailed
            }
        }
        // A child closing stdin must become an error, never a SIGPIPE in the app.
        guard fcntl(inputFD, F_SETNOSIGPIPE, 1) >= 0 else { throw ReviewChatError.ioFailed }
        try Task.checkCancellation()
        do { try process.run() }
        catch { throw ReviewChatError.launchFailed }
        let pid = process.processIdentifier
        if getpgid(pid) == pid { ownedProcessGroup = pid }
        do {
            try stdin.fileHandleForReading.close()
            try stdout.fileHandleForWriting.close()
            try stderr.fileHandleForWriting.close()

            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            var inputOffset = 0
            var inputClosed = false
            var outputClosed = false
            var errorClosed = false
            var output = Data()
            var errorBytes = 0
            var diagnostics = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)

            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw ReviewChatError.timedOut }
                var madeProgress = false
                if !inputClosed {
                    let count = input.withUnsafeBytes { bytes in
                        Darwin.write(inputFD, bytes.baseAddress!.advanced(by: inputOffset),
                                     min(8192, input.count - inputOffset))
                    }
                    if count >= 0 {
                        inputOffset += count
                        madeProgress = count > 0
                    } else if errno == EPIPE {
                        inputClosed = true
                    } else if errno != EAGAIN && errno != EINTR {
                        throw ReviewChatError.ioFailed
                    }
                    if inputClosed || inputOffset == input.count {
                        try stdin.fileHandleForWriting.close()
                        inputClosed = true
                    }
                }
                if !outputClosed {
                    let count = try Self.read(outputFD, into: &buffer)
                    if count > 0 {
                        guard count <= maximumOutputBytes - output.count else {
                            throw ReviewChatError.outputLimitExceeded
                        }
                        output.append(contentsOf: buffer.prefix(count))
                        madeProgress = true
                    } else if count == 0 { outputClosed = true }
                }
                if !errorClosed {
                    let count = try Self.read(errorFD, into: &buffer)
                    if count > 0 {
                        guard count <= maximumErrorBytes - errorBytes else {
                            throw ReviewChatError.errorLimitExceeded
                        }
                        errorBytes += count
                        diagnostics.append(contentsOf: buffer.prefix(count))
                        madeProgress = true
                    } else if count == 0 { errorClosed = true }
                }
                if !process.isRunning && outputClosed && errorClosed { break }
                // Nonblocking I/O keeps backpressure, inherited child pipes, and floods cancellable.
                if !madeProgress { try await Task.sleep(for: .milliseconds(10)) }
            }
            guard process.terminationStatus == 0 else {
                if let failure = Self.knownAdapterFailure(diagnostics) { throw ReviewChatError.adapterFailed(failure) }
                throw ReviewChatError.processFailed(process.terminationStatus)
            }
            guard inputOffset == input.count else { throw ReviewChatError.inputClosed }
            return output
        } catch {
            await Self.stop(process, processGroup: ownedProcessGroup)
            throw error
        }
    }

    private static func knownAdapterFailure(_ data: Data) -> ReviewChatAdapterFailure? {
        let prefix = "GITHUBBAR_ADAPTER_ERROR_V1:"
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() where line.hasPrefix(prefix) {
            let payload = Data(line.dropFirst(prefix.count).utf8)
            guard payload.count <= 256,
                  let record = try? JSONDecoder().decode([String: String].self, from: payload),
                  record.count == 1, let code = record["code"] else { return nil }
            return ReviewChatAdapterFailure(rawValue: code)
        }
        return nil
    }

    private static func stop(_ process: Process, processGroup: Int32?) async {
        if let group = processGroup { kill(-group, SIGKILL) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while process.isRunning && ContinuousClock.now < deadline {
            // waitUntilExit can strand an executor thread in Foundation's run loop after
            // the child has exited. A cancelled Task.sleep would also skip this delay.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10)) {
                    continuation.resume()
                }
            }
        }
    }

    private static func read(_ fd: Int32, into buffer: inout [UInt8]) throws -> Int {
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count >= 0 || errno == EAGAIN || errno == EINTR else { throw ReviewChatError.ioFailed }
        return count
    }

    private static func adapterEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment = inherited.filter { ["HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"].contains($0.key) }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return environment
    }
}
