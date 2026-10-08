// Tests for the pure SyncSession state machine and for SyncEngine over InMemoryTransport.

import Foundation
import Testing
import TetherCore
import TetherStorage

@testable import TetherSync

private let me = ReplicaID(bytes: Data(repeating: 1, count: 16))!
private let peer = ReplicaID(bytes: Data(repeating: 2, count: 16))!
private let list = DocID(bytes: Data(repeating: 0x11, count: 16))!

private func op(_ replica: ReplicaID, _ counter: UInt64, bodySize: Int = 1) -> Op {
    Op(
        replicaID: replica, counter: counter, hlc: counter, docID: list, field: "title",
        kind: 1, body: Data(repeating: 7, count: bodySize))
}

private func hello(_ id: ReplicaID, _ vector: VersionVector) -> Message {
    .hello(replicaID: id, protocolVersion: Message.protocolVersion, vector: vector)
}

/// A session that has finished the handshake with a peer that has `peerVector`.
private func liveSession(local: VersionVector, peerVector: VersionVector = VersionVector())
    -> (SyncSession, [SyncSession.Effect])
{
    var session = SyncSession(replicaID: me)
    _ = session.handle(.connected(local: local))
    let effects = session.handle(.received(hello(peer, peerVector)))
    return (session, effects)
}

@Suite struct SyncSessionTests {
    @Test func handshakeSendsHelloThenLoadsWhatThePeerLacks() {
        var session = SyncSession(replicaID: me)
        let local = VersionVector([me: 3])
        #expect(
            session.handle(.connected(local: local)) == [
                .send(hello(me, local)), .setTimer(.hello, after: SyncSession.helloRetry),
            ])
        #expect(session.phase == .handshaking)
        let effects = session.handle(.received(hello(peer, VersionVector([me: 1]))))
        #expect(session.phase == .live)
        #expect(effects == [.load(missingFrom: VersionVector([me: 1]))])
    }

    @Test func nothingToLoadWhenThePeerIsCaughtUp() {
        let (_, effects) = liveSession(
            local: VersionVector([me: 2]), peerVector: VersionVector([me: 2]))
        #expect(effects.isEmpty)
    }

    @Test func helloFromANewerSchemaIsAcceptedNotRefused() {
        var session = SyncSession(replicaID: me, schemaVersions: 1...1)
        let connected = session.handle(.connected(local: VersionVector([me: 2])))
        #expect(
            connected.first
                == .send(
                    .hello(
                        replicaID: me, protocolVersion: Message.protocolVersion,
                        vector: VersionVector([me: 2]), schemaVersions: 1...1)))
        let newer = Message.hello(
            replicaID: peer, protocolVersion: Message.protocolVersion, vector: VersionVector(),
            schemaVersions: 1...3)
        let effects = session.handle(.received(newer))
        #expect(session.phase == .live)
        #expect(session.peerSchemaVersions == 1...3)
        #expect(effects == [.load(missingFrom: VersionVector())])
    }

    @Test func helloIsRetriedUntilThePeerAnswers() {
        var session = SyncSession(replicaID: me)
        _ = session.handle(.connected(local: VersionVector()))
        #expect(session.handle(.timerFired(.hello)).count == 2)
        _ = session.handle(.received(hello(peer, VersionVector())))
        #expect(session.handle(.timerFired(.hello)).isEmpty)
    }

    @Test func repeatedHelloIsAnswered() {
        var (session, _) = liveSession(local: VersionVector())
        let effects = session.handle(.received(hello(peer, VersionVector())))
        #expect(
            effects == [
                .send(
                    .hello(
                        replicaID: me, protocolVersion: Message.protocolVersion,
                        vector: VersionVector(), isReply: true))
            ])
        let reply = Message.hello(
            replicaID: peer, protocolVersion: Message.protocolVersion, vector: VersionVector(),
            isReply: true)
        #expect(session.handle(.received(reply)).isEmpty)
    }

    /// Regression (mixed-version simulation, seeds 2 and 48): a hello retry that crossed the
    /// peer's hello left both sides live, and each answered the other's hello forever.
    @Test func liveSessionsDontTradeHellosForever() {
        var sessions = [SyncSession(replicaID: me), SyncSession(replicaID: peer)]
        var inbox: [(to: Int, Message)] = []
        for side in 0..<2 {
            for case .send(let message) in sessions[side].handle(.connected(local: VersionVector()))
            {
                inbox.append((1 - side, message))
            }
        }
        // Side 0's retry timer fires before side 1's hello lands.
        for case .send(let message) in sessions[0].handle(.timerFired(.hello)) {
            inbox.append((1, message))
        }
        var delivered = 0
        while !inbox.isEmpty, delivered < 20 {
            let (to, message) = inbox.removeFirst()
            delivered += 1
            for case .send(let reply) in sessions[to].handle(.received(message)) {
                inbox.append((1 - to, reply))
            }
        }
        #expect(inbox.isEmpty)
        #expect(sessions.allSatisfy { $0.phase == .live })
    }

    @Test func loadedOpsAreSentRetriedWithBackoffAndClearedByAck() {
        var (session, _) = liveSession(local: VersionVector([me: 2]))
        let ops = [op(me, 1), op(me, 2)]
        #expect(
            session.handle(.loaded(ops)) == [
                .send(.ops(ops)), .setTimer(.batch(1), after: .seconds(1)),
            ])
        #expect(session.unackedBatches == 1)
        #expect(
            session.handle(.timerFired(.batch(1))) == [
                .send(.ops(ops)), .setTimer(.batch(1), after: .seconds(2)),
            ])
        #expect(session.handle(.received(.ack(VersionVector([me: 2])))).isEmpty)
        #expect(session.unackedBatches == 0)
        #expect(session.handle(.timerFired(.batch(1))).isEmpty)
    }

    @Test func aPartialAckKeepsTheBatchInFlight() {
        var (session, _) = liveSession(local: VersionVector([me: 2]))
        _ = session.handle(.loaded([op(me, 1), op(me, 2)]))
        _ = session.handle(.received(.ack(VersionVector([me: 1]))))
        #expect(session.unackedBatches == 1)
    }

    @Test func receivedOpsAreAppliedThenAcked() {
        var (session, _) = liveSession(local: VersionVector())
        let ops = [op(peer, 1)]
        #expect(session.handle(.received(.ops(ops))) == [.apply(ops)])
        let after = VersionVector([peer: 1])
        #expect(session.handle(.applied(local: after)) == [.send(.ack(after))])
    }

    @Test func localChangesArePushedLive() {
        var (session, _) = liveSession(local: VersionVector())
        #expect(
            session.handle(.localChanged(VersionVector([me: 1])))
                == [.load(missingFrom: VersionVector())])
        // A second change while that load is outstanding waits for it.
        #expect(session.handle(.localChanged(VersionVector([me: 2]))).isEmpty)
        let effects = session.handle(.loaded([op(me, 1)]))
        #expect(effects.last == .load(missingFrom: VersionVector([me: 1])))
    }

    @Test func alreadySentOpsAreNotSentAgain() {
        var (session, _) = liveSession(local: VersionVector([me: 1]))
        _ = session.handle(.loaded([op(me, 1)]))
        #expect(session.handle(.localChanged(VersionVector([me: 1]))).isEmpty)
    }

    @Test func batchesStayUnderTheSizeCap() {
        let ops = (1...10).map { op(me, UInt64($0), bodySize: 60_000) }
        let batches = SyncSession.batches(of: ops)
        #expect(batches.count == 3)
        #expect(batches.flatMap { $0 } == ops)
        for batch in batches {
            #expect(batch.map { $0.encoded().count }.reduce(0, +) <= SyncSession.maxBatchBytes)
        }
        let huge = [op(me, 1, bodySize: 300_000)]
        #expect(SyncSession.batches(of: huge) == [huge])
    }

    @Test func backoffDoublesUpToThirtySeconds() {
        #expect(
            (0..<7).map { SyncSession.backoff(attempt: $0) }
                == [1, 2, 4, 8, 16, 30, 30].map { .seconds($0) })
    }
}

