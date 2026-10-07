// Tests for version vectors, message encoding, and the in-memory transport.

import Foundation
import Testing
import TetherCore
import TetherStorage

@testable import TetherSync

private let a = ReplicaID(bytes: Data(repeating: 1, count: 16))!
private let b = ReplicaID(bytes: Data(repeating: 2, count: 16))!
private let c = ReplicaID(bytes: Data(repeating: 3, count: 16))!

@Suite struct VersionVectorTests {
    @Test func equalVectors() {
        let v = VersionVector([a: 3, b: 1])
        #expect(v.compare(to: VersionVector([a: 3, b: 1])) == .equal)
        #expect(v.missing(from: v).isEmpty)
    }

    @Test func oneAhead() {
        let ahead = VersionVector([a: 5, b: 1])
        let behind = VersionVector([a: 2])
        #expect(ahead.compare(to: behind) == .ahead)
        #expect(behind.compare(to: ahead) == .behind)
        #expect(ahead.missing(from: behind) == [a: 3...5, b: 1...1])
        #expect(behind.missing(from: ahead).isEmpty)
    }

    @Test func concurrent() {
        let left = VersionVector([a: 4, b: 1])
        let right = VersionVector([a: 2, c: 7])
        #expect(left.compare(to: right) == .concurrent)
        #expect(left.missing(from: right) == [a: 3...4, b: 1...1])
        #expect(right.missing(from: left) == [c: 1...7])
        var merged = left
        merged.merge(right)
        #expect(merged == VersionVector([a: 4, b: 1, c: 7]))
        #expect(merged.dominates(left) && merged.dominates(right))
    }

    @Test func empty() {
        let empty = VersionVector()
        let some = VersionVector([a: 1])
        #expect(empty.compare(to: VersionVector()) == .equal)
        #expect(some.compare(to: empty) == .ahead)
        #expect(some.missing(from: empty) == [a: 1...1])
        #expect(VersionVector([a: 0]) == empty)
    }
}

private func randomOp(_ rng: inout SeededGenerator) -> Op {
    let length = Int.random(in: 0...40, using: &rng)
    let body = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) })
    return Op(
        replicaID: .random(using: &rng), counter: UInt64.random(in: 1...1_000_000, using: &rng),
        hlc: UInt64.random(in: 0...(1 << 62), using: &rng), docID: .random(using: &rng),
        field: ["title", "items/0a1b", "tags/ff"].randomElement(using: &rng) ?? "title",
        kind: UInt8.random(in: 1...3, using: &rng), body: body)
}

private func randomVector(_ rng: inout SeededGenerator) -> VersionVector {
    var counters: [ReplicaID: UInt64] = [:]
    for _ in 0..<Int.random(in: 0...5, using: &rng) {
        counters[.random(using: &rng)] = UInt64.random(in: 1...UInt64.max, using: &rng)
    }
    return VersionVector(counters)
}

private func randomMessage(_ rng: inout SeededGenerator) -> Message {
    switch Int.random(in: 0..<3, using: &rng) {
    case 0:
        let low = UInt64.random(in: 1...3, using: &rng)
        return .hello(
            replicaID: .random(using: &rng), protocolVersion: UInt64.random(in: 1...9, using: &rng),
            vector: randomVector(&rng),
            schemaVersions: low...(low + UInt64.random(in: 0...3, using: &rng)))
    case 1:
        return .ops((0..<Int.random(in: 0...20, using: &rng)).map { _ in randomOp(&rng) })
    default:
        return .ack(randomVector(&rng))
    }
}

@Suite struct MessageTests {
    @Test(arguments: 0..<5)
    func randomMessagesRoundTrip(seed: UInt64) throws {
        var rng = SeededGenerator(seed: seed)
        for _ in 0..<200 {
            let message = randomMessage(&rng)
            #expect(try Message(decoding: message.encoded()) == message, "seed \(seed)")
        }
    }

