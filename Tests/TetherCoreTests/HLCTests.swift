// Tests for the hybrid logical clock: ordering, monotonicity, skew guard, persistence.

import Foundation
import Testing
import TetherStorage

@testable import TetherCore

private let start: UInt64 = 1_800_000_000_000  // A 2027 wall time in ms.

private func stamp(_ millis: UInt64, _ counter: UInt16) -> HLCTimestamp {
    HLCTimestamp(rawValue: millis << 16 | UInt64(counter))
}

@Suite struct HLCTimestampTests {
    @Test func packAndUnpackRoundTrip() throws {
        let t = stamp(start, 513)
        #expect(t.millis == start)
        #expect(t.counter == 513)
        #expect(HLCTimestamp(rawValue: t.rawValue) == t)
    }

    @Test func ordersByMillisThenCounter() throws {
        #expect(stamp(10, 0xFFFF) < stamp(11, 0))
        #expect(stamp(10, 1) < stamp(10, 2))
    }

    @Test func millisBeyond48BitsAreRejected() {
        #expect(throws: ClockError.wallClockOutOfRange) {
            try HLCTimestamp(millis: HLCTimestamp.maxMillis + 1, counter: 0)
        }
    }
}

@Suite struct HybridLogicalClockTests {
    @Test func tickFollowsTheWallClock() throws {
        let wall = FakeClock(millis: start)
        var clock = HybridLogicalClock(wallClock: wall)
        #expect(try clock.tick() == stamp(start, 0))
        #expect(try clock.tick() == stamp(start, 1))
        wall.advance(by: 5)
        #expect(try clock.tick() == stamp(start + 5, 0))
    }

    @Test func staysStrictlyIncreasingWhenWallClockJumpsBack() throws {
        let wall = FakeClock(millis: start)
        var clock = HybridLogicalClock(wallClock: wall)
        var previous = try clock.tick()
        for jump: Int64 in [-60_000, -1, 3, -3_600_000, 0, 10_000] {
            wall.advance(by: jump)
            let next = try clock.tick()
            #expect(next > previous, "jump \(jump)")
            previous = next
        }
    }

    @Test func receiveLandsPastRemoteAndLocal() throws {
        let wall = FakeClock(millis: start)
        var clock = HybridLogicalClock(wallClock: wall)
        let local = try clock.tick()

        let ahead = stamp(start + 2_000, 7)
        let afterAhead = try clock.receive(ahead)
        #expect(afterAhead == stamp(start + 2_000, 8))

        let behind = stamp(start - 10_000, 99)
        let afterBehind = try clock.receive(behind)
        #expect(afterBehind > afterAhead)
        #expect(afterBehind > local)
    }

    @Test func receiveWithSameMillisTakesTheHigherCounter() throws {
        let wall = FakeClock(millis: start)
        var clock = HybridLogicalClock(wallClock: wall)
        _ = try clock.tick()
        #expect(try clock.receive(stamp(start, 40)) == stamp(start, 41))
    }

    @Test func remoteTooFarAheadIsRejectedAndChangesNothing() throws {
        let wall = FakeClock(millis: start)
        var clock = HybridLogicalClock(wallClock: wall)
        let before = try clock.tick()
        let limit = start + HybridLogicalClock.maxSkewMillis

        #expect(throws: ClockError.remoteTooFarAhead(millis: limit + 1)) {
            try clock.receive(stamp(limit + 1, 0))
        }
        #expect(clock.last == before)
        #expect(try clock.receive(stamp(limit, 0)) == stamp(limit, 1))
    }

    @Test func counterOverflowThrows() throws {
        let wall = FakeClock(millis: start)
        var clock = HybridLogicalClock(wallClock: wall, last: stamp(start, .max))
        #expect(throws: ClockError.counterOverflow) { try clock.tick() }
    }
}

@Suite struct HLCPersistenceTests {
    @Test func restartWithBackwardClockNeverIssuesASmallerTimestamp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TetherHLC-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path

        let wall = FakeClock(millis: start)
        var clock = HybridLogicalClock(wallClock: wall)
        var issued = try clock.tick()
        for _ in 0..<10 { issued = try clock.tick() }
        let db = try await Database.openStore(path: path)
        try await db.saveHLC(issued)
        await db.close()

        wall.advance(by: -3_600_000)
        let reopened = try await Database.openStore(path: path)
        var restarted = HybridLogicalClock(wallClock: wall, last: try await reopened.lastHLC())
        #expect(try restarted.tick() > issued)
    }

    @Test func lastHLCFallsBackToTheNewestOp() async throws {
        let db = try await Database.openStore(path: ":memory:")
        #expect(try await db.lastHLC() == HLCTimestamp(rawValue: 0))
        let newest = stamp(start, 3)
        let op = Op(
            replicaID: try await db.replicaID(), counter: 1, hlc: newest.rawValue,
            docID: .random(), field: "title", kind: 0, body: Data())
        try await db.append(op)
        #expect(try await db.lastHLC() == newest)
        try await db.saveHLC(stamp(start - 1, 0))
        #expect(try await db.lastHLC() == newest)
    }
}
