// Round-trip tests for SQLValue binding/reading, Row getters, and the statement cache.

import Foundation
import Testing

@testable import TetherStorage

@Suite struct StatementTests {
    /// Stores `value` in an untyped column and reads it back.
    private func roundTrip(_ value: SQLValue) async throws -> SQLValue {
        let db = try Database.inMemory()
        try await db.execute("CREATE TABLE t(v)")
        try await db.run("INSERT INTO t(v) VALUES (?)", [value])
        return try await db.query("SELECT v FROM t").first?.value("v") ?? .null
    }

    @Test(arguments: [
        SQLValue.int(42), .int(0), .int(.max), .int(.min),
        .double(3.25), .double(.infinity), .double(-.infinity),
        .text("hello"), .text(""), .text("emoji 🧵👩🏽‍💻 ü"), .text("nul\0inside"),
        .blob(Data([0, 1, 2, 255])), .blob(Data()),
        .null,
    ])
    func valueRoundTrips(_ value: SQLValue) async throws {
        #expect(try await roundTrip(value) == value)
    }

    @Test func negativeZeroKeepsItsSign() async throws {
        guard case .double(let v) = try await roundTrip(.double(-0.0)) else {
            Issue.record("expected a double")
            return
        }
        #expect(v.sign == .minus)
    }

    @Test func nanIsStoredAsNull() async throws {
        // SQLite has no NaN; it stores NULL instead.
        #expect(try await roundTrip(.double(.nan)) == .null)
    }

    @Test func boundTextOutlivesTheSwiftString() async throws {
        let db = try Database.inMemory()
        try await db.execute("CREATE TABLE t(i INTEGER, v TEXT)")
        for i in 0..<200 {
            try await db.run("INSERT INTO t VALUES (?, ?)", [.int(Int64(i)), .text("row-\(i)")])
        }
        let rows = try await db.query("SELECT i, v FROM t ORDER BY i")
        #expect(try rows.map { try $0.text("v") } == (0..<200).map { "row-\($0)" })
    }

    @Test func typedGettersThrowOnMismatch() async throws {
        let db = try Database.inMemory()
        let row = try #require(try await db.query("SELECT 1 AS n, 'x' AS s").first)
        #expect(try row.int("n") == 1)
        #expect(try row.text("s") == "x")
        #expect(throws: StorageError.typeMismatch(column: "n")) { try row.text("n") }
        #expect(throws: StorageError.noSuchColumn("missing")) { try row.int("missing") }
    }

    @Test func wrongParameterCountThrows() async throws {
        let db = try Database.inMemory()
        await #expect(throws: StorageError.parameterCount(expected: 2, actual: 1)) {
            try await db.query("SELECT ?, ?", [.int(1)])
        }
    }

    @Test func statementsAreCachedAndReusable() async throws {
        let db = try Database.inMemory()
        for i in 0..<5 {
            let rows = try await db.query("SELECT ? AS v", [.int(Int64(i))])
            #expect(try rows.first?.int("v") == Int64(i))
        }
        #expect(await db.cachedStatementCount == 1)
    }

    @Test func failedStatementCanBeReused() async throws {
        let db = try Database.inMemory()
        try await db.execute("CREATE TABLE t(id INTEGER PRIMARY KEY)")
        try await db.run("INSERT INTO t VALUES (?)", [.int(1)])
        await #expect(throws: StorageError.self) {
            try await db.run("INSERT INTO t VALUES (?)", [.int(1)])
        }
        try await db.run("INSERT INTO t VALUES (?)", [.int(2)])
        #expect(try await db.query("SELECT id FROM t").count == 2)
    }

    @Test func closeFinalizesCachedStatements() async throws {
        let db = try Database.inMemory()
        _ = try await db.query("SELECT 1")
        await db.close()
        #expect(await db.cachedStatementCount == 0)
        await #expect(throws: StorageError.closed) { try await db.query("SELECT 1") }
    }
}
