import SQLite3

/// Everything that can go wrong in TetherStorage.
public enum StorageError: Error, Equatable {
    case sqlite(code: Int32, message: String)
    case closed
    case unexpectedJournalMode(String)
    case emptyStatement
    case parameterCount(expected: Int, actual: Int)
    case noSuchColumn(String)
    case typeMismatch(column: String)
    case schemaTooNew(found: Int, supported: Int)
    case corrupt(String)
}

extension StorageError {
    /// Builds an error for `code`, reading the message from `connection` when there is one.
    init(code: Int32, connection: OpaquePointer?) {
        let message =
            connection.map { String(cString: sqlite3_errmsg($0)) }
            ?? String(cString: sqlite3_errstr(code))
        self = .sqlite(code: code, message: message)
    }
}

/// Throws unless `rc` is `SQLITE_OK`. Every SQLite call that returns a result code goes
/// through here, so errors always carry SQLite's own message.
func check(_ rc: Int32, _ connection: OpaquePointer?) throws {
    guard rc == SQLITE_OK else { throw StorageError(code: rc, connection: connection) }
}
