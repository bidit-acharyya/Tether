// The op log: appending ops, the materialized state they produce, and version vectors.

import Foundation

public struct StateRow: Sendable, Equatable {
    public let docID: DocID
    public let field: String
    public let value: Data
    public let hlc: UInt64
    public let replicaID: ReplicaID
    /// The app's manifest has this field; UIs can skip the rest.
    public let known: Bool
    /// Holds ops this version can't merge; `value` is meaningless until an upgrade rebuilds it.
    public let pending: Bool
}

/// How ops merge into state. Storage never decodes values itself.
public struct MergeRules: Sendable {
    /// Merges `op` into a field's current bytes (nil if new). Returns nil if this version
    /// can't merge the op's kind, which marks the field pending.
    public let merge: @Sendable (_ op: Op, _ current: Data?) throws -> Data?
    public let isKnown: @Sendable (_ field: String) -> Bool

    public init(
        merge: @escaping @Sendable (Op, Data?) throws -> Data?,
        isKnown: @escaping @Sendable (String) -> Bool
    ) {
        self.merge = merge
        self.isKnown = isKnown
    }
}

extension Database {
    /// Appends ops in one transaction. Ops already in the log are skipped.
    /// Returns how many were new.
    @discardableResult
    public func append(_ ops: [Op]) throws -> Int {
        try transaction { db in try db.appendInTransaction(ops) }
    }

