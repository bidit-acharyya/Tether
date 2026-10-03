// Tests for varints, CRC32, and the Op binary format, including random round-trips.

import Foundation
import Testing

@testable import TetherStorage

private func randomOp(using rng: inout SeededGenerator) -> Op {
    let alphabet = Array("abcXYZ09_ ü€🧵👩🏽‍💻")
    let fieldLength = Int.random(in: 0...12, using: &rng)
    let field = String((0..<fieldLength).map { _ in alphabet.randomElement(using: &rng) ?? "a" })
    let bodyLength = Int.random(in: 0...64, using: &rng)
    let body = Data((0..<bodyLength).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    // Mix small and huge numbers so every varint length gets exercised.
    func number() -> UInt64 {
        Bool.random(using: &rng)
            ? UInt64.random(in: 0...300, using: &rng)
            : UInt64.random(in: .min ... .max, using: &rng)
    }
    return Op(
        replicaID: .random(using: &rng), counter: number(), hlc: number(),
        docID: .random(using: &rng), field: field,
        kind: UInt8.random(in: .min ... .max, using: &rng), body: body)
}

@Suite struct VarintTests {
    @Test(arguments: [
        (UInt64(0), 1), (127, 1), (128, 2), (16_383, 2), (16_384, 3), (UInt64.max, 10),
    ])
    func roundTripsWithExpectedLength(value: UInt64, length: Int) throws {
        var writer = ByteWriter()
        writer.writeVarint(value)
        #expect(writer.data.count == length)
        var reader = ByteReader(writer.data)
        #expect(try reader.readVarint() == value)
        #expect(reader.isAtEnd)
    }

    @Test func overflowIsRejected() {
        let tooBig = Data(repeating: 0xFF, count: 9) + Data([0x02])
        var reader = ByteReader(tooBig)
        #expect(throws: StorageError.invalidEncoding("varint overflows UInt64")) {
            try reader.readVarint()
        }
    }

    @Test func lengthPastEndIsTruncated() {
        var reader = ByteReader(Data([0x05, 0x01]))
        #expect(throws: StorageError.truncated) { try reader.readBytes() }
    }
}

@Suite struct CRC32Tests {
    @Test func matchesStandardCheckValue() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func emptyInputIsZero() {
        #expect(CRC32.checksum(Data()) == 0)
    }
}

@Suite struct OpFormatTests {
    @Test(arguments: 0..<10)
    func randomOpsRoundTrip(seed: UInt64) throws {
        var rng = SeededGenerator(seed: seed)
        for _ in 0..<100 {
            let op = randomOp(using: &rng)
            #expect(try Op(decoding: op.encoded()) == op, "seed \(seed)")
        }
    }

    @Test(arguments: 0..<5)
    func everyTruncationThrows(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        for _ in 0..<20 {
            let encoded = randomOp(using: &rng).encoded()
            for length in 0..<encoded.count {
                #expect(throws: StorageError.self, "seed \(seed), length \(length)") {
                    try Op(decoding: encoded.prefix(length))
                }
            }
        }
    }

    @Test func trailingBytesAreRejected() {
        var rng = SeededGenerator(seed: 42)
        let encoded = randomOp(using: &rng).encoded() + Data([0])
        #expect(throws: StorageError.invalidEncoding("trailing bytes")) {
            try Op(decoding: encoded)
        }
    }

    @Test func unknownVersionIsRejected() {
        var rng = SeededGenerator(seed: 7)
        var encoded = randomOp(using: &rng).encoded()
        encoded[encoded.startIndex] = 99
        #expect(throws: StorageError.unknownFormatVersion(99)) { try Op(decoding: encoded) }
    }

    @Test func formatStartsWithVersionByte() {
        var rng = SeededGenerator(seed: 1)
        #expect(randomOp(using: &rng).encoded().first == Op.formatVersion)
    }
}