    @Test(arguments: 0..<3)
    func everyTruncationThrows(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        for _ in 0..<20 {
            let encoded = randomMessage(&rng).encoded()
            for length in 0..<encoded.count {
                #expect(throws: (any Error).self, "seed \(seed), length \(length)") {
                    try Message(decoding: encoded.prefix(length))
                }
            }
        }
    }

    /// A Hello laid out as message format 1 wrote it, before schema ranges existed.
    @Test func formatOneHelloStillDecodes() throws {
        var writer = ByteWriter()
        writer.write(1)
        writer.write(1)  // hello
        writer.writeFixed(a.bytes)
        writer.writeVarint(1)
        VersionVector([a: 4]).write(to: &writer)
        let message = try Message(decoding: writer.data)
        #expect(
            message
                == .hello(
                    replicaID: a, protocolVersion: 1, vector: VersionVector([a: 4]),
                    schemaVersions: 1...1))
    }

    @Test func unknownMessageExtensionsAreSkipped() throws {
        var bytes = Message.ack(VersionVector([a: 1])).encoded()
        bytes.removeLast()  // the empty extension count
        var writer = ByteWriter()
        writer.writeVarint(1)
        writer.writeVarint(77)
        writer.writeBytes(Data("from the future".utf8))
        bytes += writer.data
        #expect(try Message(decoding: bytes) == .ack(VersionVector([a: 1])))
    }

    @Test func badHeadersAreRejected() {
        let ack = Message.ack(VersionVector([a: 1])).encoded()
        var wrongVersion = ack
        wrongVersion[wrongVersion.startIndex] = 9
        #expect(throws: SyncError.unsupportedMessageVersion(9)) {
            try Message(decoding: wrongVersion)
        }
        var wrongType = ack
        wrongType[wrongType.startIndex + 1] = 42
        #expect(throws: SyncError.unknownMessageType(42)) { try Message(decoding: wrongType) }
        #expect(throws: StorageError.self) { try Message(decoding: ack + Data([0])) }
    }
}

@Suite struct InMemoryTransportTests {
    @Test func connectSendAndDisconnect() async throws {
        let network = InMemoryNetwork()
        let left = await network.makeTransport(PeerID("left"))
        let right = await network.makeTransport(PeerID("right"))
        var leftEvents = left.events.makeAsyncIterator()
        var rightEvents = right.events.makeAsyncIterator()

        await network.connect(PeerID("left"), PeerID("right"))
        #expect(await leftEvents.next() == .connected(PeerID("right")))
        #expect(await rightEvents.next() == .connected(PeerID("left")))

        let hello = Message.hello(replicaID: a, protocolVersion: 1, vector: VersionVector([a: 2]))
        try await left.send(hello, to: PeerID("right"))
        #expect(await rightEvents.next() == .received(hello, from: PeerID("left")))

        await network.disconnect(PeerID("left"), PeerID("right"))
        #expect(await leftEvents.next() == .disconnected(PeerID("right")))
        #expect(await rightEvents.next() == .disconnected(PeerID("left")))
        await #expect(throws: SyncError.notConnected(PeerID("right"))) {
            try await left.send(.ack(VersionVector()), to: PeerID("right"))
        }
    }

    @Test func messagesArriveInSendOrder() async throws {
        let network = InMemoryNetwork()
        let left = await network.makeTransport(PeerID("left"))
        let right = await network.makeTransport(PeerID("right"))
        await network.connect(PeerID("left"), PeerID("right"))
        var events = right.events.makeAsyncIterator()
        _ = await events.next()
        for counter in 1...20 {
            try await left.send(.ack(VersionVector([a: UInt64(counter)])), to: PeerID("right"))
        }
        for counter in 1...20 {
            #expect(
                await events.next()
                    == .received(.ack(VersionVector([a: UInt64(counter)])), from: PeerID("left")))
        }
    }
}
