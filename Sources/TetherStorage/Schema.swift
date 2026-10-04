// Tether's on-disk schema, how a store is opened, and the per-device replica id.

import Foundation

enum Schema {
    static let migrations: [Migration] = [
        // 1: ops is the source of truth; state is rebuildable from it.
        { db in
            try db.execute(
                """
                CREATE TABLE ops(
                    replica_id BLOB NOT NULL,
                    counter INTEGER NOT NULL,
                    hlc INTEGER NOT NULL,
                    doc_id BLOB NOT NULL,
                    payload BLOB NOT NULL,
                    crc32 INTEGER NOT NULL,
                    PRIMARY KEY (replica_id, counter)
                ) STRICT;
                CREATE INDEX ops_by_hlc ON ops(hlc, replica_id);
                CREATE TABLE state(
                    doc_id BLOB NOT NULL,
                    field TEXT NOT NULL,
                    value BLOB NOT NULL,
                    hlc INTEGER NOT NULL,
                    replica_id BLOB NOT NULL,
                    PRIMARY KEY (doc_id, field)
                ) STRICT;
                CREATE TABLE version_vector(
                    replica_id BLOB PRIMARY KEY,
                    max_counter INTEGER NOT NULL
                ) STRICT;
                CREATE TABLE meta(
                    key TEXT PRIMARY KEY,
                    value BLOB NOT NULL
                ) STRICT;
                """)
        }
    ]
}

extension Database {
    /// Opens a database with Tether's schema applied and a replica id assigned.
    public static func openStore(path: String) async throws -> Database {
        let db = try Database(path: path)
        try await db.migrate(Schema.migrations)
        _ = try await db.replicaID()
        return db
    }

    /// This device's replica id, created on first use and stable after that.
    public func replicaID() throws -> ReplicaID {
        if let existing = try storedReplicaID() { return existing }
        return try transaction { db in
            try db.run(
                "INSERT OR IGNORE INTO meta(key, value) VALUES ('replica_id', ?)",
                [.blob(ReplicaID.random().bytes)])
            guard let id = try db.storedReplicaID() else {
                throw StorageError.corrupt("replica_id")
            }
            return id
        }
    }

    private func storedReplicaID() throws -> ReplicaID? {
        guard let row = try query("SELECT value FROM meta WHERE key = 'replica_id'").first else {
            return nil
        }
        guard let id = ReplicaID(bytes: try row.blob("value")) else {
            throw StorageError.corrupt("replica_id")
        }
        return id
    }
}
