import Foundation

/// The placeholder ranges of an inserted phrase (decision 92, plan 4.3). Tab and Shift-Tab cycle,
/// typing inside a range fills it (the range follows the typing), and an edit outside every
/// range, or one that straddles a range edge, clears the set. Ranges are UTF-16 ranges.
public struct PlaceholderSet: Sendable, Equatable {
    public private(set) var ranges: [NSRange]
    /// The range typing goes into, once one is selected.
    public private(set) var current: Int?
    private var filled: Set<Int> = []

    public init(ranges: [NSRange] = []) { self.ranges = ranges }

    public var isEmpty: Bool { ranges.isEmpty }

    /// The ranges still holding their hole's name, for drawing.
    public var unfilledRanges: [NSRange] {
        ranges.enumerated().filter { !filled.contains($0.offset) }.map(\.element)
    }

    /// Selects and returns the first range.
    public mutating func selectFirst() -> NSRange? {
        guard !ranges.isEmpty else { return nil }
        current = 0
        return ranges[0]
    }

    /// Moves to the next range, wrapping; returns it.
    public mutating func next() -> NSRange? {
        guard !ranges.isEmpty else { return nil }
        current = ((current ?? -1) + 1) % ranges.count
        return ranges[current!]
    }

    /// Moves to the previous range, wrapping; returns it.
    public mutating func previous() -> NSRange? {
        guard !ranges.isEmpty else { return nil }
        current = ((current ?? ranges.count) - 1 + ranges.count) % ranges.count
        return ranges[current!]
    }

    public mutating func clear() {
        ranges = []
        current = nil
        filled = []
    }

    /// Follows an edit: `range` of the buffer was replaced by `replacementLength` UTF-16 units.
    /// An edit inside a range (or an insertion at its end) fills it and resizes it, the ranges
    /// after it shift, and the ones before stay. Any other edit clears the set. Returns true
    /// when the set is kept.
    @discardableResult
    public mutating func apply(replacing range: NSRange, withLength replacementLength: Int) -> Bool {
        guard !ranges.isEmpty else { return false }
        let a = range.location
        let b = a + range.length
        let delta = replacementLength - range.length
        guard let hit = ranges.firstIndex(where: { a >= $0.location && b <= $0.location + $0.length }) else {
            clear()
            return false
        }
        ranges[hit].length += delta
        for i in (hit + 1)..<ranges.count { ranges[i].location += delta }
        filled.insert(hit)
        current = hit
        return true
    }
}
