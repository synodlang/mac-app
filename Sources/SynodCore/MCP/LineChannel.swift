import Foundation

/// A connected socket read through a DispatchSource, delivering newline-separated lines.
/// End of input or an over-long line closes the channel.
final class LineChannel: @unchecked Sendable {
    let lines: AsyncStream<Data>
    private let fd: Int32
    private let maxLine: Int
    private let continuation: AsyncStream<Data>.Continuation
    private let queue = DispatchQueue(label: "io.github.synodlang.mcp.channel")
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var closed = false
    private var buffer = Data()  // only touched on `queue`

    init(fd: Int32, maxLine: Int) {
        self.fd = fd
        self.maxLine = maxLine
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let made = AsyncStream.makeStream(of: Data.self)
        lines = made.stream
        continuation = made.continuation
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in readAvailable() }
        source.setCancelHandler { [self] in
            Darwin.close(fd)
            continuation.finish()
            source.setEventHandler(handler: nil)
            source.setCancelHandler(handler: nil)
        }
        source.resume()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &chunk, chunk.count)
        if n > 0 {
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 10) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
                if !line.isEmpty { continuation.yield(line) }
            }
            if buffer.count > maxLine { close() }
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            close()
        }
    }

    struct SendFailure: Error {}

    /// Writes `text` plus a newline; throws once the channel is closed or the peer is gone.
    func send(_ text: String) throws {
        let bytes = Array((text + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }
        if closed { throw SendFailure() }
        var off = 0
        var waited = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                off += n
                waited = 0
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&p, 1, 1000)
                waited += 1
                if waited > 10 { throw SendFailure() }
            } else {
                throw SendFailure()
            }
        }
    }

    /// Closes the socket and ends `lines`; safe to call twice and from any thread.
    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        shutdown(fd, SHUT_RDWR)
        source.cancel()
    }
}
