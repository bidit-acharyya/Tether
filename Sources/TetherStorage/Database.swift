import SQLite3

/// One SQLite connection.
///
/// The actor serializes every call, so the connection is opened with `SQLITE_OPEN_NOMUTEX`
/// and skips SQLite's own per-connection locking.
public actor Database {
    /// The live connection, or `nil` once `close()` has run.
    nonisolated(unsafe) private var connection: OpaquePointer?
    private var statements: [String: Statement] = [:]
    private(set) var inTransaction = false
    /// How ops merge into state; nil means plain last-writer-wins on the body.
    private(set) var mergeRules: MergeRules?

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
        // close_v2 defers the close until any cached statements are finalized.
        sqlite3_close_v2(connection)
    }

    public func setMergeRules(_ rules: MergeRules) {
        mergeRules = rules
    }

    /// Closes the connection. Safe to call more than once; later calls do nothing.
    public func close() {
        guard let connection else { return }
        statements.removeAll()
        sqlite3_close_v2(connection)
        self.connection = nil
    }

    /// Runs one or more SQL statements that return no rows.
    public func execute(_ sql: String) throws {
        try check(sqlite3_exec(openConnection(), sql, nil, nil, nil), connection)
    }

    /// Runs one statement with bound parameters, ignoring any rows.
    public func run(_ sql: String, _ values: [SQLValue] = []) throws {
        _ = try query(sql, values)
    }

    public func query(_ sql: String, _ values: [SQLValue] = []) throws -> [Row] {
        let statement = try prepared(sql)
        defer { statement.reset() }
        try statement.bind(values)
        return try statement.rows()
    }

    /// Runs `body` inside `BEGIN IMMEDIATE ... COMMIT`, rolling back if it throws.
    public func transaction<T: Sendable>(
        _ body: @Sendable (isolated Database) throws -> T
    ) throws -> T {
        precondition(!inTransaction, "Nested transactions aren't supported")
        try execute("BEGIN IMMEDIATE")
        inTransaction = true
        defer { inTransaction = false }
        do {
            let result = try body(self)
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func pragma(_ name: String) throws -> SQLValue? {
        try query("PRAGMA \(name)").first?.values.first
    }

    var cachedStatementCount: Int { statements.count }

    /// Rows changed by the most recent INSERT, UPDATE or DELETE.
    var changes: Int {
        guard let connection else { return 0 }
        return Int(sqlite3_changes(connection))
    }

    private func prepared(_ sql: String) throws -> Statement {
        if let cached = statements[sql] { return cached }
        let statement = try Statement(sql, connection: openConnection())
        statements[sql] = statement
        return statement
    }

    private func openConnection() throws -> OpaquePointer {
        guard let connection else { throw StorageError.closed }
        return connection
    }

    // Static so the synchronous init can call it before the actor is fully initialized.
    private static func configure(_ connection: OpaquePointer, inMemory: Bool) throws {
        let mode = try Statement("PRAGMA journal_mode=WAL", connection: connection)
            .rows().first?.values.first
        guard mode == .text(inMemory ? "memory" : "wal") else {
            throw StorageError.unexpectedJournalMode(String(describing: mode))
        }
        try check(sqlite3_exec(connection, "PRAGMA synchronous=FULL", nil, nil, nil), connection)
        try check(sqlite3_exec(connection, "PRAGMA foreign_keys=ON", nil, nil, nil), connection)
    }
}
