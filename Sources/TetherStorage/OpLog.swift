// The op log: appending ops, the materialized state they produce, and version vectors.

import Foundation

public struct StateRow: Sendable, Equatable {
    public let docID: DocID
    public let field: String
    public let value: Data
    public let hlc: UInt64
    public let replicaID: ReplicaID
}

extension Database {
    /// Appends ops in one transaction. Ops already in the log are skipped.
    /// Returns how many were new.
    @discardableResult
    public func append(_ ops: [Op]) throws -> Int {
        try transaction { db in
            var inserted = 0
            for op in ops {
                let payload = op.encoded()
                try db.run(
                    """
                    INSERT OR IGNORE INTO ops(replica_id, counter, hlc, doc_id, payload, crc32)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .blob(op.replicaID.bytes), try sqlInt(op.counter, "counter"),
                        try sqlInt(op.hlc, "hlc"), .blob(op.docID.bytes), .blob(payload),
                        .int(Int64(CRC32.checksum(payload))),
                    ])
                guard db.changes > 0 else { continue }
                inserted += 1
                try db.applyToState(op)
                try db.run(
                    """
                    INSERT INTO version_vector(replica_id, max_counter) VALUES (?, ?)
                    ON CONFLICT(replica_id) DO UPDATE
                    SET max_counter = max(max_counter, excluded.max_counter)
                    """,
                    [.blob(op.replicaID.bytes), try sqlInt(op.counter, "counter")])
            }
            return inserted
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

    public func versionVector() throws -> [ReplicaID: UInt64] {
        var vector: [ReplicaID: UInt64] = [:]
        for row in try query("SELECT replica_id, max_counter FROM version_vector") {
            guard let id = ReplicaID(bytes: try row.blob("replica_id")) else {
                throw StorageError.corrupt("version_vector.replica_id")
            }
            vector[id] = UInt64(try row.int("max_counter"))
        }
        return vector
    }

    /// Every op this database has that a peer with `vector` hasn't seen.
    public func ops(missingFrom vector: [ReplicaID: UInt64]) throws -> [Op] {
        var missing: [Op] = []
        let known = try versionVector().sorted {
            $0.key.bytes.lexicographicallyPrecedes($1.key.bytes)
        }
        for (replica, ours) in known {
            let theirs = vector[replica, default: 0]
            guard ours > theirs else { continue }
            let rows = try query(
                """
                SELECT payload, crc32 FROM ops
                WHERE replica_id = ? AND counter > ? ORDER BY counter
                """,
                [.blob(replica.bytes), try sqlInt(theirs, "counter")])
            missing += try rows.map(decodeStored)
        }
        return missing
    }

    /// Throws away `state` and recomputes it by replaying every op in (hlc, replica_id) order.
    public func rebuildState() throws {
        try transaction { db in
            try db.execute("DELETE FROM state")
            for row in try db.query("SELECT payload, crc32 FROM ops ORDER BY hlc, replica_id") {
                try db.applyToState(try db.decodeStored(row))
            }
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
                hlc: UInt64(try row.int("hlc")), replicaID: replicaID)
        }
    }

    // Last writer wins by (hlc, replica_id) until Week 2 swaps in CRDT merges.
    private func applyToState(_ op: Op) throws {
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
        return try Op(decoding: payload)
    }
}

// SQLite integers are signed; anything above Int64.max would sort wrongly.
private func sqlInt(_ value: UInt64, _ name: String) throws -> SQLValue {
    guard let signed = Int64(exactly: value) else { throw StorageError.valueTooLarge(name) }
    return .int(signed)
}