private let start: UInt64 = 1_800_000_000_000

private func replica(_ byte: UInt8) async throws -> Replica {
    try await Replica.open(
        path: ":memory:", wallClock: FakeClock(millis: start),
        replicaID: ReplicaID(bytes: Data(repeating: byte, count: 16)))
}

/// Polls until `condition` holds or `timeout` passes.
private func eventually(
    timeout: Duration = .seconds(10), _ condition: () async throws -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    return false
}

private func sameState(_ replicas: [Replica]) async throws -> Bool {
    let first = try await replicas[0].database.stateSnapshot()
    for other in replicas.dropFirst() where try await other.database.stateSnapshot() != first {
        return false
    }
    return true
}

@Suite struct SyncEngineTests {
    @Test func twoReplicasCatchUp() async throws {
        let a = try await replica(1)
        let b = try await replica(2)
        try await a.perform(.createList(list, title: "Groceries"))
        for index in 0..<50 {
            try await a.perform(
                .addItem(.random(), toList: list, title: "item \(index)", position: "V"))
        }
        try await b.perform(.addItem(.random(), toList: list, title: "from b", position: "W"))

        let network = InMemoryNetwork()
        let engineA = SyncEngine(replica: a, transport: await network.makeTransport(PeerID("a")))
        let engineB = SyncEngine(replica: b, transport: await network.makeTransport(PeerID("b")))
        let runs = [Task { await engineA.run() }, Task { await engineB.run() }]
        defer { for run in runs { run.cancel() } }
        await network.connect(PeerID("a"), PeerID("b"))

        #expect(try await eventually { try await sameState([a, b]) })
        #expect(try await b.database.items(inList: list).count == 51)
        #expect(try await eventually { await engineA.statuses().first?.unackedBatches == 0 })
    }

