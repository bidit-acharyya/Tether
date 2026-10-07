// PN-Counter: each replica keeps running totals of its own increments and decrements;
// merging takes the per-replica max, and the value is all increments minus all decrements.

import Foundation
import TetherStorage

public struct PNCounter: CRDT {
    public struct Totals: Equatable, Sendable {
        public var increments: UInt64 = 0
        public var decrements: UInt64 = 0
    }

    public private(set) var totals: [ReplicaID: Totals] = [:]

    public init() {}

    public var value: Int64 {
        totals.values.reduce(0) {
            $0 &+ Int64(bitPattern: $1.increments) &- Int64(bitPattern: $1.decrements)
        }
    }

    public mutating func merge(_ other: PNCounter) {
        totals.merge(other.totals) { mine, theirs in
            Totals(
                increments: max(mine.increments, theirs.increments),
                decrements: max(mine.decrements, theirs.decrements))
        }
    }

    /// The delta for `replica` adding `amount`: just its new running totals.
    public func adding(_ amount: Int64, by replica: ReplicaID) -> PNCounter {
        var mine = totals[replica] ?? Totals()
        if amount >= 0 {
            mine.increments &+= UInt64(amount)
        } else {
            mine.decrements &+= amount.magnitude
        }
        var delta = PNCounter()
        delta.totals[replica] = mine
        return delta
    }
}

// Layout: entry count, then per replica (sorted) its id, increments, decrements.
extension PNCounter {
    public func encoded() -> Data {
        var writer = ByteWriter()
        writer.writeVarint(UInt64(totals.count))
        for (replica, entry) in totals.sorted(by: { $0.key < $1.key }) {
            writer.writeFixed(replica.bytes)
            writer.writeVarint(entry.increments)
            writer.writeVarint(entry.decrements)
        }
        return writer.data
    }

    public init(decoding data: Data) throws {
        var reader = ByteReader(data)
        self.init()
        for _ in 0..<(try reader.readVarint()) {
            guard let replica = ReplicaID(bytes: try reader.readFixed(16)) else {
                throw StorageError.truncated
            }
            guard totals[replica] == nil else {
                throw StorageError.invalidEncoding("duplicate counter replica")
            }
            totals[replica] = Totals(
                increments: try reader.readVarint(), decrements: try reader.readVarint())
        }
        guard reader.isAtEnd else { throw StorageError.invalidEncoding("trailing bytes") }
    }
}

extension Op {
    /// An `increment` op adding `amount` to `counter` on behalf of `replicaID`.
    public static func increment(
        _ amount: Int64, of counter: PNCounter, docID: DocID, field: String,
        replicaID: ReplicaID, opCounter: UInt64, hlc: HLCTimestamp
    ) -> Op {
        Op(
            replicaID: replicaID, counter: opCounter, hlc: hlc.rawValue, docID: docID,
            field: field, kind: OpKind.increment.rawValue,
            body: counter.adding(amount, by: replicaID).encoded())
    }
}
