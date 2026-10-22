import Foundation

/// The result of one process run.
public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum RunnerError: Error, Equatable, LocalizedError {
    case launchFailed(String)
    case timedOut(seconds: Double)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let m): return "Could not start synod: \(m)"
        case .timedOut(let s): return "synod did not finish within \(Int(s)) seconds"
        }
    }
}

/// Runs the `synod` binary (or, in tests, `/bin/sh fake-synod.sh`).
///
/// Both output streams are read to the end on background threads, cancellation terminates the
/// process (SIGKILL after one second), and a hard timeout applies.
public actor SynodRunner {
    public let executable: URL
    /// Arguments placed before every call's own, e.g. a script path for `/bin/sh`.
    public let prefixArgs: [String]
    public let timeout: Duration
    private let extraEnvironment: [String: String]

    public init(executable: URL, prefixArgs: [String] = [], timeout: Duration = .seconds(60), environment: [String: String] = [:]) {
        self.executable = executable
        self.prefixArgs = prefixArgs
        self.timeout = timeout
        self.extraEnvironment = environment
    }

    /// Runs `args` in `cwd` and waits for the exit; throws `CancellationError` when the task is
    /// cancelled and `RunnerError.timedOut` after the timeout.
    public func exec(_ args: [String], cwd: URL) async throws -> ProcessResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = prefixArgs + args
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        for (k, v) in extraEnvironment { env[k] = v }
        process.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let box = ProcessBox(process)
        let exited = OneShot<Int32>()
        process.terminationHandler = { p in exited.fulfill(p.terminationStatus) }
        do { try process.run() } catch {
            throw RunnerError.launchFailed(error.localizedDescription)
        }
        let outRead = Self.readAll(outPipe.fileHandleForReading)
        let errRead = Self.readAll(errPipe.fileHandleForReading)

        let limit = timeout
        let timer = Task {
            try await Task.sleep(for: limit)
            box.timedOut = true
            box.terminateThenKill()
        }
        let code = await withTaskCancellationHandler {
            await exited.value
        } onCancel: {
            box.terminateThenKill()
        }
        timer.cancel()
        let out = await outRead.value
        let err = await errRead.value
        if box.timedOut {
            let c = limit.components
            throw RunnerError.timedOut(seconds: Double(c.seconds) + Double(c.attoseconds) / 1e18)
        }
        try Task.checkCancellation()
        return ProcessResult(exitCode: code, stdout: out, stderr: err)
    }

    /// Reads a pipe to EOF on a background thread.
    private static func readAll(_ handle: FileHandle) -> OneShot<Data> {
        let shot = OneShot<Data>()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = (try? handle.readToEnd()) ?? Data()
            shot.fulfill(data)
        }
        return shot
    }
}

/// A Process with a terminate-then-kill helper, shared with the cancellation handler.
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var _timedOut = false

    init(_ p: Process) { process = p }

    var timedOut: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _timedOut }
        set { lock.lock(); _timedOut = newValue; lock.unlock() }
    }

    func terminateThenKill() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// A value delivered once, awaitable from one task.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    private var waiter: CheckedContinuation<T, Never>?

    func fulfill(_ v: T) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: v)
        } else {
            stored = v
            lock.unlock()
        }
    }

    var value: T {
        get async {
            await withCheckedContinuation { c in
                lock.lock()
                if let v = stored {
                    lock.unlock()
                    c.resume(returning: v)
                } else {
                    waiter = c
                    lock.unlock()
                }
            }
        }
    }
}
