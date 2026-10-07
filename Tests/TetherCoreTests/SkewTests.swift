// Tests for preserving what an older version doesn't understand: unknown fields merge and
// forward intact, unknown op kinds go pending without stalling sync, and an upgrade
// computes pending fields from the op log. Also the PN-Counter those tests rely on.

import Foundation
import Testing
import TetherStorage

@testable import TetherCore

private let start: UInt64 = 1_800_000_000_000
private let list = DocID(bytes: Data(repeating: 0x11, count: 16))!
private let item = DocID(bytes: Data(repeating: 0x22, count: 16))!

private func replica(_ byte: UInt8, _ manifest: SchemaManifest, path: String = ":memory:")
    async throws -> Replica
{
    try await Replica.open(
        path: path, wallClock: FakeClock(millis: start),
        replicaID: ReplicaID(bytes: Data(repeating: byte, count: 16)), manifest: manifest)
}

private func send(_ from: Replica, to: Replica) async throws {
    try await to.apply(from.database.ops(missingFrom: to.database.versionVector()))
}

private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TetherSkew-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

/// A list with one item, written by `replica`.
private func seed(_ replica: Replica) async throws {
    try await replica.perform(.createList(list, title: "Groceries"))
    try await replica.perform(.addItem(item, toList: list, title: "Milk", position: "V"))
}

private func row(_ replica: Replica, _ field: String) async throws -> StateRow? {
    try await replica.database.stateSnapshot().first { $0.docID == item && $0.field == field }
}

/// State without the `known` flag, which legitimately differs between versions.
private struct Merged: Equatable {
    let docID: DocID
    let field: String
    let value: Data
    let pending: Bool
}

private func merged(_ replica: Replica) async throws -> [Merged] {
    try await replica.database.stateSnapshot().map {
        Merged(docID: $0.docID, field: $0.field, value: $0.value, pending: $0.pending)
    }
}

@Suite struct SkewTests {
    @Test func v1ForwardsV2OpsIntact() async throws {
        let writer = try await replica(1, TaskListSchema.v2)
        let old = try await replica(2, TaskListSchema.v1)
        let reader = try await replica(3, TaskListSchema.v2)
        try await seed(writer)
        let written = try await writer.perform(.setPriority(item: item, 2))

        try await send(writer, to: old)
        // v1 merges the field by its op kind, but marks it unknown so its UI skips it.
        #expect(
            try await old.database.register(Int64.self, doc: item, field: Field.priority)?.value
                == 2)
        let priority = try #require(try await row(old, Field.priority))
        #expect(!priority.known && !priority.pending)
        #expect(try await row(old, Field.title)?.known == true)

