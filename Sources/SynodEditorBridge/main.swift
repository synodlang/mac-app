import Foundation

// synod-editor-mcp: a stdio MCP server for Claude Code that relays bytes to Synod's editor socket.
// It never interprets MCP. Usage: synod-editor-mcp --socket <path> [--workspace <module root>]
// The token comes from SYNOD_EDITOR_TOKEN, never from argv.

enum Bridge {
    static let refusal = "synod-editor-mcp: Synod is not accepting editor connections"

    static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }

    static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = write(fd, bytes.baseAddress! + off, bytes.count - off)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            off += n
        }
        return true
    }

    static func connectSocket(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if ok != 0 {
            close(fd)
            return nil
        }
        return fd
    }

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    static func main() {
        var socketPath: String?
        var workspace: String?
        var args = CommandLine.arguments.dropFirst()[...]
        while let a = args.popFirst() {
            switch a {
            case "--socket": socketPath = args.popFirst()
            case "--workspace": workspace = args.popFirst()
            default: fail("synod-editor-mcp: unknown argument \(a)", code: 2)
            }
        }
        guard let socketPath else { fail("usage: synod-editor-mcp --socket <path> [--workspace <module root>]", code: 2) }
        signal(SIGPIPE, SIG_IGN)
        guard let token = ProcessInfo.processInfo.environment["SYNOD_EDITOR_TOKEN"], !token.isEmpty else { fail(refusal, code: 1) }
        guard let sock = connectSocket(socketPath) else { fail(refusal, code: 1) }

        let hello = "{\"synodEditorBridge\":1,\"token\":\(jsonString(token)),\"workspace\":\(workspace.map(jsonString) ?? "null")}\n"
        let sent = Array(hello.utf8).withUnsafeBytes { writeAll(sock, $0) }
        if !sent { fail(refusal, code: 1) }

        // Read the answer line (a refusal closes the connection); bytes after it belong to the relay.
        var pending = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 65536)
        var answer: [UInt8]?
        while answer == nil {
            var p = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, 10_000)
            if r == 0 { fail(refusal, code: 1) }
            if r < 0 && errno == EINTR { continue }
            let n = read(sock, &chunk, chunk.count)
            if n <= 0 { fail(refusal, code: 1) }
            pending.append(contentsOf: chunk[0..<n])
            if let nl = pending.firstIndex(of: 10) {
                answer = Array(pending[0..<nl])
                pending.removeSubrange(0...nl)
            } else if pending.count > 1024 {
                fail(refusal, code: 1)
            }
        }
        guard String(decoding: answer!, as: UTF8.self) == "{\"ok\":true}" else { fail(refusal, code: 1) }

        if !pending.isEmpty { _ = pending.withUnsafeBytes { writeAll(1, $0) } }

        // stdin -> socket on a thread; socket -> stdout here. Either side ending ends the process.
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(0, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                if !buf.withUnsafeBytes({ writeAll(sock, UnsafeRawBufferPointer(rebasing: $0[0..<n])) }) { break }
            }
            exit(0)
        }
        while true {
            let n = read(sock, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { exit(0) }
            if !chunk.withUnsafeBytes({ writeAll(1, UnsafeRawBufferPointer(rebasing: $0[0..<n])) }) { exit(0) }
        }
    }
}

Bridge.main()
