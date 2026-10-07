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
    // Half the ops are format 1 (no extensions), half format 2 with a few random tags.
    var extensions: [UInt64: Data] = [:]
    if Bool.random(using: &rng) {
        for _ in 0..<Int.random(in: 1...3, using: &rng) {
            let length = Int.random(in: 0...8, using: &rng)
            extensions[number()] = Data(
                (0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) })
        }
    }
    return Op(
        replicaID: .random(using: &rng), counter: number(), hlc: number(),
        docID: .random(using: &rng), field: field,
        kind: UInt8.random(in: .min ... .max, using: &rng), body: body, extensions: extensions)
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

    @Test func opsWithoutExtensionsStayFormatOne() {
        var rng = SeededGenerator(seed: 1)
        var op = randomOp(using: &rng)
        op.extensions = [:]
        #expect(op.encoded().first == 1)
        op.schemaVersion = 2
        #expect(op.encoded().first == 2)
    }

    /// Bytes laid out exactly as Week 1's format-1 encoder wrote them.
    @Test func formatOneBytesStillDecode() throws {
        let replica = ReplicaID(bytes: Data(repeating: 0xAB, count: 16))!
        let doc = DocID(bytes: Data(repeating: 0xCD, count: 16))!
        var writer = ByteWriter()
        writer.write(1)
        writer.writeFixed(replica.bytes)
        writer.writeVarint(7)
        writer.writeVarint(1_234_567)
        writer.writeFixed(doc.bytes)
        writer.writeString("title")
        writer.write(1)
        writer.writeBytes(Data("body".utf8))

        let op = try Op(decoding: writer.data)
        #expect(op.counter == 7 && op.hlc == 1_234_567 && op.field == "title")
        #expect(op.schemaVersion == nil)
        #expect(op.encoded() == writer.data)
    }

    /// An older device must forward a newer op without losing what it can't read.
    @Test func unknownExtensionsSurviveReencoding() throws {
        var rng = SeededGenerator(seed: 3)
        var op = randomOp(using: &rng)
        op.extensions = [99: Data([1, 2, 3]), 12_345: Data()]
        op.schemaVersion = 3
        let bytes = op.encoded()
        let forwarded = try Op(decoding: bytes)
        #expect(forwarded.extensions[99] == Data([1, 2, 3]))
        #expect(forwarded.schemaVersion == 3)
        #expect(forwarded.encoded() == bytes)
    }

    @Test func duplicateExtensionTagsAreRejected() throws {
        var rng = SeededGenerator(seed: 4)
        var op = randomOp(using: &rng)
        op.extensions = [5: Data([1])]
        var bytes = op.encoded()
        // Rewrite the extension count from 1 to 2 and repeat the (5, [1]) entry.
        let entry = bytes.suffix(3)
        bytes.removeLast(4)
        bytes.append(2)
        bytes.append(contentsOf: entry + entry)
        #expect(throws: StorageError.invalidEncoding("duplicate extension tag")) {
            try Op(decoding: bytes)
        }
    }
}
