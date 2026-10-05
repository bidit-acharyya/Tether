// 16-byte identifiers: ReplicaID names a device's database, DocID names a document.
// Stored as two big-endian UInt64 halves so hashing and comparing are cheap; comparing the
// halves gives the same order as comparing the bytes, which is how SQLite orders the blobs.

import Foundation

public struct ReplicaID: Hashable, Comparable, Sendable {
    private let high: UInt64
    private let low: UInt64

    public var bytes: Data { encode(high, low) }

    public init?(bytes: Data) {
        guard let (high, low) = decode(bytes) else { return nil }
        self.high = high
        self.low = low
    }

    public static func < (lhs: ReplicaID, rhs: ReplicaID) -> Bool {
        lhs.high != rhs.high ? lhs.high < rhs.high : lhs.low < rhs.low
    }

    public static func random() -> ReplicaID {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> ReplicaID {
        ReplicaID(high: generator.next(), low: generator.next())
    }

    private init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }
}

public struct DocID: Hashable, Comparable, Sendable {
    private let high: UInt64
    private let low: UInt64

    public var bytes: Data { encode(high, low) }

    public init?(bytes: Data) {
        guard let (high, low) = decode(bytes) else { return nil }
        self.high = high
        self.low = low
    }

    public static func < (lhs: DocID, rhs: DocID) -> Bool {
        lhs.high != rhs.high ? lhs.high < rhs.high : lhs.low < rhs.low
    }

    public static func random() -> DocID {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> DocID {
        DocID(high: generator.next(), low: generator.next())
    }

    private init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }
}

private func decode(_ bytes: Data) -> (UInt64, UInt64)? {
    guard bytes.count == 16 else { return nil }
    return bytes.withUnsafeBytes { raw in
        (
            UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self)),
            UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        )
    }
}

private func encode(_ high: UInt64, _ low: UInt64) -> Data {
    withUnsafeBytes(of: (high.bigEndian, low.bigEndian)) { Data($0) }
}
