// Deterministic simulation: real Replicas (in-memory SQLite) and real SyncSessions, with a
// simulated network and clocks. One task runs the scheduler and awaits each step in turn,
// so nothing interleaves and a seed always replays the same run.

import Foundation
import TetherCore
import TetherStorage
import TetherSync

public struct SimulationConfig: Sendable {
    public var nodeCount: ClosedRange<Int> = 3...5
    /// User actions and faults happen during this window; then the network is perfect and
    /// the run continues until no message or timer is left.
    public var activeMillis: UInt64 = 60_000
    public var dropRate: ClosedRange<Double> = 0.05...0.20
    public var duplicateRate = 0.05
    public var latencyMillis: ClosedRange<UInt64> = 1...200
    public var actionIntervalMillis: ClosedRange<UInt64> = 100...1_000
    public var partitionCount: ClosedRange<Int> = 1...3
    public var clockSkewMillis: ClosedRange<Int64> = -2_000...2_000
    /// Give up if the network is still busy this long after the active window.
    public var settleLimitMillis: UInt64 = 600_000

    public init() {}
}

public struct SimulationReport: Sendable {
    public let seed: UInt64
    /// nil if every invariant held.
    public let failure: String?
    public let trace: [String]
    public let traceHash: UInt64
    public let opCount: Int
    public let messagesSent: Int
    public let messagesDropped: Int
    public let finishedAtMillis: UInt64
}

public enum Simulation {
    public static func run(seed: UInt64, config: SimulationConfig = SimulationConfig())
        async throws -> SimulationReport
    {
        let world = try await World(seed: seed, config: config)
        return try await world.run()
    }
}

private let wallStart: UInt64 = 1_800_000_000_000
private let list = DocID(bytes: Data(repeating: 0x11, count: 16))!

private enum Action {
    case deliver(from: Int, to: Int, Data)
    case timer(node: Int, peer: Int, SyncSession.TimerID)
    case act(node: Int)
    case partition
    case heal
    case endActive
}

private final class Node {
    let replica: Replica
    let clock: FakeClock
    let skew: Int64
    var sessions: [Int: SyncSession] = [:]

    init(replica: Replica, clock: FakeClock, skew: Int64) {
        self.replica = replica
        self.clock = clock
        self.skew = skew
    }
}

private final class World {
    let seed: UInt64
    let config: SimulationConfig
    var rng: SeededGenerator
    var scheduler = Scheduler<Action>()
    var nodes: [Node] = []
    var blocked: Set<Set<Int>> = []
    var active = true
    let dropRate: Double
    var trace: [String] = []
    var deleted: Set<DocID> = []
    var opCount = 0
    var sent = 0
    var dropped = 0
    var failure: String?

    init(seed: UInt64, config: SimulationConfig) async throws {
        self.seed = seed
        self.config = config
        rng = SeededGenerator(seed: seed)
        dropRate = Double.random(in: config.dropRate, using: &rng)
        for _ in 0..<Int.random(in: config.nodeCount, using: &rng) {
            let skew = Int64.random(in: config.clockSkewMillis, using: &rng)
            let clock = FakeClock(millis: UInt64(Int64(wallStart) + skew))
            let replica = try await Replica.open(
                path: ":memory:", wallClock: clock, replicaID: .random(using: &rng))
            nodes.append(Node(replica: replica, clock: clock, skew: skew))
        }
    }

    func run() async throws -> SimulationReport {
        log("start nodes=\(nodes.count) drop=\(String(format: "%.3f", dropRate))")
        try await nodes[0].replica.perform(.createList(list, title: "List"))
        for node in nodes.indices {
            for peer in nodes.indices where peer != node {
                nodes[node].sessions[peer] = SyncSession(
                    replicaID: nodes[node].replica.id,
                    schemaVersions: 1...nodes[node].replica.manifest.version)
            }
        }
        for node in nodes.indices {
            scheduler.schedule(.act(node: node), afterMillis: actionDelay())
            for peer in nodes.indices where peer != node {
                try await handle(node, peer, .connected(local: try await vector(node)))
            }
        }
        for _ in 0..<Int.random(in: config.partitionCount, using: &rng) {
            let start = UInt64.random(in: 0..<config.activeMillis, using: &rng)
            scheduler.schedule(.partition, afterMillis: start)
            scheduler.schedule(
                .heal, afterMillis: start + UInt64.random(in: 2_000...20_000, using: &rng))
        }
        scheduler.schedule(.endActive, afterMillis: config.activeMillis)

        while failure == nil, let action = scheduler.next() {
            guard scheduler.now <= config.activeMillis + config.settleLimitMillis else {
                failure =
                    "network still busy \(config.settleLimitMillis) ms after the active window"
                break
            }
            try await process(action)
        }
        if failure == nil { failure = try await checkInvariants() }
        log("end failure=\(failure ?? "none")")
        return SimulationReport(
            seed: seed, failure: failure, trace: trace, traceHash: fnv1a(trace), opCount: opCount,
            messagesSent: sent, messagesDropped: dropped, finishedAtMillis: scheduler.now)
    }

