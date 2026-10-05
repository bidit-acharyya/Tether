// Last-writer-wins register: one value plus the stamp of the write that set it.

import Foundation
import TetherStorage

public struct LWWRegister<Value: FieldValue>: CRDT {
    public private(set) var value: Value
    public private(set) var stamp: Stamp

    public init(value: Value, stamp: Stamp) {
        self.value = value
        self.stamp = stamp
    }

    /// Keeps the higher stamp. Every stamp names exactly one write, so ties can't disagree.
    public mutating func merge(_ other: LWWRegister) {
        if other.stamp > stamp { self = other }
    }
}

// Layout: hlc varint, replica id (16 bytes), value.
extension LWWRegister {
    public func encoded() -> Data {
        var writer = ByteWriter()
        writer.writeVarint(stamp.hlc.rawValue)
        writer.writeFixed(stamp.replicaID.bytes)
        value.write(to: &writer)
        return writer.data
    }

    public init(decoding data: Data) throws {
        var reader = ByteReader(data)
        let hlc = HLCTimestamp(rawValue: try reader.readVarint())
        guard let replicaID = ReplicaID(bytes: try reader.readFixed(16)) else {
            throw StorageError.truncated
        }
        let value = try Value.read(from: &reader)
        guard reader.isAtEnd else { throw StorageError.invalidEncoding("trailing bytes") }
        self.init(value: value, stamp: Stamp(hlc: hlc, replicaID: replicaID))
    }
}

extension Op {
    /// A `set` op carrying `register`; its replica and hlc come from the register's stamp.
    public static func set<Value>(
        _ register: LWWRegister<Value>, docID: DocID, field: String, counter: UInt64
    ) -> Op {
        Op(
            replicaID: register.stamp.replicaID, counter: counter,
            hlc: register.stamp.hlc.rawValue, docID: docID, field: field,
            kind: OpKind.set.rawValue, body: register.encoded())
    }
}
