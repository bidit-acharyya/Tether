// Schema migrations, tracked by SQLite's PRAGMA user_version.

public typealias Migration = @Sendable (isolated Database) throws -> Void

extension Database {
    /// Runs every migration past the stored version, all in one transaction.
    public func migrate(_ migrations: [Migration]) throws {
        let current = try userVersion()
        guard current <= migrations.count else {
            throw StorageError.schemaTooNew(found: current, supported: migrations.count)
        }
        guard current < migrations.count else { return }
        try transaction { db in
            for migration in migrations[current...] {
                try migration(db)
            }
            try db.execute("PRAGMA user_version = \(migrations.count)")
        }
    }

    func userVersion() throws -> Int {
        guard case .int(let version) = try pragma("user_version") else {
            throw StorageError.corrupt("user_version")
        }
        return Int(version)
    }
}
