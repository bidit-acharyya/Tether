// FieldMerger: how storage merges an op into a field's state, chosen by the op's kind.
// It never needs the field's value type, so a version merges fields it has never heard of;
// only an op kind it can't merge leaves the field pending.

import Foundation
import TetherStorage

public enum CoreError: Error, Equatable {
    /// A change tried to write a field or op kind this app version's manifest doesn't have.
    case notInManifest(field: String, kind: UInt8)
    /// No field by this name in this document type, for this app version.
    case unknownField(String)
    /// The field's CRDT kind or value type doesn't fit the read or write.
    case typeMismatch(String)
}

public enum FieldMerger {
    /// The rules for the app version described by `manifest`.
    public static func rules(for manifest: SchemaManifest) -> MergeRules {
        let kinds = manifest.mergeableKinds
        let fields = Set(manifest.documents.flatMap(\.fields).map(\.id))
        return MergeRules(
            merge: { op, current in
                guard kinds.contains(op.kind) else { return nil }
                return try merge(op, current)
            },
            isKnown: { fields.contains(SchemaManifest.baseID(of: $0)) })
    }

    static func merge(_ op: Op, _ current: Data?) throws -> Data? {
        switch OpKind(rawValue: op.kind) {
        case .set:
            return try mergeRegisters(current, op.body)
        case .add, .remove:
            var set = try current.map { try ORSet<Data>(decoding: $0) } ?? ORSet()
            set.merge(try ORSet<Data>(decoding: op.body))
            return set.encoded()
        case .increment:
            var counter = try current.map { try PNCounter(decoding: $0) } ?? PNCounter()
            counter.merge(try PNCounter(decoding: op.body))
            return counter.encoded()
        case nil:
            return nil
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
