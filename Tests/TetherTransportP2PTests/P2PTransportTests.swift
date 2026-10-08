// Tests for framing and for P2PTransport over real TCP on loopback (no Bonjour needed).

import Foundation
import Network
import Testing
import TetherCore
import TetherStorage
import TetherSync

@testable import TetherTransportP2P

private let a = ReplicaID(bytes: Data(repeating: 0x0A, count: 16))!
private let b = ReplicaID(bytes: Data(repeating: 0x0B, count: 16))!

@Suite struct FramingTests {
    @Test func framesSplitAnywhereReassembleInOrder() throws {
        let payloads = [Data(), Data([1]), Data(repeating: 7, count: 70_000), Data("hi".utf8)]
        let stream = payloads.map(FrameDecoder.frame).reduce(Data(), +)
        for chunkSize in [1, 3, 4, 5, 1_000, stream.count] {
            var decoder = FrameDecoder()
            var frames: [Data] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                frames += try decoder.append(stream[offset..<end])
                offset = end
            }
            #expect(frames == payloads, "chunk size \(chunkSize)")
        }
    }

    @Test func oversizedFramesAreRejected() {
        var decoder = FrameDecoder()
        let length = UInt32(FrameDecoder.maxFrameBytes + 1).bigEndian
        #expect(throws: FrameError.frameTooLarge(FrameDecoder.maxFrameBytes + 1)) {
            try decoder.append(withUnsafeBytes(of: length) { Data($0) })
        }
    }
}

private func loopback(_ port: UInt16) -> NWEndpoint {
    .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
}

private func nextEvent(
    _ events: inout AsyncStream<TransportEvent>.Iterator, timeout: Duration = .seconds(5)
) async -> TransportEvent? {
    await withTaskGroup(of: TransportEvent?.self) { group in
        var iterator = events
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let event = await iterator.next()
        group.cancelAll()
        events = iterator
        return event
    }
}

@Suite(.serialized) struct P2PTransportTests {
    @Test func connectExchangeAndDisconnect() async throws {
        let left = P2PTransport(replicaID: a, bonjour: false)
        let right = P2PTransport(replicaID: b, bonjour: false)
        let port = try await right.start()
        try await left.start()
        var leftEvents = left.events.makeAsyncIterator()
        var rightEvents = right.events.makeAsyncIterator()

        left.connect(to: loopback(port))
        #expect(await nextEvent(&leftEvents) == .connected(right.peerID))
        #expect(await nextEvent(&rightEvents) == .connected(left.peerID))

        let hello = Message.hello(replicaID: a, protocolVersion: 1, vector: VersionVector([a: 3]))
        try await left.send(hello, to: right.peerID)
        #expect(await nextEvent(&rightEvents) == .received(hello, from: left.peerID))
        let ack = Message.ack(VersionVector([b: 9]))
        try await right.send(ack, to: left.peerID)
        #expect(await nextEvent(&leftEvents) == .received(ack, from: right.peerID))

        right.stop()
        #expect(await nextEvent(&leftEvents) == .disconnected(right.peerID))
        left.stop()
    }

