import Foundation

@testable import SynodCore

/// An in-memory editor for the MCP tests.
actor MockEditor: EditorService {
    var calls: [String] = []
    var waitForCancel = false
    private(set) var sawCancellation = false
    var version = 3

    func setWaitForCancel(_ v: Bool) { waitForCancel = v }

    func listFiles() async throws -> [EditorFileInfo] {
        calls.append("list_files")
        return [EditorFileInfo(path: "a.synod", open: true, dirty: true, readOnly: false, version: version)]
    }

    func readBuffer(path: String, startLine: Int?, endLine: Int?) async throws -> EditorBufferSlice {
        calls.append("read_buffer")
        if path.hasPrefix("..") { throw EditorToolError(.outsideModule, "\(path) is outside the module") }
        if path == "missing.synod" { throw EditorToolError(.notFound, path) }
        return EditorBufferSlice(path: path, version: version, dirty: true, readOnly: false, lineCount: 2, startLine: startLine ?? 1, endLine: endLine ?? 2, text: "one\ntwo\n")
    }

    func diagnostics(path: String?, fresh: Bool) async throws -> EditorDiagnosticsResult {
        calls.append("get_diagnostics fresh=\(fresh)")
        if waitForCancel {
            do { try await Task.sleep(for: .seconds(30)) } catch {
                sawCancellation = true
                throw CancellationError()
            }
        }
        return EditorDiagnosticsResult(
            stale: false, diagnostics: [EditorDiagnostic(path: "a.synod", line: 1, col: 2, endLine: 1, endCol: 5, severity: "error", code: "unknown-phrase", message: "m", hint: nil)])
    }

    func selection() async throws -> EditorSelectionInfo {
        calls.append("get_selection")
        return EditorSelectionInfo(path: nil, version: nil, caret: nil, selections: [])
    }

    func applyEdits(path: String, version v: Int, edits: [EditorTextEdit]) async throws -> EditorEditResult {
        calls.append("apply_edits \(edits.count)")
        if v != version { throw EditorToolError(.versionMismatch, "buffer is at version \(version); read it again") }
        version += 1
        return EditorEditResult(path: path, version: version)
    }

    func replaceBuffer(path: String, version v: Int, text: String) async throws -> EditorEditResult {
        calls.append("replace_buffer")
        throw EditorToolError(.readOnly, "bundled examples; copy them to a folder first")
    }

    func createFile(path: String, text: String) async throws -> EditorCreateResult {
        calls.append("create_file")
        return EditorCreateResult(path: path, version: 1, formatted: true)
    }

    func saveFiles(paths: [String]) async throws -> EditorSaveResult {
        calls.append("save_files")
        return EditorSaveResult(saved: paths.map { EditorSavedFile(path: $0, version: version, formatted: true) }, failed: [])
    }

    func openFile(path: String, line: Int?, col: Int?) async throws -> String {
        calls.append("open_file")
        return path
    }
}

/// Finds a built executable product next to the test bundle.
func builtProduct(_ name: String) -> URL? {
    var dir = Bundle.module.bundleURL
    for _ in 0..<6 {
        dir = dir.deletingLastPathComponent()
        let u = dir.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: u.path) { return u }
    }
    return nil
}

/// A blocking line client on a connected Unix socket (for tests).
final class TestSocket: @unchecked Sendable {
    let fd: Int32
    private var buffer = Data()

    init?(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in Array(path.utf8).enumerated() { raw[i] = b }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if ok != 0 {
            Darwin.close(fd)
            return nil
        }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func send(_ line: String) { _ = Array((line + "\n").utf8).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } }

    /// The next line, or nil on end of stream or timeout.
    func readLine() async -> String? {
        await offPool { self.readLineBlocking() }
    }

    private func readLineBlocking() -> String? {
        while true {
            if let nl = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    func close() { Darwin.close(fd) }
}

func posixMode(_ path: String) -> Int? {
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    return Int(st.st_mode & 0o777)
}

func shortTempDir() throws -> URL {
    let url = URL(fileURLWithPath: "/tmp/sm-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct SingleGrantAuthority: BridgeAuthority {
    let token: String
    let editor: MockEditor
    func authorize(_ h: BridgeHandshake) async -> BridgeGrant? {
        guard BridgeHandshake.constantTimeEquals(h.token, token) else { return nil }
        return BridgeGrant(tools: EditorToolRegistry(service: editor), serverVersion: "0.0.1")
    }
}

/// Runs blocking work on a dispatch thread so it never starves the cooperative pool the listener runs on.
func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in DispatchQueue.global().async { c.resume(returning: work()) } }
}