    /// append's body, for callers that batch other writes into the same transaction.
    public func appendInTransaction(_ ops: [Op]) throws -> Int {
        precondition(inTransaction, "appendInTransaction needs an open transaction")
        var inserted = 0
        for op in ops {
            let payload = op.encoded()
            try run(
                """
                INSERT OR IGNORE INTO ops(replica_id, counter, hlc, doc_id, payload, crc32)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                [
                    .blob(op.replicaID.bytes), try sqlInt(op.counter, "counter"),
                    try sqlInt(op.hlc, "hlc"), .blob(op.docID.bytes), .blob(payload),
                    .int(Int64(CRC32.checksum(payload))),
                ])
            guard changes > 0 else { continue }
            inserted += 1
            try applyToState(op)
            try advanceVersionVector(op.replicaID, inserted: op.counter)
        }
        return inserted
    }

    // The version vector holds, per replica, the highest n such that ops 1...n are all
    // here. Ops can arrive out of order, so a gap holds the counter back until it fills;
    // claiming the highest counter seen would make peers skip the missing op forever.
    private func advanceVersionVector(_ replica: ReplicaID, inserted counter: UInt64) throws {
        let current =
            try query(
                "SELECT max_counter FROM version_vector WHERE replica_id = ?",
                [.blob(replica.bytes)]
            ).first?.uint64("max_counter") ?? 0
        var prefix = current
        if counter == current + 1 {
            prefix = counter
            while true {
                let next = try query(
                    """
                    SELECT counter FROM ops WHERE replica_id = ? AND counter > ?
                    ORDER BY counter LIMIT 64
                    """,
                    [.blob(replica.bytes), try sqlInt(prefix, "counter")]
                ).map { try $0.uint64("counter") }
                let before = prefix
                for found in next {
                    guard found == prefix + 1 else { break }
                    prefix = found
                }
                if next.count < 64 || prefix - before < UInt64(next.count) { break }
            }
        }
        try run(
            """
            INSERT INTO version_vector(replica_id, max_counter) VALUES (?, ?)
            ON CONFLICT(replica_id) DO UPDATE SET max_counter = excluded.max_counter
            """,
            [.blob(replica.bytes), try sqlInt(prefix, "counter")])
    }

    /// A field's current merged state bytes, or nil if no op has touched it.
    public func stateValue(docID: DocID, field: String) throws -> Data? {
        try query(
            "SELECT value FROM state WHERE doc_id = ? AND field = ?",
            [.blob(docID.bytes), .text(field)]
        ).first?.blob("value")
    }

    /// Whether a field holds ops this version can't merge yet.
    public func isPending(docID: DocID, field: String) throws -> Bool {
        try query(
            "SELECT pending FROM state WHERE doc_id = ? AND field = ?",
            [.blob(docID.bytes), .text(field)]
        ).first?.int("pending") == 1
    }

    /// The state of every field of `docID` whose name starts with `prefix`.
    public func stateValues(docID: DocID, fieldPrefix prefix: String) throws -> [Data] {
        // A range on the (doc_id, field) primary key; U+FFFF sorts after any suffix we use.
        try query(
            "SELECT value FROM state WHERE doc_id = ? AND field >= ? AND field < ?",
            [.blob(docID.bytes), .text(prefix), .text(prefix + "\u{FFFF}")]
        ).map { try $0.blob("value") }
    }

    /// Every (doc, value) for one field name, e.g. all item positions.
    public func stateValues(field: String) throws -> [(docID: DocID, value: Data)] {
        try query("SELECT doc_id, value FROM state WHERE field = ?", [.text(field)]).map { row in
            guard let docID = DocID(bytes: try row.blob("doc_id")) else {
                throw StorageError.corrupt("state.doc_id")
            }
            return (docID, try row.blob("value"))
        }
    }

    @discardableResult
    public func append(_ op: Op) throws -> Bool {
        try append([op]) == 1
    }

    /// The counter for this replica's next local op.
    public func nextCounter() throws -> UInt64 {
        let own = try replicaID()
        return (try versionVector()[own] ?? 0) + 1
    }

    /// Per replica, the highest n such that every op 1...n is here. Replicas with no
    /// contiguous ops yet are left out.
    public func versionVector() throws -> [ReplicaID: UInt64] {
        var vector: [ReplicaID: UInt64] = [:]
        let rows = try query(
            "SELECT replica_id, max_counter FROM version_vector WHERE max_counter > 0")
        for row in rows {
            guard let id = ReplicaID(bytes: try row.blob("replica_id")) else {
                throw StorageError.corrupt("version_vector.replica_id")
            }
            vector[id] = try row.uint64("max_counter")
        }
        return vector
    }

    /// Every op in this database's contiguous prefix that a peer with `vector` lacks, sorted
    /// by replica then counter. Ops past a gap are held back until the gap fills.
    public func ops(missingFrom vector: [ReplicaID: UInt64]) throws -> [Op] {
        var missing: [Op] = []
        for (replica, ours) in try versionVector().sorted(by: { $0.key < $1.key }) {
            let theirs = vector[replica, default: 0]
            guard ours > theirs else { continue }
            let rows = try query(
                """
                SELECT \(opColumns) FROM ops
                WHERE replica_id = ? AND counter > ? AND counter <= ? ORDER BY counter
                """,
                [.blob(replica.bytes), try sqlInt(theirs, "counter"), try sqlInt(ours, "counter")])
            missing += try rows.map(decodeStored)
        }
        return missing
    }

    /// Throws away `state` and recomputes it by replaying every op in (hlc, replica_id) order.
    public func rebuildState() throws {
        try transaction { db in try db.replayOps() }
    }

    /// rebuildState's body, for callers already inside a transaction.
    func replayOps() throws {
        try execute("DELETE FROM state")
        for row in try query("SELECT \(opColumns) FROM ops ORDER BY hlc, replica_id") {
            try applyToState(try decodeStored(row))
        }
    }

    /// All of `state`, sorted, so two databases can be compared with `==`.
    public func stateSnapshot() throws -> [StateRow] {
        try query("SELECT * FROM state ORDER BY doc_id, field").map { row in
            guard let docID = DocID(bytes: try row.blob("doc_id")),
                let replicaID = ReplicaID(bytes: try row.blob("replica_id"))
            else { throw StorageError.corrupt("state ids") }
            return StateRow(
                docID: docID, field: try row.text("field"), value: try row.blob("value"),
                hlc: try row.uint64("hlc"), replicaID: replicaID, known: try row.int("known") == 1,
                pending: try row.int("pending") == 1)
        }
    }

    // With merge rules, state.value is whatever they return and (hlc, replica_id) is the
    // highest stamp that touched the field. Without them, the higher stamp's body wins.
    // An op the rules can't merge is still logged and synced; its field just goes pending.
    private func applyToState(_ op: Op) throws {
        if let mergeRules {
            let row = try query(
                "SELECT value, pending FROM state WHERE doc_id = ? AND field = ?",
                [.blob(op.docID.bytes), .text(op.field)]
            ).first
            let current = try row?.blob("value")
            let merged = try row?.int("pending") == 1 ? nil : mergeRules.merge(op, current)
            try run(
                """
                INSERT INTO state(doc_id, field, value, hlc, replica_id, known, pending)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(doc_id, field) DO UPDATE SET value = excluded.value,
                known = excluded.known, pending = excluded.pending,
                hlc = CASE WHEN (excluded.hlc, excluded.replica_id) > (state.hlc, state.replica_id)
                    THEN excluded.hlc ELSE state.hlc END,
                replica_id = CASE
                    WHEN (excluded.hlc, excluded.replica_id) > (state.hlc, state.replica_id)
                    THEN excluded.replica_id ELSE state.replica_id END
                """,
                [
                    .blob(op.docID.bytes), .text(op.field), .blob(merged ?? current ?? Data()),
                    try sqlInt(op.hlc, "hlc"), .blob(op.replicaID.bytes),
                    .int(mergeRules.isKnown(op.field) ? 1 : 0), .int(merged == nil ? 1 : 0),
                ])
            return
        }
        try run(
            """
            INSERT INTO state(doc_id, field, value, hlc, replica_id) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(doc_id, field) DO UPDATE
            SET value = excluded.value, hlc = excluded.hlc, replica_id = excluded.replica_id
            WHERE (excluded.hlc, excluded.replica_id) > (state.hlc, state.replica_id)
            """,
            [
                .blob(op.docID.bytes), .text(op.field), .blob(op.body),
                try sqlInt(op.hlc, "hlc"), .blob(op.replicaID.bytes),
            ])
    }

    private func decodeStored(_ row: Row) throws -> Op {
        let payload = try row.blob("payload")
        guard CRC32.checksum(payload) == UInt32(truncatingIfNeeded: try row.int("crc32")) else {
            throw StorageError.corrupt("op checksum mismatch")
        }
        let op = try Op(decoding: payload)
        // The indexed columns sit outside the CRC, so check them against the payload.
        guard try row.blob("replica_id") == op.replicaID.bytes,
            try row.uint64("counter") == op.counter,
            try row.uint64("hlc") == op.hlc,
            try row.blob("doc_id") == op.docID.bytes
        else { throw StorageError.corrupt("op columns don't match payload") }
        return op
    }
}

private let opColumns = "replica_id, counter, hlc, doc_id, payload, crc32"

// SQLite integers are signed; anything above Int64.max would sort wrongly.
private func sqlInt(_ value: UInt64, _ name: String) throws -> SQLValue {
    guard let signed = Int64(exactly: value) else { throw StorageError.valueTooLarge(name) }
    return .int(signed)
}
