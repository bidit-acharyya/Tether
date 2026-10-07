// Tests for reading and writing through the manifest: rename lenses, read-time defaults,
// type checks, and deterministic migrations.

import Foundation
import Testing
import TetherStorage

@testable import TetherCore

private let start: UInt64 = 1_800_000_000_000
private let list = DocID(bytes: Data(repeating: 0x11, count: 16))!
private let item = DocID(bytes: Data(repeating: 0x22, count: 16))!

private func replica(_ byte: UInt8, _ manifest: SchemaManifest) async throws -> Replica {
    try await Replica.open(
        path: ":memory:", wallClock: FakeClock(millis: start),
        replicaID: ReplicaID(bytes: Data(repeating: byte, count: 16)), manifest: manifest)
}

private func send(_ from: Replica, to: Replica) async throws {
    try await to.apply(from.database.ops(missingFrom: to.database.versionVector()))
}

private func seed(_ replica: Replica) async throws {
    try await replica.perform(.createList(list, title: "Groceries"))
    try await replica.perform(.addItem(item, toList: list, title: "Milk", position: "V"))
}

private let explicitPriority = DataMigration(
    id: "2026-10-explicit-priority", field: Field.priority, value: TaskListSchema.mediumPriority,
    schemaVersion: 2)

@Suite struct LensTests {
    @Test func v1TitleIsV3NameAndBack() async throws {
        let old = try await replica(1, TaskListSchema.v1)
        let new = try await replica(3, TaskListSchema.v3)
        try await seed(old)
        try await old.perform(.setTitle(item: item, "Oat milk"))
        try await send(old, to: new)
        #expect(try await new.read(String.self, "name", of: item, in: "item") == "Oat milk")
        await #expect(throws: CoreError.unknownField("title")) {
            try await new.read(String.self, "title", of: item, in: "item")
        }

        let written = try await new.perform(.set(item, type: "item", field: "name", to: "Soy milk"))
        #expect(written.map(\.field) == [Field.title])
        try await send(new, to: old)
        #expect(try await old.database.items(inList: list).map(\.title) == ["Soy milk"])
        // Lists weren't renamed.
        #expect(try await new.read(String.self, "title", of: list, in: "list") == "Groceries")
    }

    @Test func defaultsAreReadNotWritten() async throws {
        let replica = try await replica(1, TaskListSchema.v2)
        try await seed(replica)
        let before = try await replica.database.ops(missingFrom: [:]).count
        #expect(
            try await replica.read(Int64.self, "priority", of: item, in: "item")
                == TaskListSchema.mediumPriority)
        #expect(try await replica.database.ops(missingFrom: [:]).count == before)
        #expect(try await replica.database.stateValue(docID: item, field: Field.priority) == nil)

        try await replica.perform(.set(item, type: "item", field: "priority", to: Int64(2)))
        #expect(try await replica.read(Int64.self, "priority", of: item, in: "item") == 2)
    }

    @Test func wrongTypesAndUnknownNamesAreRefused() async throws {
        let v1 = try await replica(1, TaskListSchema.v1)
        let v2 = try await replica(2, TaskListSchema.v2)
        await #expect(throws: CoreError.unknownField("priority")) {
            try await v1.read(Int64.self, "priority", of: item, in: "item")
        }
        await #expect(throws: CoreError.typeMismatch("priority")) {
            try await v2.read(String.self, "priority", of: item, in: "item")
        }
        await #expect(throws: CoreError.typeMismatch("priority")) {
            try await v2.perform(.set(item, type: "item", field: "priority", to: "high"))
        }
        await #expect(throws: CoreError.typeMismatch("tags")) {
            try await v2.perform(.set(item, type: "item", field: "tags", to: "x"))
        }
        #expect(try await v2.database.ops(missingFrom: [:]).isEmpty)
    }

    @Test func countersReadThroughTheLens() async throws {
        let replica = try await replica(1, TaskListSchema.v3)
        try await seed(replica)
        #expect(try await replica.read(Int64.self, "views", of: item, in: "item") == nil)
        try await replica.perform(.incrementViews(item: item, by: 3))
        #expect(try await replica.read(Int64.self, "views", of: item, in: "item") == 3)
    }
}

@Suite struct DataMigrationTests {
    @Test func twoDevicesMigratingTheSameDocumentProduceOneOp() async throws {
        let a = try await replica(1, TaskListSchema.v2)
        let b = try await replica(2, TaskListSchema.v2)
        try await seed(a)
        try await send(a, to: b)

        #expect(try await a.migrate(explicitPriority, documents: [item]) == 1)
        #expect(try await b.migrate(explicitPriority, documents: [item]) == 1)
        let author = explicitPriority.author(of: item)
        let fromA = try await a.database.ops(missingFrom: [:]).filter { $0.replicaID == author }
        let fromB = try await b.database.ops(missingFrom: [:]).filter { $0.replicaID == author }
        #expect(fromA.count == 1)
        #expect(fromA.map { $0.encoded() } == fromB.map { $0.encoded() })

        try await send(a, to: b)
        try await send(b, to: a)
        for replica in [a, b] {
            let ops = try await replica.database.ops(missingFrom: [:])
            #expect(ops.filter { $0.replicaID == author }.count == 1)
            #expect(try await replica.migrate(explicitPriority, documents: [item]) == 0)
        }
        #expect(try await a.database.stateSnapshot() == b.database.stateSnapshot())
    }

    @Test func aRealEditBeatsTheMigration() async throws {
        let a = try await replica(1, TaskListSchema.v2)
        let b = try await replica(2, TaskListSchema.v2)
        try await seed(a)
        try await a.perform(.setPriority(item: item, 2))
        try await b.migrate(explicitPriority, documents: [item])
        try await send(a, to: b)
        try await send(b, to: a)
        for replica in [a, b] {
            #expect(try await replica.read(Int64.self, "priority", of: item, in: "item") == 2)
        }
    }

    @Test func authorsDifferPerDocumentAndPerMigration() {
        let other = DocID(bytes: Data(repeating: 0x33, count: 16))!
        let renamed = DataMigration(
            id: "another", field: Field.priority, value: Int64(0), schemaVersion: 2)
        #expect(explicitPriority.author(of: item) != explicitPriority.author(of: other))
        #expect(explicitPriority.author(of: item) != renamed.author(of: item))
        #expect(explicitPriority.op(for: item) == explicitPriority.op(for: item))
    }

    @Test func migrationsMustFitTheManifest() async throws {
        let v1 = try await replica(1, TaskListSchema.v1)
        await #expect(throws: CoreError.unknownField(Field.priority)) {
            try await v1.migrate(explicitPriority, documents: [item])
        }
        let wrongType = DataMigration(id: "bad", field: Field.done, value: "yes", schemaVersion: 1)
        await #expect(throws: CoreError.typeMismatch(Field.done)) {
            try await v1.migrate(wrongType, documents: [item])
        }
    }
}
