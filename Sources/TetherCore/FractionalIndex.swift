// Fractional indexing: position keys are base-62 fractions, compared as plain strings.
// Inserting between two keys makes a new key strictly between them, so moving an item
// only rewrites that item's position.

public enum FractionalIndexError: Error, Equatable {
    case invalidKey(String)
    case keysOutOfOrder(String, String)
}

public enum FractionalIndex {
    // ASCII order, so byte comparison of keys matches digit comparison.
    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)

    /// A key strictly between `lower` and `upper`; nil means the start or end of the list.
    public static func between(_ lower: String?, _ upper: String?) throws -> String {
        let low = try lower.map(digitValues) ?? []
        let high = try upper.map(digitValues)
        if let high, let lower, let upper, !low.lexicographicallyPrecedes(high) {
            throw FractionalIndexError.keysOutOfOrder(lower, upper)
        }
        let key: [UInt8]
        switch (lower, high) {
        case (.some, nil): key = after(low[...])
        case (nil, .some(let high)): key = before(high[...])
        default: key = midpoint(low[...], high?[...])
        }
        return String(decoding: key.map { digits[Int($0)] }, as: UTF8.self)
    }

    // Appending and prepending step one digit instead of halving, so keys grow by about
    // one character per 30 inserts at an end rather than one per 5.
    private static func after(_ low: ArraySlice<UInt8>) -> [UInt8] {
        guard let first = low.first else { return midpoint([], nil) }
        let last = UInt8(digits.count - 1)
        return first < last ? [first + 1] : [last] + after(low.dropFirst())
    }

    private static func before(_ high: ArraySlice<UInt8>) -> [UInt8] {
        switch high[high.startIndex] {
        case 0: return [0] + before(high.dropFirst())
        case 1: return [0] + midpoint([], nil)
        case let first: return [first - 1]
        }
    }

    /// Sorts items by position, breaking ties (same key made concurrently) by item id.
    public static func sorted<ID: Comparable>(_ items: [(id: ID, position: String)]) -> [ID] {
        items.sorted { $0.position != $1.position ? $0.position < $1.position : $0.id < $1.id }
            .map(\.id)
    }

    private static func digitValues(_ key: String) throws -> [UInt8] {
        let values = try key.utf8.map { byte in
            guard let index = digits.firstIndex(of: byte) else {
                throw FractionalIndexError.invalidKey(key)
            }
            return UInt8(index)
        }
        // A trailing zero digit would leave no room below the key.
        guard let last = values.last, last != 0 else { throw FractionalIndexError.invalidKey(key) }
        return values
    }

    // After David Greenspan's fractional-indexing midpoint: copy the shared prefix, then pick
    // a digit between the first differing ones, or extend if they are adjacent.
    private static func midpoint(_ low: ArraySlice<UInt8>, _ high: ArraySlice<UInt8>?) -> [UInt8] {
        if let high {
            var shared = 0
            while shared < high.count,
                (shared < low.count ? low[low.startIndex + shared] : 0)
                    == high[high.startIndex + shared]
            {
                shared += 1
            }
            if shared > 0 {
                return Array(high.prefix(shared))
                    + midpoint(low.dropFirst(shared), high.dropFirst(shared))
            }
        }
        let lowDigit = Int(low.first ?? 0)
        let highDigit = high?.first.map(Int.init) ?? digits.count
        if highDigit - lowDigit > 1 {
            return [UInt8((lowDigit + highDigit + 1) / 2)]
        }
        if let high, high.count > 1 {
            return [high[high.startIndex]]
        }
        return [UInt8(lowDigit)] + midpoint(low.dropFirst(), nil)
    }
}
