// Tests for Replica: local changes, idempotent remote apply, order independence, and the
// documented answer to a delete racing an edit.

import Foundation
import Testing
import TetherStorage

@testable import TetherCore

private let start: UInt64 = 1_800_000_000_000
private let list = DocID(bytes: Data(repeating: 0x11, count: 16))!

private func replica(_ byte: UInt8, clock: FakeClock = FakeClock(millis: start)) async throws
    -> Replica
{
    try await Replica.open(
        path: ":memory:", wallClock: clock,
        replicaID: ReplicaID(bytes: Data(repeating: byte, count: 16)))
}

/// Delivers everything `from` has that `to` is missing.
private func send(_ from: Replica, to: Replica) async throws {
    let missing = try await from.database.ops(missingFrom: to.database.versionVector())
    try await to.apply(missing)
}

private func snapshot(_ replica: Replica) async throws -> [StateRow] {
    try await replica.database.stateSnapshot()
}

@Suite struct ReplicaTests {
    @Test func localChangesShowUpInOrder() async throws {
        let a = try await replica(1)
        let milk = DocID.random()
        let eggs = DocID.random()
        let first = try FractionalIndex.between(nil, nil)
        try await a.perform(.createList(list, title: "Groceries"))
        try await a.perform(.addItem(milk, toList: list, title: "Milk", position: first))
        try await a.perform(
            .addItem(
                eggs, toList: list, title: "Eggs", position: try FractionalIndex.between(nil, first)
            ))
        try await a.perform(.setDone(item: milk, true))
        try await a.perform(.addTag(item: milk, "dairy"))

        let items = try await a.database.items(inList: list)
        #expect(items.map(\.title) == ["Eggs", "Milk"])
        #expect(items[1].done)
        #expect(items[1].tags == ["dairy"])
        #expect(try await a.database.listTitle(list) == "Groceries")
        try await a.database.verify()
    }

    @Test func applyingTheSameOpsTwiceChangesNothing() async throws {
        let a = try await replica(1)
        let b = try await replica(2)
        let ops =
            try await a.perform(.createList(list, title: "Groceries"))
            + a.perform(.addItem(.random(), toList: list, title: "Milk", position: "V"))
        #expect(try await b.apply(ops) == ops.count)
        let once = try await snapshot(b)
        #expect(try await b.apply(ops) == 0)
        #expect(try await b.apply(ops.reversed()) == 0)
        #expect(try await snapshot(b) == once)
    }

    @Test func localThenRemoteEqualsRemoteThenLocal() async throws {
        let a = try await replica(1)
        let b = try await replica(2)
        let item = DocID.random()
        let setup =
            try await a.perform(.createList(list, title: "List"))
            + a.perform(.addItem(item, toList: list, title: "Draft", position: "V"))
        try await b.apply(setup)

        // Concurrent edits to the same and different fields.
        let fromA =
            try await a.perform(.setTitle(item: item, "A's title"))
            + a.perform(.addTag(item: item, "home"))
        let fromB =
            try await b.perform(.setTitle(item: item, "B's title"))
            + b.perform(.setDone(item: item, true))

        let c = try await replica(3)
        let d = try await replica(4)
        try await c.apply(setup + fromA + fromB)
        try await d.apply(setup + fromB + fromA)
        try await a.apply(fromB)
        try await b.apply(fromA)
        let expected = try await snapshot(a)
        #expect(try await snapshot(b) == expected)
        #expect(try await snapshot(c) == expected)
        #expect(try await snapshot(d) == expected)
        let merged = try #require(try await a.database.items(inList: list).first)
        #expect(merged.done && merged.tags == ["home"])
    }

    /// Documented answer: delete wins. The concurrent edit is kept in the log and in state
    /// but hidden, and no later-arriving edit can bring the item back.
    @Test func deleteRacingAnEditKeepsTheItemDeleted() async throws {
        let a = try await replica(1)
        let b = try await replica(2)
        let item = DocID.random()
        try await b.apply(
            try await a.perform(.createList(list, title: "List"))
                + a.perform(.addItem(item, toList: list, title: "Old", position: "V")))

        let delete = try await a.perform(.deleteItem(item, fromList: list))
        let edit = try await b.perform(.setTitle(item: item, "Edited"))
        try await a.apply(edit)
        try await b.apply(delete)

        for replica in [a, b] {
            #expect(try await replica.database.items(inList: list).isEmpty)
            let title = try await replica.database.register(
                String.self, doc: item, field: Field.title)
            #expect(title?.value == "Edited")
        }
        #expect(try await snapshot(a) == snapshot(b))

        // An edit arriving after the delete is applied still can't resurrect the item.
        let late = try await b.perform(.setDone(item: item, true))
        try await a.apply(late)
        #expect(try await a.database.items(inList: list).isEmpty)
    }

    @Test func concurrentTagAddAndRemoveKeepsTheTag() async throws {
        let a = try await replica(1)
        let b = try await replica(2)
        let item = DocID.random()
        try await b.apply(
            try await a.perform(.createList(list, title: "List"))
                + a.perform(.addItem(item, toList: list, title: "Milk", position: "V"))
                + a.perform(.addTag(item: item, "urgent")))
        let removal = try await a.perform(.removeTag(item: item, "urgent"))
        let readd = try await b.perform(.addTag(item: item, "urgent"))
        try await a.apply(readd)
        try await b.apply(removal)
        #expect(try await a.database.items(inList: list).first?.tags == ["urgent"])
        #expect(try await snapshot(a) == snapshot(b))
    }

    @Test func remoteOpsFarInTheFutureAreRejected() async throws {
        let future = FakeClock(millis: start + 10 * 60 * 1000)
        let ahead = try await replica(1, clock: future)
        let b = try await replica(2)
        let ops = try await ahead.perform(.createList(list, title: "From the future"))
        await #expect(throws: ClockError.self) { try await b.apply(ops) }
        #expect(try await snapshot(b).isEmpty)
    }

    @Test func stateAlwaysMatchesARebuild() async throws {
        let a = try await replica(1)
        let b = try await replica(2)
        let item = DocID.random()
        try await a.perform(.createList(list, title: "List"))
        try await a.perform(.addItem(item, toList: list, title: "Milk", position: "V"))
        try await send(a, to: b)
        try await b.perform(.addTag(item: item, "x"))
        try await a.perform(.deleteItem(item, fromList: list))
        try await send(a, to: b)
        try await send(b, to: a)
        try await a.database.verify()
        try await b.database.verify()
        #expect(try await snapshot(a) == snapshot(b))
    }

    @Test func reopeningKeepsDataAndTheClockMovesForward() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TetherReplica-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path
        let clock = FakeClock(millis: start)

        let first = try await Replica.open(path: path, wallClock: clock)
        let before = try await first.perform(.createList(list, title: "Kept"))
        await first.database.close()

        clock.advance(by: -60_000)
        let reopened = try await Replica.open(path: path, wallClock: clock)
        #expect(reopened.id == first.id)
        #expect(try await reopened.database.listTitle(list) == "Kept")
        let after = try await reopened.perform(.renameList(list, title: "Renamed"))
        #expect(after[0].hlc > before[0].hlc)
        #expect(after[0].counter == before[0].counter + 1)
        #expect(try await reopened.database.listTitle(list) == "Renamed")
    }
}
