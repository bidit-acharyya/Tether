// The CRDT protocol, the Stamp that orders writes, and the op kinds CRDTs encode to.

import TetherStorage

/// A value that merges deterministically. merge must be commutative, associative and
/// idempotent. Tests check those laws on whole states; the engine applies one op at a time.
public protocol CRDT: Sendable, Equatable {
    mutating func merge(_ other: Self)
}

/// Orders writes: HLC first, then replica id to break ties the same way everywhere.
public struct Stamp: Comparable, Hashable, Sendable {
    public let hlc: HLCTimestamp
    public let replicaID: ReplicaID

    public init(hlc: HLCTimestamp, replicaID: ReplicaID) {
        self.hlc = hlc
        self.replicaID = replicaID
    }

    public static func < (lhs: Stamp, rhs: Stamp) -> Bool {
        (lhs.hlc, lhs.replicaID) < (rhs.hlc, rhs.replicaID)
    }
}

public enum OpKind: UInt8, Sendable {
    case set = 1
    case add = 2
    case remove = 3
}
