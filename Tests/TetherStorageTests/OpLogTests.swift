// Tests for the write path: append, state, rebuild, version vectors, and missing ops.

import Foundation
import Testing

@testable import TetherStorage

private func makeOp(_ replica: ReplicaID, _ counter: UInt64, hlc: UInt64, body: UInt8) -> Op {
    Op(
        replicaID: replica, counter: counter, hlc: hlc, docID: DocID(bytes: Data(count: 16))!,
        field: "title", kind: 0, body: Data([body]))
}

@Suite struct OpLogTests {
    @Test(arguments: 0..<10)
    func stateMatchesRebuild(seed: UInt64) async throws {
        var rng = SeededGenerator(seed: seed)
        let db = try await Database.openStore(path: ":memory:")
        for op in randomHistory(count: 100, using: &rng).shuffled(using: &rng) {
            try await db.append(op)
        }
        let live = try await db.stateSnapshot()
        try await db.rebuildState()
        #expect(try await db.stateSnapshot() == live, "seed \(seed)")
    }

    @Test(arguments: 0..<5)
    func appendOrderDoesNotMatter(seed: UInt64) async throws {
        var rng = SeededGenerator(seed: seed)
        let history = randomHistory(count: 100, using: &rng)
        let a = try await Database.openStore(path: ":memory:")
        let b = try await Database.openStore(path: ":memory:")
        try await a.append(history)
        try await b.append(history.shuffled(using: &rng))
        #expect(try await a.stateSnapshot() == b.stateSnapshot(), "seed \(seed)")
        #expect(try await a.versionVector() == b.versionVector(), "seed \(seed)")
    }

    /// Regression: seed 3 of appendOrderDoesNotMatter once failed because the generator let
    /// one replica write twice with the same HLC, which a real clock never does.
    @Test(arguments: 0..<20)
    func generatedHistoriesNeverReuseAStamp(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let history = randomHistory(count: 200, using: &rng)
        let stamps = history.map { "\($0.replicaID.bytes.base64EncodedString())-\($0.hlc)" }
        #expect(Set(stamps).count == history.count, "seed \(seed)")
    }

    @Test func reappendingIsIgnored() async throws {
        var rng = SeededGenerator(seed: 1)
        let db = try await Database.openStore(path: ":memory:")
        let history = randomHistory(count: 20, using: &rng)
        #expect(try await db.append(history) == 20)
        let before = try await db.stateSnapshot()
        #expect(try await db.append(history) == 0)
        #expect(try await db.append(history[0]) == false)
        #expect(try await db.stateSnapshot() == before)
        #expect(try await db.query("SELECT counter FROM ops").count == 20)
    }

    @Test func higherHLCWinsAndTiesGoToHigherReplica() async throws {
        let low = ReplicaID(bytes: Data(repeating: 1, count: 16))!
        let high = ReplicaID(bytes: Data(repeating: 2, count: 16))!
        let db = try await Database.openStore(path: ":memory:")
        try await db.append([makeOp(low, 1, hlc: 10, body: 1), makeOp(high, 1, hlc: 5, body: 2)])
        #expect(try await db.stateSnapshot().first?.value == Data([1]))
        try await db.append([makeOp(high, 2, hlc: 10, body: 3), makeOp(low, 2, hlc: 9, body: 4)])
        #expect(try await db.stateSnapshot().first?.value == Data([3]))
    }

    @Test func versionVectorCountsOnlyTheContiguousPrefix() async throws {
        let a = ReplicaID.random()
        let b = ReplicaID.random()
        let db = try await Database.openStore(path: ":memory:")
        try await db.append([makeOp(a, 2, hlc: 1, body: 0), makeOp(a, 1, hlc: 1, body: 0)])
        try await db.append(makeOp(b, 5, hlc: 1, body: 0))
        #expect(try await db.versionVector() == [a: 2])  // b's 1...4 are missing.

        // A peer that has nothing must still be offered b's ops once the gap fills.
        try await db.append((1...3).map { makeOp(b, $0, hlc: 1, body: 0) })
        #expect(try await db.versionVector() == [a: 2, b: 3])
        #expect(try await db.ops(missingFrom: [:]).filter { $0.replicaID == b }.count == 3)
        try await db.append(makeOp(b, 4, hlc: 1, body: 0))
        #expect(try await db.versionVector() == [a: 2, b: 5])
        try await db.verify()
    }

    @Test func longRunsOfOutOfOrderOpsAdvanceTheVector() async throws {
        let a = ReplicaID.random()
        let db = try await Database.openStore(path: ":memory:")
        try await db.append((2...300).reversed().map { makeOp(a, UInt64($0), hlc: 1, body: 0) })
        #expect(try await db.versionVector().isEmpty)
        try await db.append(makeOp(a, 1, hlc: 1, body: 0))
        #expect(try await db.versionVector() == [a: 300])
        try await db.verify()
    }

    @Test func nextCounterFollowsOwnOps() async throws {
        let db = try await Database.openStore(path: ":memory:")
        let own = try await db.replicaID()
        #expect(try await db.nextCounter() == 1)
        try await db.append(makeOp(own, 1, hlc: 1, body: 0))
        try await db.append(makeOp(ReplicaID.random(), 9, hlc: 1, body: 0))
        #expect(try await db.nextCounter() == 2)
    }

    @Test func missingOpsAreExactlyWhatThePeerLacks() async throws {
        let a = ReplicaID.random()
        let b = ReplicaID.random()
        let db = try await Database.openStore(path: ":memory:")
        let opsA = (1...4).map { makeOp(a, $0, hlc: $0, body: 0) }
        let opsB = (1...2).map { makeOp(b, $0, hlc: $0, body: 0) }
        try await db.append(opsA + opsB)

        let missing = try await db.ops(missingFrom: [a: 2])
        #expect(Set(missing.map { "\($0.replicaID.bytes)-\($0.counter)" }).count == 4)
        #expect(missing.filter { $0.replicaID == a }.map(\.counter) == [3, 4])
        #expect(missing.filter { $0.replicaID == b }.map(\.counter) == [1, 2])
        #expect(try await db.ops(missingFrom: [a: 4, b: 2]).isEmpty)
    }

    @Test func storedStateSurvivesReopen() async throws {
        try await withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("store.sqlite").path
            var rng = SeededGenerator(seed: 3)
            let db = try await Database.openStore(path: path)
            try await db.append(randomHistory(count: 50, using: &rng))
            let before = try await db.stateSnapshot()
            await db.close()

            let reopened = try await Database.openStore(path: path)
            #expect(try await reopened.stateSnapshot() == before)
        }
    }

    @Test func hlcAboveInt64MaxIsRejected() async throws {
        let db = try await Database.openStore(path: ":memory:")
        let op = makeOp(ReplicaID.random(), 1, hlc: .max, body: 0)
        await #expect(throws: StorageError.valueTooLarge("hlc")) { try await db.append(op) }
        #expect(try await db.stateSnapshot().isEmpty)
    }
}
