import Foundation

/// The per-process editor socket: `$TMPDIR/synod-mcp-<8 hex>/editor.sock`, folder 0700, socket 0600.
/// It exists only while at least one holder (a prompt-bar request or the external setting) has `acquire`d it.
/// POSIX sockets and DispatchSource only; there is no IP listener.
public actor UnixSocketListener {
    public enum ListenerError: Error, Equatable {
        case pathTooLong(Int)
        case posix(String, Int32)
    }

    private let authority: any BridgeAuthority
    private let baseDirectory: URL
    private let handshakeTimeout: Duration
    private var holders = 0
    private var folder: URL?
    private var socketPath: String?
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [UUID: (channel: LineChannel, token: String?)] = [:]

    /// `baseDirectory` defaults to the per-user temporary directory.
    public init(authority: any BridgeAuthority, baseDirectory: URL? = nil, handshakeTimeout: Duration = .seconds(5)) {
        self.authority = authority
        self.baseDirectory = baseDirectory ?? FileManager.default.temporaryDirectory
        self.handshakeTimeout = handshakeTimeout
    }

    public var isListening: Bool { acceptSource != nil }
    public var socketURL: URL? { socketPath.map { URL(fileURLWithPath: $0) } }
    public var folderURL: URL? { folder }
    public var connectionCount: Int { connections.count }

    /// Takes a hold on the listener, starting it when it is not running. Returns the socket URL.
    @discardableResult
    public func acquire() throws -> URL {
        if holders == 0 || acceptSource == nil { try start() }
        holders += 1
        return URL(fileURLWithPath: socketPath!)
    }

    /// Drops one hold. With none left, closes every connection and removes the socket and its folder.
    public func release() {
        guard holders > 0 else { return }
        holders -= 1
        if holders == 0 { stop() }
    }

    /// Closes the connections that logged in with `token` (call after revoking it).
    public func closeConnections(token: String) {
        for (id, c) in connections where c.token.map({ BridgeHandshake.constantTimeEquals($0, token) }) == true {
            c.channel.close()
            connections[id] = nil
        }
    }

    public func closeAllConnections() {
        for (_, c) in connections { c.channel.close() }
        connections.removeAll()
    }

    // MARK: Start and stop

    private func start() throws {
        stop()
        var suffix = [UInt8](repeating: 0, count: 4)
        for i in suffix.indices { suffix[i] = UInt8.random(in: 0...255) }
        let hex = suffix.map { String(format: "%02x", $0) }.joined()
        let dir = baseDirectory.appendingPathComponent("synod-mcp-\(hex)", isDirectory: true)
        let path = dir.appendingPathComponent("editor.sock").path
        guard path.utf8.count < 104 else { throw ListenerError.pathTooLong(path.utf8.count) }
        guard mkdir(dir.path, 0o700) == 0 else { throw ListenerError.posix("mkdir", errno) }
        chmod(dir.path, 0o700)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            let e = errno
            rmdir(dir.path)
            throw ListenerError.posix("socket", e)
        }
        func fail(_ what: String) -> ListenerError {
            let e = errno
            Darwin.close(fd)
            unlink(path)
            rmdir(dir.path)
            return .posix(what, e)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8)
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw fail("bind") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { throw fail("listen") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "io.github.synodlang.mcp.accept"))
        src.setEventHandler { [weak self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { break }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(c, &uid, &gid) == 0, uid == geteuid() else {
                    Darwin.close(c)
                    continue
                }
                Task { await self?.accepted(c) }
            }
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        listenFD = fd
        acceptSource = src
        folder = dir
        socketPath = path
    }

    private func stop() {
        closeAllConnections()
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        if let socketPath { unlink(socketPath) }
        if let folder { try? FileManager.default.removeItem(at: folder) }
        socketPath = nil
        folder = nil
    }

    // MARK: Connections

    private func accepted(_ fd: Int32) async {
        let channel = LineChannel(fd: fd, maxLine: 4 * 1024 * 1024)
        guard acceptSource != nil else {
            channel.close()
            return
        }
        let id = UUID()
        connections[id] = (channel, nil)
        await serve(id: id, channel: channel)
        channel.close()
        connections[id] = nil
    }

    private func serve(id: UUID, channel: LineChannel) async {
        var it = channel.lines.makeAsyncIterator()
        let timeout = handshakeTimeout
        let timer = Task {
            try await Task.sleep(for: timeout)
            channel.close()
        }
        let first = await it.next()
        timer.cancel()
        guard let first, first.count <= 4096,
            let handshake = BridgeHandshake.parse(line: String(decoding: first, as: UTF8.self)),
            let grant = await authority.authorize(handshake)
        else { return }
        connections[id] = (channel, handshake.token)
        guard (try? channel.send(BridgeHandshake.okLine)) != nil else { return }

        let server = MCPServer(name: grant.serverName, version: grant.serverVersion, tools: grant.tools)
        await withTaskGroup(of: Void.self) { group in
            while let data = await it.next() {
                let line = String(decoding: data, as: UTF8.self)
                group.addTask {
                    if let response = await server.handle(line: line) { try? channel.send(response) }
                }
            }
            await server.cancelAll()
        }
    }
}
