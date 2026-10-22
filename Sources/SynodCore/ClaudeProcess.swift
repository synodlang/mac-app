import Foundation

/// Runs one `claude` process with an explicit environment (the allowlist, nothing inherited),
/// streams stdout line by line, collects stderr, and stops it by SIGINT, then SIGTERM, then SIGKILL.
public actor ClaudeProcess {
    public struct Exit: Sendable, Equatable {
        public let status: Int32
        public let stderr: String
        /// `stop()` was called (or the task was cancelled).
        public let stopped: Bool
        public let timedOut: Bool
    }

    public struct StopTiming: Sendable, Equatable {
        public var sigtermAfter: Duration
        public var sigkillAfter: Duration
        public init(sigtermAfter: Duration = .seconds(3), sigkillAfter: Duration = .seconds(2)) {
            self.sigtermAfter = sigtermAfter
            self.sigkillAfter = sigkillAfter
        }
    }

    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL
    public let timeout: Duration
    public let stopTiming: StopTiming

    private var process: Process?
    private var stopRequested = false
    private var timedOut = false
    private var started = false

    public init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL,
                timeout: Duration = .seconds(1800), stopTiming: StopTiming = StopTiming()) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.stopTiming = stopTiming
    }

    public init(_ invocation: ClaudeInvocation, timeout: Duration = .seconds(1800), stopTiming: StopTiming = StopTiming()) {
        self.init(executable: invocation.claude, arguments: invocation.arguments, environment: invocation.environment,
                  workingDirectory: invocation.workingDirectory, timeout: timeout, stopTiming: stopTiming)
    }

    /// Starts the process and returns when it has exited and stdout is drained. `onLine` gets
    /// each complete stdout line in order. Throws `RunnerError.launchFailed`. Cancelling the
    /// calling task is the same as `stop()`.
    public func run(onLine: @escaping @Sendable (String) -> Void) async throws -> Exit {
        precondition(!started, "ClaudeProcess runs once")
        started = true
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.currentDirectoryURL = workingDirectory
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let lines = LineBuffer(onLine)
        let outDone = Latch()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                lines.finish()
                outDone.fulfill()
            } else {
                lines.append(d)
            }
        }
        let errBox = TailBuffer(limit: 64 * 1024)
        let errDone = Latch()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                errDone.fulfill()
            } else {
                errBox.append(d)
            }
        }
        let exited = StatusLatch()
        p.terminationHandler = { exited.fulfill($0.terminationStatus) }
        do { try p.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            throw RunnerError.launchFailed(error.localizedDescription)
        }
        process = p

        let limit = timeout
        let timer = Task { [weak self] in
            try await Task.sleep(for: limit)
            await self?.timeoutFired()
        }
        let status = await withTaskCancellationHandler {
            await exited.value
        } onCancel: {
            Task { await self.stop() }
        }
        timer.cancel()
        // Grandchildren can keep the pipes open; do not wait for them for long.
        await outDone.wait(upTo: .seconds(1))
        await errDone.wait(upTo: .seconds(1))
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        lines.finish()
        process = nil
        return Exit(status: status, stderr: errBox.text, stopped: stopRequested, timedOut: timedOut)
    }

    private func timeoutFired() {
        timedOut = true
        stop()
    }

    /// SIGINT now, SIGTERM after `sigtermAfter`, SIGKILL after `sigkillAfter` more, each only
    /// while the process is still running. Safe to call more than once.
    public func stop() {
        guard let p = process, p.isRunning, !stopRequested else { return }
        stopRequested = true
        let pid = p.processIdentifier
        kill(pid, SIGINT)
        let timing = stopTiming
        Task.detached {
            try? await Task.sleep(for: timing.sigtermAfter)
            guard p.isRunning else { return }
            kill(pid, SIGTERM)
            try? await Task.sleep(for: timing.sigkillAfter)
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }
}

private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let sink: @Sendable (String) -> Void

    init(_ sink: @escaping @Sendable (String) -> Void) { self.sink = sink }

    func append(_ d: Data) {
        var complete: [String] = []
        lock.lock()
        pending.append(d)
        while let nl = pending.firstIndex(of: 0x0A) {
            complete.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        lock.unlock()
        for l in complete { sink(l) }
    }

    func finish() {
        lock.lock()
        let rest = pending
        pending = Data()
        lock.unlock()
        if !rest.isEmpty { sink(String(decoding: rest, as: UTF8.self)) }
    }
}

private final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func append(_ d: Data) {
        lock.lock()
        data.append(d)
        if data.count > limit { data = data.suffix(limit) }
        lock.unlock()
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A one-time signal that can be awaited with a time limit.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextID = 0

    func fulfill() {
        lock.lock()
        done = true
        let w = waiters
        waiters = [:]
        lock.unlock()
        w.values.forEach { $0.resume() }
    }

    private func release(_ id: Int) {
        lock.lock()
        let c = waiters.removeValue(forKey: id)
        lock.unlock()
        c?.resume()
    }

    /// Returns when fulfilled or after `limit`, whichever is first.
    func wait(upTo limit: Duration) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if done { lock.unlock(); c.resume(); return }
            let id = nextID
            nextID += 1
            waiters[id] = c
            lock.unlock()
            Task { [weak self] in
                try? await Task.sleep(for: limit)
                self?.release(id)
            }
        }
    }
}

private final class StatusLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?

    func fulfill(_ s: Int32) {
        lock.lock()
        if let w = waiter { waiter = nil; lock.unlock(); w.resume(returning: s) } else { status = s; lock.unlock() }
    }

    var value: Int32 {
        get async {
            await withCheckedContinuation { c in
                lock.lock()
                if let s = status { lock.unlock(); c.resume(returning: s) } else { waiter = c; lock.unlock() }
            }
        }
    }
}