    private func process(_ action: Action) async throws {
        switch action {
        case .deliver(let from, let to, let data):
            let message = try Message(decoding: data)
            log("recv n\(to)<-n\(from) \(describe(message))")
            try await handle(to, from, .received(message))
        case .timer(let node, let peer, let id):
            try await handle(node, peer, .timerFired(id))
        case .act(let node):
            guard active else { return }
            setClock(node)
            let change = try await RandomUser.change(on: nodes[node].replica, list: list, rng: &rng)
            if case .deleteItem(let item, _) = change { deleted.insert(item) }
            let ops = try await nodes[node].replica.perform(change)
            opCount += ops.count
            log("act n\(node) \(change.kind) ops=\(ops.count)")
            try await localChanged(node, except: nil)
            scheduler.schedule(.act(node: node), afterMillis: actionDelay())
        case .partition:
            guard active else { return }
            let shuffled = nodes.indices.shuffled(using: &rng)
            let cut = Int.random(in: 1..<shuffled.count, using: &rng)
            let side = Set(shuffled[..<cut])
            blocked = []
            for a in side {
                for b in nodes.indices where !side.contains(b) { blocked.insert([a, b]) }
            }
            log("partition \(side.sorted()) | \(Set(nodes.indices).subtracting(side).sorted())")
        case .heal:
            blocked = []
            log("heal")
        case .endActive:
            active = false
            blocked = []
            log("quiet")
        }
    }

    // State is stored before any effect runs, exactly like SyncEngine.
    private func handle(_ node: Int, _ peer: Int, _ event: SyncSession.Event) async throws {
        guard var session = nodes[node].sessions[peer] else { return }
        let effects = session.handle(event)
        nodes[node].sessions[peer] = session
        for effect in effects { try await execute(effect, node, peer) }
    }

    private func execute(_ effect: SyncSession.Effect, _ node: Int, _ peer: Int) async throws {
        switch effect {
        case .send(let message):
            send(message, from: node, to: peer)
        case .apply(let ops):
            setClock(node)
            do {
                try await nodes[node].replica.apply(ops)
            } catch {
                failure = "n\(node) rejected ops from n\(peer): \(error)"
                return
            }
            try await handle(node, peer, .applied(local: try await vector(node)))
            try await localChanged(node, except: peer)
        case .load(let vector):
            let ops = try await nodes[node].replica.database.ops(missingFrom: vector.counters)
            try await handle(node, peer, .loaded(ops))
        case .setTimer(let id, let delay):
            scheduler.schedule(.timer(node: node, peer: peer, id), afterMillis: millis(delay))
        }
    }

    /// Tells every other session on `node` that its store changed, so they relay it.
    private func localChanged(_ node: Int, except skipped: Int?) async throws {
        let current = try await vector(node)
        for peer in nodes[node].sessions.keys.sorted() where peer != skipped {
            try await handle(node, peer, .localChanged(current))
        }
    }

    private func send(_ message: Message, from: Int, to: Int) {
        sent += 1
        let data = message.encoded()
        if active
            && (blocked.contains([from, to]) || Double.random(in: 0..<1, using: &rng) < dropRate)
        {
            dropped += 1
            log("drop n\(from)->n\(to) \(describe(message))")
            return
        }
        scheduler.schedule(.deliver(from: from, to: to, data), afterMillis: latency())
        if active && Double.random(in: 0..<1, using: &rng) < config.duplicateRate {
            scheduler.schedule(.deliver(from: from, to: to, data), afterMillis: latency())
            log("dup n\(from)->n\(to)")
        }
    }

    private func checkInvariants() async throws -> String? {
        let reference = try await nodes[0].replica.database.stateSnapshot()
        let referenceVector = try await vector(0)
        for (index, node) in nodes.enumerated() {
            let db = node.replica.database
            if try await db.stateSnapshot() != reference {
                return "n\(index) state differs from n0"
            }
            if try await vector(index) != referenceVector {
                return "n\(index) version vector differs from n0"
            }
            do {
                try await db.verify()
            } catch {
                return "n\(index) fails verify(): \(error)"
            }
            let visible = Set(try await db.items(inList: list).map(\.id))
            if let back = deleted.first(where: visible.contains) {
                return "n\(index) shows deleted item \(back.bytes.prefix(2).map { String($0) })"
            }
            for (peer, session) in node.sessions where session.unackedBatches > 0 {
                return "n\(index) still has unacked batches for n\(peer)"
            }
        }
        return nil
    }

    private func vector(_ node: Int) async throws -> VersionVector {
        VersionVector(try await nodes[node].replica.database.versionVector())
    }

    private func setClock(_ node: Int) {
        nodes[node].clock.set(UInt64(Int64(wallStart) + Int64(scheduler.now) + nodes[node].skew))
    }

    private func actionDelay() -> UInt64 {
        UInt64.random(in: config.actionIntervalMillis, using: &rng)
    }

    private func latency() -> UInt64 {
        UInt64.random(in: config.latencyMillis, using: &rng)
    }

    private func millis(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(seconds) * 1_000 + UInt64(attoseconds / 1_000_000_000_000_000)
    }

    private func log(_ line: String) {
        trace.append("t=\(scheduler.now) \(line)")
    }

    private func describe(_ message: Message) -> String {
        switch message {
        case .hello(_, _, let vector, let schemas):
            return "hello(\(vector.counters.count), v\(schemas.lowerBound)-\(schemas.upperBound))"
        case .ops(let ops): return "ops(\(ops.count))"
        case .ack(let vector): return "ack(\(vector.counters.values.reduce(0, +)))"
        }
    }
}

extension Change {
    fileprivate var kind: String {
        switch self {
        case .createList: "createList"
        case .renameList: "renameList"
        case .addItem: "addItem"
        case .setTitle: "setTitle"
        case .setDone: "setDone"
        case .move: "move"
        case .deleteItem: "deleteItem"
        case .addTag: "addTag"
        case .removeTag: "removeTag"
        case .setPriority: "setPriority"
        case .incrementViews: "incrementViews"
        case .set: "set"
        }
    }
}

/// FNV-1a over the trace. Swift's Hasher is seeded per process, so it can't be used here.
func fnv1a(_ lines: [String]) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for line in lines {
        for byte in line.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        hash = (hash ^ 0x0A) &* 0x0000_0100_0000_01B3
    }
    return hash
}
