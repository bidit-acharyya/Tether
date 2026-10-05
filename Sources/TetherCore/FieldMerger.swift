// FieldMerger: how storage merges an op into a field's state, chosen by the op's kind.
// It never needs the field's value type, which is what Week 4's version skew relies on.

import Foundation
import TetherStorage

public enum CoreError: Error, Equatable {
    case unknownOpKind(UInt8)
}

public enum FieldMerger {
    public static let merge: FieldMerge = { op, current in
        switch OpKind(rawValue: op.kind) {
        case .set:
            return try mergeRegisters(current, op.body)
        case .add, .remove:
            var set = try current.map { try ORSet<Data>(decoding: $0) } ?? ORSet()
            set.merge(try ORSet<Data>(decoding: op.body))
            return set.encoded()
        case nil:
            throw CoreError.unknownOpKind(op.kind)
        }
    }

    /// LWW merge on encoded registers: compare the stamps, keep the winner's bytes as-is.
    static func mergeRegisters(_ current: Data?, _ incoming: Data) throws -> Data {
        guard let current else { return incoming }
        return try stamp(of: incoming) > stamp(of: current) ? incoming : current
    }

    private static func stamp(of encoded: Data) throws -> Stamp {
        var reader = ByteReader(encoded)
        let hlc = HLCTimestamp(rawValue: try reader.readVarint())
        guard let replicaID = ReplicaID(bytes: try reader.readFixed(16)) else {
            throw StorageError.truncated
        }
        return Stamp(hlc: hlc, replicaID: replicaID)
    }
}
