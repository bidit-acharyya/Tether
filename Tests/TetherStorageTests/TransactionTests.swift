// Tests for transactions, the migrator, Tether's schema, and the replica id.

import Foundation
import Testing

@testable import TetherStorage

private struct Boom: Error {}

@Suite struct TransactionTests {
    @Test func throwingRollsBack() async throws {
        let db = try Database.inMemory()
        try await db.execute("CREATE TABLE t(v INTEGER)")
        await #expect(throws: Boom.self) {
            try await db.transaction { db in
                try db.run("INSERT INTO t VALUES (1)")
                throw Boom()
            }
        }
        #expect(try await db.query("SELECT v FROM t").isEmpty)
    }

    @Test func commitSurvivesReopen() async throws {
        try await withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("test.sqlite").path
            let db = try Database(path: path)
            try await db.execute("CREATE TABLE t(v INTEGER)")
            let returned = try await db.transaction { db in
                try db.run("INSERT INTO t VALUES (?)", [.int(7)])
                return "done"
            }
            #expect(returned == "done")
            await db.close()

            let reopened = try Database(path: path)
            #expect(try await reopened.query("SELECT v FROM t").first?.int("v") == 7)
        }
    }

    @Test func transactionCanRunAgainAfterRollback() async throws {
        let db = try Database.inMemory()
        try await db.execute("CREATE TABLE t(v INTEGER)")
        try? await db.transaction { _ in throw Boom() }
        try await db.transaction { db in try db.run("INSERT INTO t VALUES (1)") }
        #expect(try await db.query("SELECT v FROM t").count == 1)
    }
}

@Suite struct MigrationTests {
    private let twoSteps: [Migration] = [
        { db in try db.execute("CREATE TABLE t(v INTEGER)") },
        { db in try db.run("INSERT INTO t VALUES (1)") },
    ]

    @Test func runsPendingMigrationsOnce() async throws {
        let db = try Database.inMemory()
        try await db.migrate(twoSteps)
        try await db.migrate(twoSteps)
        #expect(try await db.userVersion() == 2)
        #expect(try await db.query("SELECT v FROM t").count == 1)
    }

    @Test func failedMigrationLeavesNothingBehind() async throws {
        let db = try Database.inMemory()
        let broken: [Migration] = [
            { db in try db.execute("CREATE TABLE t(v INTEGER)") },
            { _ in throw Boom() },
        ]
        await #expect(throws: Boom.self) { try await db.migrate(broken) }
        #expect(try await db.userVersion() == 0)
        #expect(try await db.query("SELECT name FROM sqlite_master WHERE name = 't'").isEmpty)
    }

    @Test func newerSchemaIsRefused() async throws {
        let db = try Database.inMemory()
        try await db.migrate(twoSteps)
        await #expect(throws: StorageError.schemaTooNew(found: 2, supported: 1)) {
            try await db.migrate(Array(twoSteps.prefix(1)))
        }
    }
}

@Suite struct SchemaTests {
    @Test func freshStoreHasVersionOneAndAllTables() async throws {
        let db = try await Database.openStore(path: ":memory:")
        #expect(try await db.userVersion() == 1)
        let names = try await db.query(
            """
            SELECT name FROM sqlite_master
            WHERE type IN ('table', 'index') AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """)
        let expected = ["meta", "ops", "ops_by_hlc", "state", "version_vector"]
        #expect(try names.map { try $0.text("name") } == expected)
    }

    @Test func replicaIDIsStableAcrossReopens() async throws {
        try await withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("store.sqlite").path
            let first = try await Database.openStore(path: path)
            let id = try await first.replicaID()
            #expect(id.bytes.count == 16)
            await first.close()

            let reopened = try await Database.openStore(path: path)
            #expect(try await reopened.replicaID() == id)
            #expect(try await reopened.userVersion() == 1)
        }
    }

    @Test func separateStoresGetDifferentReplicaIDs() async throws {
        let a = try await Database.openStore(path: ":memory:")
        let b = try await Database.openStore(path: ":memory:")
        #expect(try await a.replicaID() != b.replicaID())
    }

    @Test func strictTablesRejectWrongTypes() async throws {
        let db = try await Database.openStore(path: ":memory:")
        await #expect(throws: StorageError.self) {
            try await db.run(
                "INSERT INTO version_vector VALUES (?, ?)", [.blob(Data()), .text("x")])
        }
    }
}