        // The reader only ever hears from v1.
        try await send(old, to: reader)
        let forwarded = try await reader.database.ops(missingFrom: [:])
            .filter { $0.field == Field.priority }
        #expect(forwarded.map { $0.encoded() } == written.map { $0.encoded() })
        #expect(forwarded.first?.schemaVersion == 2)
        #expect(
            try await reader.database.register(Int64.self, doc: item, field: Field.priority)?.value
                == 2)
    }

    @Test func concurrentV1TitleAndV2PriorityEditsBothSurvive() async throws {
        let old = try await replica(1, TaskListSchema.v1)
        let new = try await replica(2, TaskListSchema.v2)
        try await seed(old)
        try await send(old, to: new)

        try await old.perform(.setTitle(item: item, "Oat milk"))
        try await new.perform(.setPriority(item: item, 2))
        try await send(old, to: new)
        try await send(new, to: old)

        for replica in [old, new] {
            #expect(try await replica.database.items(inList: list).map(\.title) == ["Oat milk"])
            #expect(
                try await replica.database.register(Int64.self, doc: item, field: Field.priority)?
                    .value == 2)
        }
        #expect(try await merged(old) == merged(new))
    }

    @Test func v1HoldingV3CounterOpsUpgradesToTheRightTotal() async throws {
        try await withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("store.sqlite").path
            let a = try await replica(1, TaskListSchema.v3)
            let b = try await replica(2, TaskListSchema.v3)
            try await seed(a)
            try await send(a, to: b)
            try await a.perform(.incrementViews(item: item, by: 3))
            try await a.perform(.incrementViews(item: item, by: 4))
            try await b.perform(.incrementViews(item: item, by: 5))
            try await b.perform(.incrementViews(item: item, by: -2))
            try await a.perform(.setTitle(item: item, "Oat milk"))

            let old = try await replica(9, TaskListSchema.v1, path: path)
            try await send(a, to: old)
            try await send(b, to: old)
            // The counter ops are kept but pending; everything else in the batch applied.
            #expect(try await old.database.items(inList: list).map(\.title) == ["Oat milk"])
            #expect(try await old.database.isPending(docID: item, field: Field.views))
            #expect(try await old.database.counter(doc: item, field: Field.views) == nil)
            #expect(try await old.database.ops(missingFrom: [:]).count == 10)
            try await old.database.verify()
            await #expect(
                throws: CoreError.notInManifest(field: Field.views, kind: OpKind.increment.rawValue)
            ) {
                try await old.perform(.incrementViews(item: item, by: 1))
            }
            await old.database.close()

            let upgraded = try await replica(9, TaskListSchema.v3, path: path)
            #expect(try await upgraded.database.counter(doc: item, field: Field.views)?.value == 10)
            #expect(try await !upgraded.database.isPending(docID: item, field: Field.views))

            try await send(a, to: b)
            try await send(b, to: a)
            #expect(try await a.database.counter(doc: item, field: Field.views)?.value == 10)
            #expect(try await upgraded.database.stateSnapshot() == a.database.stateSnapshot())
        }
    }

    @Test func anUnknownOpKindNeverStallsABatch() async throws {
        let replica = try await replica(1, TaskListSchema.v3)
        let author = ReplicaID(bytes: Data(repeating: 7, count: 16))!
        let future = Op(
            replicaID: author, counter: 1, hlc: start << 16, docID: item, field: "reactions",
            kind: 200, body: Data("🎉".utf8))
        let title = Op.set(
            LWWRegister(
                value: "Milk",
                stamp: Stamp(hlc: HLCTimestamp(rawValue: (start << 16) + 1), replicaID: author)),
            docID: item, field: Field.title, counter: 2)
        #expect(try await replica.apply([future, title]) == 2)
        let reactions = try #require(
            try await replica.database.stateSnapshot().first { $0.field == "reactions" })
        #expect(reactions.pending && !reactions.known)
        #expect(
            try await replica.database.register(String.self, doc: item, field: Field.title)?.value
                == "Milk")
        #expect(try await replica.database.versionVector() == [author: 2])
    }
}

private let counterReplicas = (1...3).map { ReplicaID(bytes: Data(repeating: $0, count: 16))! }

private func randomCounter(_ rng: inout SeededGenerator) -> PNCounter {
    var counter = PNCounter()
    for _ in 0..<Int.random(in: 0...4, using: &rng) {
        let replica = counterReplicas.randomElement(using: &rng) ?? counterReplicas[0]
        counter.merge(counter.adding(Int64.random(in: -50...50, using: &rng), by: replica))
    }
    return counter
}

@Suite struct PNCounterTests {
    @Test(arguments: 0..<5)
    func mergeObeysTheLaws(seed: UInt64) {
        checkLaws(seed: seed, randomCounter)
    }

    @Test func valueIsIncrementsMinusDecrements() throws {
        var counter = PNCounter()
        counter.merge(counter.adding(5, by: counterReplicas[0]))
        counter.merge(counter.adding(-2, by: counterReplicas[0]))
        counter.merge(counter.adding(4, by: counterReplicas[1]))
        #expect(counter.value == 7)
        // Re-delivering an old delta changes nothing.
        counter.merge(PNCounter().adding(5, by: counterReplicas[0]))
        #expect(counter.value == 7)
        #expect(try PNCounter(decoding: counter.encoded()) == counter)
    }
}