    @Test func simultaneousDialsLeaveOneConnection() async throws {
        let left = P2PTransport(replicaID: a, bonjour: false)
        let right = P2PTransport(replicaID: b, bonjour: false)
        let leftPort = try await left.start()
        let rightPort = try await right.start()
        var leftEvents = left.events.makeAsyncIterator()

        left.connect(to: loopback(rightPort))
        right.connect(to: loopback(leftPort))
        #expect(await nextEvent(&leftEvents) == .connected(right.peerID))

        // Whichever duplicate was cancelled, messages still flow and no second connect fires.
        try await Task.sleep(for: .milliseconds(300))
        for counter in 1...5 {
            try await right.send(.ack(VersionVector([b: UInt64(counter)])), to: left.peerID)
        }
        for counter in 1...5 {
            #expect(
                await nextEvent(&leftEvents)
                    == .received(.ack(VersionVector([b: UInt64(counter)])), from: right.peerID))
        }
        left.stop()
        right.stop()
    }

    /// Like Wi-Fi dropping, or the other app being killed and relaunched.
    @Test func redialsWhenThePeerComesBack() async throws {
        let left = P2PTransport(replicaID: a, bonjour: false)
        let right = P2PTransport(replicaID: b, bonjour: false)
        let port = try await right.start()
        try await left.start()
        var leftEvents = left.events.makeAsyncIterator()

        left.connect(to: loopback(port))
        #expect(await nextEvent(&leftEvents) == .connected(right.peerID))
        right.stop()
        #expect(await nextEvent(&leftEvents) == .disconnected(right.peerID))

        let restarted = P2PTransport(replicaID: b, bonjour: false)
        try await restarted.start(port: NWEndpoint.Port(rawValue: port)!)
        #expect(await nextEvent(&leftEvents, timeout: .seconds(10)) == .connected(right.peerID))
        try await restarted.send(.ack(VersionVector([b: 1])), to: left.peerID)
        #expect(
            await nextEvent(&leftEvents)
                == .received(.ack(VersionVector([b: 1])), from: right.peerID))
        left.stop()
        restarted.stop()
    }

    @Test func aNetworkChangeRedialsImmediately() async throws {
        let left = P2PTransport(replicaID: a, bonjour: false)
        let right = P2PTransport(replicaID: b, bonjour: false)
        let port = try await right.start()
        try await left.start()
        var leftEvents = left.events.makeAsyncIterator()

        left.connect(to: loopback(port))
        #expect(await nextEvent(&leftEvents) == .connected(right.peerID))
        right.stop()
        #expect(await nextEvent(&leftEvents) == .disconnected(right.peerID))
        // Down long enough for the backoff to grow past the timeout below.
        try await Task.sleep(for: .seconds(7.5))

        let restarted = P2PTransport(replicaID: b, bonjour: false)
        try await restarted.start(port: NWEndpoint.Port(rawValue: port)!)
        let changed = ContinuousClock.now
        left.networkChanged()
        #expect(await nextEvent(&leftEvents) == .connected(right.peerID))
        #expect(ContinuousClock.now - changed < .seconds(2))
        left.stop()
        restarted.stop()
    }

    /// Regression for the real-device test: with Wi-Fi off, both devices still showed the
    /// other as "live" because the dead TCP connection was never noticed.
    @Test func deadConnectionsAreDetectedWithinSeconds() {
        let tcp = P2PTransport.tcpOptions()
        #expect(tcp.enableKeepalive)
        #expect(tcp.keepaliveIdle + tcp.keepaliveInterval * tcp.keepaliveCount <= 15)
        #expect(tcp.connectionDropTime > 0 && tcp.connectionDropTime <= 15)
        #expect(tcp.connectionTimeout > 0)
    }

    @Test func sendingToAnUnknownPeerThrows() async throws {
        let transport = P2PTransport(replicaID: a, bonjour: false)
        try await transport.start()
        await #expect(throws: SyncError.notConnected(PeerID("nobody"))) {
            try await transport.send(.ack(VersionVector()), to: PeerID("nobody"))
        }
        transport.stop()
    }

    @Test func twoReplicasSyncOverTCP() async throws {
        let list = DocID(bytes: Data(repeating: 0x11, count: 16))!
        let clock = FakeClock(millis: 1_800_000_000_000)
        let left = try await Replica.open(path: ":memory:", wallClock: clock, replicaID: a)
        let right = try await Replica.open(path: ":memory:", wallClock: clock, replicaID: b)
        try await left.perform(.createList(list, title: "Over TCP"))
        for index in 0..<200 {
            try await left.perform(
                .addItem(.random(), toList: list, title: "\(index)", position: "V"))
        }

        let leftTransport = P2PTransport(replicaID: a, bonjour: false)
        let rightTransport = P2PTransport(replicaID: b, bonjour: false)
        let port = try await rightTransport.start()
        try await leftTransport.start()
        let engines = [
            SyncEngine(replica: left, transport: leftTransport),
            SyncEngine(replica: right, transport: rightTransport),
        ]
        let runs = engines.map { engine in Task { await engine.run() } }
        defer {
            for run in runs { run.cancel() }
            leftTransport.stop()
            rightTransport.stop()
        }
        leftTransport.connect(to: loopback(port))

        let deadline = ContinuousClock.now + .seconds(10)
        while try await right.database.items(inList: list).count < 200,
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await right.database.items(inList: list).count == 200)
        try await right.perform(.renameList(list, title: "Renamed on the other side"))
        while try await left.database.listTitle(list) != "Renamed on the other side",
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await left.database.listTitle(list) == "Renamed on the other side")
        #expect(try await left.database.stateSnapshot() == right.database.stateSnapshot())
    }
}
