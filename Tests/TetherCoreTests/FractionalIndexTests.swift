// Tests for fractional indexing: keys stay strictly ordered, and concurrent edits converge.

import Foundation
import Testing
import TetherStorage

@testable import TetherCore

@Suite struct FractionalIndexTests {
    @Test func firstKeyAndEnds() throws {
        let first = try FractionalIndex.between(nil, nil)
        #expect(try FractionalIndex.between(nil, first) < first)
        #expect(try FractionalIndex.between(first, nil) > first)
    }

    @Test(arguments: 0..<3)
    func tenThousandRandomInsertsStayStrictlyOrdered(seed: UInt64) throws {
        var rng = SeededGenerator(seed: seed)
        var keys: [String] = []
        for _ in 0..<10_000 {
            let slot = Int.random(in: 0...keys.count, using: &rng)
            let lower = slot > 0 ? keys[slot - 1] : nil
            let upper = slot < keys.count ? keys[slot] : nil
            let key = try FractionalIndex.between(lower, upper)
            if let lower { #expect(lower < key, "seed \(seed)") }
            if let upper { #expect(key < upper, "seed \(seed)") }
            keys.insert(key, at: slot)
        }
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
        let average = Double(keys.map(\.utf8.count).reduce(0, +)) / Double(keys.count)
        let longest = keys.map(\.count).max() ?? 0
        print("fractional index, seed \(seed): average key length \(average), max \(longest)")
    }

    @Test func appendingAndPrependingGrowSlowly() throws {
        var last: String?
        var first: String?
        for _ in 0..<1_000 {
            let next = try FractionalIndex.between(last, nil)
            if let last { #expect(last < next) }
            last = next
            let previous = try FractionalIndex.between(nil, first)
            if let first { #expect(previous < first) }
            first = previous
        }
        print("1,000 appends: \(last?.count ?? 0) chars; 1,000 prepends: \(first?.count ?? 0)")
        #expect((last?.count ?? 0) <= 40)
        #expect((first?.count ?? 0) <= 40)
    }

    @Test func rejectsBadInput() {
        #expect(throws: FractionalIndexError.keysOutOfOrder("b", "a")) {
            try FractionalIndex.between("b", "a")
        }
        #expect(throws: FractionalIndexError.self) { try FractionalIndex.between("a", "a") }
        #expect(throws: FractionalIndexError.invalidKey("a0")) {
            try FractionalIndex.between("a0", nil)
        }
        #expect(throws: FractionalIndexError.invalidKey("a-b")) {
            try FractionalIndex.between(nil, "a-b")
        }
    }

    @Test func concurrentMovesOfOneItemConverge() throws {
        let a = ReplicaID(bytes: Data(repeating: 1, count: 16))!
        let b = ReplicaID(bytes: Data(repeating: 2, count: 16))!
        let start = try FractionalIndex.between(nil, nil)
        let base = LWWRegister(
            value: start, stamp: Stamp(hlc: HLCTimestamp(rawValue: 1), replicaID: a))

        // A moves the item to the front, B moves it to the back, at the same time.
        let toFront = LWWRegister(
            value: try FractionalIndex.between(nil, start),
            stamp: Stamp(hlc: HLCTimestamp(rawValue: 5), replicaID: a))
        let toBack = LWWRegister(
            value: try FractionalIndex.between(start, nil),
            stamp: Stamp(hlc: HLCTimestamp(rawValue: 5), replicaID: b))
        let onA = merged(merged(base, toFront), toBack)
        let onB = merged(merged(base, toBack), toFront)
        #expect(onA == onB)
        #expect(onA.value == toBack.value)  // Same hlc, so the higher replica id wins.
    }

    @Test func concurrentInsertsAtTheSameSpotBothSurviveInStableOrder() throws {
        let before = try FractionalIndex.between(nil, nil)
        let after = try FractionalIndex.between(before, nil)
        // Two devices insert between the same neighbours and get the same key.
        let keyA = try FractionalIndex.between(before, after)
        let keyB = try FractionalIndex.between(before, after)
        #expect(keyA == keyB)

        let itemA = DocID(bytes: Data(repeating: 0xAA, count: 16))!
        let itemB = DocID(bytes: Data(repeating: 0xBB, count: 16))!
        let order1 = FractionalIndex.sorted([(itemB, keyB), (itemA, keyA)])
        let order2 = FractionalIndex.sorted([(itemA, keyA), (itemB, keyB)])
        #expect(order1 == [itemA, itemB])
        #expect(order1 == order2)
    }
}
