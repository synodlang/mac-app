import Foundation

@testable import SynodCore

/// Access to the copied Fixtures folder.
enum Fixtures {
    static let root: URL = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    static func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
    static func data(_ relative: String) throws -> Data { try Data(contentsOf: url(relative)) }
    static func text(_ relative: String) throws -> String { String(decoding: try data(relative), as: UTF8.self) }

    static var fakeSynod: URL { url("fake-synod.sh") }

    /// Fixture examples with a trace, a scene and a summary.
    static let examples = ["raft", "tcp", "twopc"]

    static func trace(_ example: String) throws -> Trace { try Trace.parse(try data("synced/examples/\(example)/trace.jsonl")) }
    static func scene(_ example: String) throws -> SceneSummary { try SceneSummary.parse(try data("synced/examples/\(example)/scene.json")) }
    static func index(_ example: String) throws -> TraceIndex { TraceIndex(trace: try trace(example), scene: try scene(example)) }
}

/// A seeded generator so random tests repeat.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A fresh temp folder (symlinks resolved); the caller removes it.
func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("synodcore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(fileURLWithPath: FileWatcher.realPath(url.path))
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// A module shaped like the examples: 9 programs and the packages raftlook and ringlook.
func makeMiniModule(in dir: URL) throws -> URL {
    try write("module example.com/mini\nsynod 0.2\n", to: dir.appendingPathComponent("synod.mod"))
    for p in ["tcp", "gossip", "paxos", "raft", "ring", "twopc", "cassandra", "webapp", "wal"] {
        try write("# package main\nuse example.com/mini/\(p)\n", to: dir.appendingPathComponent("\(p)/demo.synod"))
        try write("# package \(p)\n", to: dir.appendingPathComponent("\(p)/\(p).synod"))
    }
    for p in ["raftlook", "ringlook"] {
        try write("# package \(p)\n", to: dir.appendingPathComponent("\(p)/\(p).synod"))
    }
    return dir
}

/// A runner that executes fake-synod.sh through /bin/sh.
func fakeRunner(_ mode: String, timeout: Duration = .seconds(30), argsFile: URL? = nil) -> SynodRunner {
    var env = ["FAKE_MODE": mode, "FAKE_FIXTURES": Fixtures.root.path]
    if let argsFile { env["FAKE_ARGS_FILE"] = argsFile.path }
    return SynodRunner(executable: URL(fileURLWithPath: "/bin/sh"), prefixArgs: [Fixtures.fakeSynod.path], timeout: timeout, environment: env)
}

/// Polls until `condition` holds or the timeout passes.
func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

/// Collects values from an async sequence on a background task.
final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
    func add(_ v: T) { lock.lock(); items.append(v); lock.unlock() }
}
