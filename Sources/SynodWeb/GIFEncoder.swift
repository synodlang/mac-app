import Foundation

public enum GIFError: Error, CustomStringConvertible, Equatable {
    case cannotCreate(String)
    case wrongSize(expected: String, got: String)
    case badOption(String)
    case tooManyFrames(count: Int, limit: Int)
    case noFrames
    case finished
    case cancelled

    public var description: String {
        switch self {
        case .cannotCreate(let m): return "cannot create GIF: \(m)"
        case .wrongSize(let e, let g): return "GIF frame is \(g), expected \(e)"
        case .badOption(let m): return "bad GIF option: \(m)"
        case .tooManyFrames(let c, let l):
            return "a GIF holds at most \(l) frames; this export would need \(c). Choose a shorter range or a lower frame rate."
        case .noFrames: return "no frames to write"
        case .finished: return "GIF already finished"
        case .cancelled: return "export cancelled"
        }
    }
}

/// Frame rates, widths and the frame limit of a GIF export (decision 88).
public enum GIFLimits {
    public static let frameRates = [10, 20, 25, 50]
    public static let widths = [480, 640, 800, 960]
    public static let maxFrames = 6000
    public static let defaultFrameRate = 20
    public static let defaultWidth = 640

    /// The delay of every frame, in hundredths of a second (100 / fps: 10, 5, 4 or 2).
    public static func delay(fps: Int) -> Int { 100 / fps }

    /// round(W * canvas.h / canvas.w), at least 1.
    public static func height(width: Int, canvasWidth: Double, canvasHeight: Double) -> Int {
        guard canvasWidth > 0 else { return max(1, width * 5 / 8) }
        return max(1, Int((Double(width) * canvasHeight / canvasWidth).rounded()))
    }

    /// A rough size estimate for the sheet: a full first frame plus the changed rectangles.
    /// Calibrated on Raft at 640x400 (about 1.1 KB per frame, 130 KB for 120 frames); tcp, which
    /// is quiet, comes out at a third of that. The real size varies with the scene.
    public static func estimatedBytes(width: Int, height: Int, frames: Int) -> Int {
        let pixels = width * height
        return pixels / 40 + max(0, frames - 1) * (pixels / 250) + 800
    }
}

/// A streaming GIF89a writer. Frames arrive as palette indices or BGRA images; each is written as it
/// comes, so memory does not depend on the length. Output goes to `<url>.partial` and is moved to
/// `url` by `finish()`; `cancel()` deletes the partial file. The same input gives the same bytes.
public actor GIFEncoder {
    public let url: URL
    public let width: Int
    public let height: Int
    public let delay: Int            // hundredths of a second
    public let palette: GIFPalette
    public private(set) var frameCount = 0

    private let partial: URL
    private let handle: FileHandle
    private var quantizer: GIFQuantizer
    private var previous: [UInt8]?
    private var done = false

    public init(url: URL, width: Int, height: Int, fps: Int, palette: GIFPalette) throws {
        guard width > 0, height > 0, width < 65536, height < 65536 else { throw GIFError.badOption("size \(width)x\(height)") }
        guard fps > 0, fps <= 100 else { throw GIFError.badOption("fps \(fps)") }
        self.url = url
        self.width = width
        self.height = height
        self.delay = 100 / fps
        self.palette = palette
        quantizer = GIFQuantizer(palette: palette)
        partial = url.appendingPathExtension("partial")
        let fm = FileManager.default
        try? fm.removeItem(at: partial)
        guard fm.createFile(atPath: partial.path, contents: nil), let h = try? FileHandle(forWritingTo: partial)
        else { throw GIFError.cannotCreate(partial.path) }
        handle = h
        try Self.header(width: width, height: height, palette: palette).write(to: h)
    }

    /// Quantizes and appends a frame.
    public func append(image: BGRAImage) throws {
        guard image.width == width, image.height == height else {
            throw GIFError.wrongSize(expected: "\(width)x\(height)", got: "\(image.width)x\(image.height)")
        }
        try append(indices: quantizer.indices(of: image))
    }

    /// Decodes a PNG and appends it.
    public func append(png: Data) throws {
        try append(image: try PixelBuffers.decodePNG(png))
    }

    /// Appends a frame of palette indices (row-major, width x height).
    public func append(indices: [UInt8]) throws {
        guard !done else { throw GIFError.finished }
        precondition(indices.count == width * height)
        var rect = (x: 0, y: 0, w: width, h: height)
        var pixels = indices
        if let prev = previous {
            rect = Self.changedRect(prev, indices, width: width, height: height)
            if rect.w == 0 {
                // Identical frame: a 1x1 rectangle repeating the pixel that is already there.
                rect = (0, 0, 1, 1)
                pixels = [prev[0]]
            } else {
                pixels = Self.crop(indices, width: width, rect: rect)
            }
        }
        var out = Data()
        // Graphic Control Extension: disposal 1 (leave in place), no transparency.
        out.append(contentsOf: [0x21, 0xF9, 0x04, 0x04, UInt8(delay & 255), UInt8(delay >> 8), 0x00, 0x00])
        out.append(0x2C)
        out.append(le16(rect.x)); out.append(le16(rect.y)); out.append(le16(rect.w)); out.append(le16(rect.h))
        out.append(0x00)           // no local table, not interlaced
        out.append(8)              // minimum LZW code size
        out.append(LZW.encode(pixels))
        try handle.write(contentsOf: out)
        previous = indices
        frameCount += 1
    }

    /// Writes the trailer and moves the file into place.
    public func finish() throws {
        guard !done else { throw GIFError.finished }
        guard frameCount > 0 else { cancel(); throw GIFError.noFrames }
        done = true
        try handle.write(contentsOf: Data([0x3B]))
        try handle.close()
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try fm.moveItem(at: partial, to: url)
    }

    /// Deletes the partial file.
    public func cancel() {
        guard !done else { return }
        done = true
        try? handle.close()
        try? FileManager.default.removeItem(at: partial)
    }

    // MARK: Pure parts

    static func header(width: Int, height: Int, palette: GIFPalette) -> Data {
        var d = Data("GIF89a".utf8)
        d.append(le16(width)); d.append(le16(height))
        d.append(0xF7)             // global table, 8-bit color resolution, 256 entries
        d.append(0)                // background index
        d.append(0)                // aspect ratio
        for i in 0..<256 {
            let c = i < palette.colors.count ? palette.colors[i] : palette.colors[0]
            d.append(contentsOf: [c.r, c.g, c.b])
        }
        // NETSCAPE2.0: loop forever.
        d.append(contentsOf: [0x21, 0xFF, 0x0B])
        d.append(Data("NETSCAPE2.0".utf8))
        d.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
        return d
    }

    /// The bounding rectangle of the pixels that differ (w == 0 when none).
    static func changedRect(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) -> (x: Int, y: Int, w: Int, h: Int) {
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where a[row + x] != b[row + x] {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                maxY = y
            }
        }
        if maxX < 0 { return (0, 0, 0, 0) }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    static func crop(_ p: [UInt8], width: Int, rect: (x: Int, y: Int, w: Int, h: Int)) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(rect.w * rect.h)
        for y in rect.y..<(rect.y + rect.h) {
            let s = y * width + rect.x
            out.append(contentsOf: p[s..<(s + rect.w)])
        }
        return out
    }
}

