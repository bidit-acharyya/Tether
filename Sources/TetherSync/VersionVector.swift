// VersionVector: the highest op counter seen from each replica. Comparing two vectors says
// exactly which ops one side is missing.

import TetherStorage

public struct VersionVector: Hashable, Sendable {
    public enum Order: Sendable {
        case equal, ahead, behind, concurrent
    }

    public private(set) var counters: [ReplicaID: UInt64]

    public init(_ counters: [ReplicaID: UInt64] = [:]) {
        self.counters = counters.filter { $0.value > 0 }
    }

    public subscript(replica: ReplicaID) -> UInt64 {
        counters[replica] ?? 0
    }

    public mutating func merge(_ other: VersionVector) {
        counters.merge(other.counters, uniquingKeysWith: max)
    }

    /// True if this vector has seen everything `other` has.
    public func dominates(_ other: VersionVector) -> Bool {
        other.counters.allSatisfy { replica, counter in self[replica] >= counter }
    }

    public func compare(to other: VersionVector) -> Order {
        switch (dominates(other), other.dominates(self)) {
        case (true, true): return .equal
        case (true, false): return .ahead
        case (false, true): return .behind
        case (false, false): return .concurrent
        }
    }

    /// The counters this vector has and `other` lacks, per replica.
    public func missing(from other: VersionVector) -> [ReplicaID: ClosedRange<UInt64>] {
        var ranges: [ReplicaID: ClosedRange<UInt64>] = [:]
        for (replica, ours) in counters where ours > other[replica] {
            ranges[replica] = (other[replica] + 1)...ours
        }
        return ranges
    }
}

// Layout: entry count, then (replica id, counter varint) sorted by replica id.
extension VersionVector {
    func write(to writer: inout ByteWriter) {
        let entries = counters.sorted { $0.key < $1.key }
        writer.writeVarint(UInt64(entries.count))
        for (replica, counter) in entries {
            writer.writeFixed(replica.bytes)
            writer.writeVarint(counter)
        }
    }

    static func read(from reader: inout ByteReader) throws -> VersionVector {
        var counters: [ReplicaID: UInt64] = [:]
        for _ in 0..<(try reader.readVarint()) {
            guard let replica = ReplicaID(bytes: try reader.readFixed(16)) else {
                throw StorageError.truncated
            }
            counters[replica] = try reader.readVarint()
        }
        return VersionVector(counters)
    }
}
