// Tests for Stamp ordering, LWWRegister merge laws and ties, and the set-op encoding.

import Foundation
import Testing
import TetherStorage

@testable import TetherCore

private let low = ReplicaID(bytes: Data(repeating: 1, count: 16))!
private let high = ReplicaID(bytes: Data(repeating: 2, count: 16))!

private func stamp(_ millis: UInt64, _ replica: ReplicaID) -> Stamp {
    Stamp(hlc: HLCTimestamp(rawValue: millis << 16), replicaID: replica)
}

@Suite struct LWWRegisterTests {
    @Test func stampsOrderByHLCThenReplica() {
        #expect(stamp(1, high) < stamp(2, low))
        #expect(stamp(5, low) < stamp(5, high))
    }

    @Test(arguments: 0..<5)
    func mergeObeysTheLaws(seed: UInt64) {
        let replicas = [low, high, ReplicaID(bytes: Data(repeating: 3, count: 16))!]
        checkLaws(seed: seed) { rng in
            // Small ranges so equal stamps happen; a stamp always maps to the same value.
            let replica = replicas.randomElement(using: &rng) ?? low
            let s = stamp(UInt64.random(in: 0..<20, using: &rng), replica)
            return LWWRegister(value: "\(s.hlc.rawValue)-\(s.replicaID.bytes[0])", stamp: s)
        }
    }

    @Test func higherStampWins() {
        var register = LWWRegister(value: "old", stamp: stamp(1, high))
        register.merge(LWWRegister(value: "new", stamp: stamp(2, low)))
        #expect(register.value == "new")
        register.merge(LWWRegister(value: "stale", stamp: stamp(1, high)))
        #expect(register.value == "new")
    }

    @Test func equalHLCBreaksTiesByReplicaOnEveryReplica() {
        let fromLow = LWWRegister(value: "low", stamp: stamp(7, low))
        let fromHigh = LWWRegister(value: "high", stamp: stamp(7, high))
        #expect(merged(fromLow, fromHigh).value == "high")
        #expect(merged(fromHigh, fromLow).value == "high")
    }

    @Test func encodingRoundTripsForEveryValueType() throws {
        let s = stamp(1_800_000_000_000, high)
        let text = LWWRegister(value: "hello 🧵", stamp: s)
        #expect(try LWWRegister<String>(decoding: text.encoded()) == text)
        let flag = LWWRegister(value: true, stamp: s)
        #expect(try LWWRegister<Bool>(decoding: flag.encoded()) == flag)
        for n: Int64 in [0, 1, -1, .max, .min] {
            let number = LWWRegister(value: n, stamp: s)
            #expect(try LWWRegister<Int64>(decoding: number.encoded()) == number)
        }
        let blob = LWWRegister(value: Data([0, 255]), stamp: s)
        #expect(try LWWRegister<Data>(decoding: blob.encoded()) == blob)
    }

    @Test func truncatedOrTrailingBytesThrow() {
        let encoded = LWWRegister(value: "title", stamp: stamp(9, low)).encoded()
        for length in 0..<encoded.count {
            #expect(throws: StorageError.self) {
                try LWWRegister<String>(decoding: encoded.prefix(length))
            }
        }
        #expect(throws: StorageError.self) {
            try LWWRegister<String>(decoding: encoded + Data([0]))
        }
    }

    @Test func setOpCarriesTheRegister() throws {
        let register = LWWRegister(value: "Buy milk", stamp: stamp(42, low))
        let op = Op.set(register, docID: .random(), field: "title", counter: 3)
        #expect(op.kind == OpKind.set.rawValue)
        #expect(op.replicaID == low)
        #expect(op.hlc == register.stamp.hlc.rawValue)
        #expect(try LWWRegister<String>(decoding: op.body) == register)
        #expect(try Op(decoding: op.encoded()) == op)
    }
}
