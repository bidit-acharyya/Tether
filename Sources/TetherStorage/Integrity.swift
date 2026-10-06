// Corruption detection: SQLite's own checks plus Tether's op-log invariants.

extension Database {
    /// Full check: integrity_check, every op's CRC, and state and version vector
    /// matching a replay of the op log. Throws `.corrupt` on any mismatch.
    public func verify() throws {
        try checkPragma("integrity_check")
        let live = try stateSnapshot()
        let vector = try versionVector()
        do {
            // Replay inside a transaction, then throw to roll it back.
            try transaction { db in
                try db.replayOps()
                throw Replayed(state: try db.stateSnapshot(), vector: try db.vectorFromOps())
            }
        } catch let replayed as Replayed {
            guard replayed.state == live else {
                throw StorageError.corrupt("state doesn't match op log")
            }
            guard replayed.vector == vector else {
                throw StorageError.corrupt("version vector doesn't match op log")
            }
        }
    }

    func checkPragma(_ name: String) throws {
        guard try query("PRAGMA \(name)").first?.value(name) == .text("ok") else {
            throw StorageError.corrupt("\(name) failed")
        }
    }

    /// The contiguous prefix per replica, recomputed from the ops themselves.
    private func vectorFromOps() throws -> [ReplicaID: UInt64] {
        var vector: [ReplicaID: UInt64] = [:]
        for row in try query("SELECT replica_id, counter FROM ops ORDER BY replica_id, counter") {
            guard let id = ReplicaID(bytes: try row.blob("replica_id")) else {
                throw StorageError.corrupt("ops.replica_id")
            }
            let counter = try row.uint64("counter")
            if counter == vector[id, default: 0] + 1 { vector[id] = counter }
        }
        return vector
    }
}

private struct Replayed: Error {
    let state: [StateRow]
    let vector: [ReplicaID: UInt64]
}
