import Foundation
import SQLite3
import Testing

@testable import TetherStorage

@Suite struct DatabaseTests {
    @Test func fileDatabaseUsesWALFullSyncAndForeignKeys() async throws {
        try await withTemporaryDirectory { directory in
            let db = try Database(path: directory.appendingPathComponent("test.sqlite").path)
            #expect(try await db.pragma("journal_mode") == "wal")
            #expect(try await db.pragma("synchronous") == "2")  // 2 means FULL.
            #expect(try await db.pragma("foreign_keys") == "1")
        }
    }

    @Test func walModeSurvivesReopen() async throws {
        try await withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("test.sqlite").path
            try await Database(path: path).close()
            let reopened = try Database(path: path)
            #expect(try await reopened.pragma("journal_mode") == "wal")
        }
    }

    @Test func inMemoryDatabaseOpens() async throws {
        let db = try Database.inMemory()
        // In-memory databases can't use WAL; SQLite keeps them in "memory" journal mode.
        #expect(try await db.pragma("journal_mode") == "memory")
        #expect(try await db.pragma("foreign_keys") == "1")
    }

    @Test func openingInMissingDirectoryThrows() async throws {
        try await withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("missing/test.sqlite").path
            let error = #expect(throws: StorageError.self) { try Database(path: path) }
            guard case .sqlite(let code, _) = error else {
                Issue.record("expected a SQLite error, got \(String(describing: error))")
                return
            }
            #expect(code == SQLITE_CANTOPEN)
        }
    }

    @Test func closingTwiceIsSafe() async throws {
        let db = try Database.inMemory()
        await db.close()
        await db.close()
        await #expect(throws: StorageError.closed) { try await db.execute("SELECT 1") }
    }

    @Test func badSQLThrowsWithSQLiteMessage() async throws {
        let db = try Database.inMemory()
        let error = await #expect(throws: StorageError.self) {
            try await db.execute("NOT VALID SQL")
        }
        guard case .sqlite(_, let message) = error else {
            Issue.record("expected a SQLite error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("syntax error"))
    }
}