private func le16(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8((v >> 8) & 255)]) }

private extension Data {
    func write(to handle: FileHandle) throws { try handle.write(contentsOf: self) }
}

/// GIF LZW with minimum code size 8, codes up to 12 bits, and a clear code when the table fills.
/// Returns the data sub-blocks including the zero terminator.
enum LZW {
    static func encode(_ pixels: [UInt8]) -> Data {
        let clear = 256, eoi = 257
        var bits = BitPacker()
        // Hash table keyed by (prefix << 8 | byte), open addressing.
        let hsize = 16384
        var keys = [Int32](repeating: -1, count: hsize)
        var vals = [UInt16](repeating: 0, count: hsize)
        var codeSize = 9
        var next = 258

        func reset() {
            for i in 0..<hsize { keys[i] = -1 }
        }
        func lookup(_ key: Int32) -> (found: UInt16?, slot: Int) {
            var h = Int((UInt32(bitPattern: key) &* 2654435761) >> 18) & (hsize - 1)
            while keys[h] != -1 {
                if keys[h] == key { return (vals[h], h) }
                h = (h + 1) & (hsize - 1)
            }
            return (nil, h)
        }

        bits.put(clear, codeSize)
        guard var prefix = pixels.first.map({ Int($0) }) else {
            bits.put(eoi, codeSize)
            return bits.finish()
        }
        for p in pixels.dropFirst() {
            let c = Int(p)
            let key = Int32(prefix << 8 | c)
            let r = lookup(key)
            if let code = r.found { prefix = Int(code); continue }
            bits.put(prefix, codeSize)
            if next > (1 << codeSize) - 1 && codeSize < 12 { codeSize += 1 }
            if next < 4096 {
                keys[r.slot] = key
                vals[r.slot] = UInt16(next)
                next += 1
            } else {
                bits.put(clear, codeSize)
                reset()
                codeSize = 9
                next = 258
            }
            prefix = c
        }
        bits.put(prefix, codeSize)
        if next > (1 << codeSize) - 1 && codeSize < 12 { codeSize += 1 }
        bits.put(eoi, codeSize)
        return bits.finish()
    }

    struct BitPacker {
        private var acc: UInt32 = 0
        private var n = 0
        private var block: [UInt8] = []
        private var out = Data()

        mutating func put(_ code: Int, _ size: Int) {
            acc |= UInt32(code) << UInt32(n)
            n += size
            while n >= 8 {
                emit(UInt8(acc & 255))
                acc >>= 8
                n -= 8
            }
        }

        private mutating func emit(_ byte: UInt8) {
            block.append(byte)
            if block.count == 255 { flush() }
        }

        private mutating func flush() {
            guard !block.isEmpty else { return }
            out.append(UInt8(block.count))
            out.append(contentsOf: block)
            block.removeAll(keepingCapacity: true)
        }

        mutating func finish() -> Data {
            if n > 0 { emit(UInt8(acc & 255)); acc = 0; n = 0 }
            flush()
            out.append(0)
            return out
        }
    }
}