    @Test func aChainConvergesThroughTheMiddle() async throws {
        let replicas = [try await replica(1), try await replica(2), try await replica(3)]
        try await replicas[0].perform(.createList(list, title: "Chain"))
        try await replicas[2].perform(
            .addItem(.random(), toList: list, title: "from c", position: "V"))

        let network = InMemoryNetwork()
        var runs: [Task<Void, Never>] = []
        for (index, replica) in replicas.enumerated() {
            let engine = SyncEngine(
                replica: replica, transport: await network.makeTransport(PeerID("\(index)")))
            runs.append(Task { await engine.run() })
        }
        defer { for run in runs { run.cancel() } }
        await network.connect(PeerID("0"), PeerID("1"))
        await network.connect(PeerID("1"), PeerID("2"))

        #expect(try await eventually { try await sameState(replicas) })
        #expect(try await replicas[0].database.items(inList: list).map(\.title) == ["from c"])
    }

    /// The Session 4.6 demo script: v1 Mac and v2 iPhone edit offline, reconnect, then the
    /// Mac upgrades to v2 and sees the priorities.
    @Test func twoVersionDemoScript() async throws {
        let mac = try await Replica.open(
            path: ":memory:", wallClock: FakeClock(millis: start),
            replicaID: ReplicaID(bytes: Data(repeating: 1, count: 16)),
            manifest: TaskListSchema.v1)
        let phone = try await Replica.open(
            path: ":memory:", wallClock: FakeClock(millis: start),
            replicaID: ReplicaID(bytes: Data(repeating: 2, count: 16)),
            manifest: TaskListSchema.v2)
        let items = (0..<3).map { _ in DocID.random() }
        try await mac.perform(.createList(list, title: "Groceries"))
        for (index, item) in items.enumerated() {
            try await mac.perform(
                .addItem(item, toList: list, title: "item \(index)", position: "V\(index)"))
        }
        try await phone.apply(mac.database.ops(missingFrom: [:]))

        // Offline: v1 edits titles, v2 sets priorities on the same items.
        for item in items { try await mac.perform(.setTitle(item: item, "renamed on Mac")) }
        for item in items.prefix(2) { try await phone.perform(.setPriority(item: item, 2)) }

        let network = InMemoryNetwork()
        let engines = [
            SyncEngine(replica: mac, transport: await network.makeTransport(PeerID("mac"))),
            SyncEngine(replica: phone, transport: await network.makeTransport(PeerID("phone"))),
        ]
        let runs = engines.map { engine in Task { await engine.run() } }
        defer { for run in runs { run.cancel() } }
        await network.connect(PeerID("mac"), PeerID("phone"))

        #expect(
            try await eventually {
                try await phone.database.items(inList: list).allSatisfy {
                    $0.title == "renamed on Mac"
                }
            })
        #expect(
            try await eventually {
                try await mac.database.stateSnapshot().filter { !$0.known }.count == 2
            })
        #expect(
            try await mac.database.items(inList: list).allSatisfy { $0.title == "renamed on Mac" })

        // The Mac installs v2.
        let upgraded = try await Replica.open(
            database: mac.database, wallClock: FakeClock(millis: start), manifest: TaskListSchema.v2
        )
        var shown: [Int64?] = []
        for item in items {
            shown.append(try await upgraded.read(Int64.self, "priority", of: item, in: "item"))
        }
        #expect(shown == [2, 2, TaskListSchema.mediumPriority])
        #expect(try await upgraded.database.stateSnapshot().allSatisfy(\.known))
    }

    @Test func liveEditsArePushedImmediately() async throws {
        let a = try await replica(1)
        let b = try await replica(2)
        let network = InMemoryNetwork()
        let engineA = SyncEngine(replica: a, transport: await network.makeTransport(PeerID("a")))
        let engineB = SyncEngine(replica: b, transport: await network.makeTransport(PeerID("b")))
        let runs = [Task { await engineA.run() }, Task { await engineB.run() }]
        defer { for run in runs { run.cancel() } }
        await network.connect(PeerID("a"), PeerID("b"))
        #expect(try await eventually { await engineA.statuses().first?.phase == .live })

        try await a.perform(.createList(list, title: "Live"))
        #expect(try await eventually { try await b.database.listTitle(list) == "Live" })
        try await b.perform(.renameList(list, title: "Renamed on b"))
        #expect(try await eventually { try await a.database.listTitle(list) == "Renamed on b" })
    }
}
