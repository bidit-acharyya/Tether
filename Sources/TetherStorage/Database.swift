import SQLite3

/// One SQLite connection.
///
/// The actor serializes every call, so the connection is opened with `SQLITE_OPEN_NOMUTEX`
/// and skips SQLite's own per-connection locking.
public actor Database {
    /// The live connection, or `nil` once `close()` has run.
    nonisolated(unsafe) private var connection: OpaquePointer?

    public init(path: String) throws {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &connection, flags, nil)
        guard rc == SQLITE_OK, let connection else {
            // sqlite3_open_v2 usually allocates a handle even when it fails. Read the error
            // message from it before releasing it.
            let error = StorageError(code: rc, connection: connection)
            sqlite3_close_v2(connection)
            throw error
        }
        do {
            try Self.configure(connection, inMemory: path == ":memory:")
        } catch {
            sqlite3_close_v2(connection)
            throw error
        }
        self.connection = connection
    }

    /// A fresh, private in-memory database. Used by tests and, later, the simulator.
    public static func inMemory() throws -> Database {
        try Database(path: ":memory:")
    }

    deinit {
        sqlite3_close_v2(connection)  // A nil connection is a harmless no-op.
    }

    /// Closes the connection. Safe to call more than once; later calls do nothing.
    public func close() {
        guard let connection else { return }
        sqlite3_close_v2(connection)
        self.connection = nil
    }

    /// Runs one or more SQL statements that return no rows.
    public func execute(_ sql: String) throws {
        try Self.execute(sql, on: openConnection())
    }

    /// Reads a pragma's current value as text, e.g. `pragma("journal_mode")` returns `"wal"`.
    func pragma(_ name: String) throws -> String? {
        try Self.queryText("PRAGMA \(name)", on: openConnection())
    }

    private func openConnection() throws -> OpaquePointer {
        guard let connection else { throw StorageError.closed }
        return connection
    }

    // These are static and take the raw connection so `init` can call them before the actor
    // is fully initialized. A synchronous actor init can't call isolated methods.

    private static func configure(_ connection: OpaquePointer, inMemory: Bool) throws {

        let mode = try queryText("PRAGMA journal_mode=WAL", on: connection)
        guard mode == (inMemory ? "memory" : "wal") else {
            throw StorageError.unexpectedJournalMode(mode ?? "")
        }

        try execute("PRAGMA synchronous=FULL", on: connection)
        try execute("PRAGMA foreign_keys=ON", on: connection)
    }

    private static func execute(_ sql: String, on connection: OpaquePointer) throws {
        try check(sqlite3_exec(connection, sql, nil, nil, nil), connection)
    }

    /// Returns the first column of the first row as text, or `nil` if there are no rows.
    /// A stand-in until Session 1.2 adds a proper statement wrapper.
    private static func queryText(_ sql: String, on connection: OpaquePointer) throws -> String? {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), connection)
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_step(statement)
        switch rc {
        case SQLITE_ROW:
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        case SQLITE_DONE:
            return nil
        default:
            throw StorageError(code: rc, connection: connection)
        }
    }
}
