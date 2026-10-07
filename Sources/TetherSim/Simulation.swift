// Deterministic simulation: real Replicas (in-memory SQLite) and real SyncSessions, with a
// simulated network and clocks. One task runs the scheduler and awaits each step in turn,
// so nothing interleaves and a seed always replays the same run. Mixed-version runs start
// nodes on different schema versions and upgrade some of them mid-run.

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
    /// Schema versions nodes start on. A range makes a mixed-version run: some nodes
    /// upgrade mid-run, and once the network is quiet every node upgrades to v3.
    public var startVersions: ClosedRange<UInt64> = 1...1
    /// Chance that a node not on v3 upgrades during the active window.
    public var upgradeRate = 0.5

    public var mixedVersions: Bool { startVersions.count > 1 }

    public init() {}

    public static var mixed: SimulationConfig {
        var config = SimulationConfig()
        config.startVersions = 1...3
        return config
    }
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
    public let upgrades: Int
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

// A link's epoch goes up when it reconnects; messages and timers from an older epoch
// belonged to the dropped connection and are discarded.
private enum Action {
    case deliver(from: Int, to: Int, epoch: Int, Data)
    case timer(node: Int, peer: Int, epoch: Int, SyncSession.TimerID)
    case act(node: Int)
    case upgrade(node: Int, to: UInt64)
    case partition
    case heal
    case endActive
}

private final class Node {
    var replica: Replica
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
    var upgrades = 0
    var failure: String?
    var epochs: [Set<Int>: Int] = [:]
    /// Every op any node created, encoded: what every log must hold at the end.
    var created: Set<Data> = []

    init(seed: UInt64, config: SimulationConfig) async throws {
        self.seed = seed
        self.config = config
        rng = SeededGenerator(seed: seed)
        dropRate = Double.random(in: config.dropRate, using: &rng)
        for _ in 0..<Int.random(in: config.nodeCount, using: &rng) {
            let skew = Int64.random(in: config.clockSkewMillis, using: &rng)
            let clock = FakeClock(millis: UInt64(Int64(wallStart) + skew))
            let version =
                config.mixedVersions
                ? UInt64.random(in: config.startVersions, using: &rng)
                : config.startVersions.lowerBound
            let replica = try await Replica.open(
                path: ":memory:", wallClock: clock, replicaID: .random(using: &rng),
                manifest: TaskListSchema.versions[Int(version) - 1])
            nodes.append(Node(replica: replica, clock: clock, skew: skew))
        }
    }

    func run() async throws -> SimulationReport {
        log("start nodes=\(nodes.count) drop=\(String(format: "%.3f", dropRate))")
        if config.mixedVersions {
            log(
                "versions \(nodes.map { "v\($0.replica.manifest.version)" }.joined(separator: " "))"
            )
        }
        let first = try await nodes[0].replica.perform(.createList(list, title: "List"))
        created.formUnion(first.map { $0.encoded() })
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
        if config.mixedVersions {
            for node in nodes.indices {
                let version = nodes[node].replica.manifest.version
                guard version < 3, Double.random(in: 0..<1, using: &rng) < config.upgradeRate
                else { continue }
                scheduler.schedule(
                    .upgrade(node: node, to: UInt64.random(in: (version + 1)...3, using: &rng)),
                    afterMillis: UInt64.random(in: 0..<config.activeMillis, using: &rng))
            }
        }
        scheduler.schedule(.endActive, afterMillis: config.activeMillis)

        try await drain()
        // Mixed versions at rest: nothing lost, old views sound. Then everyone upgrades.
        if failure == nil, config.mixedVersions {
            failure = try await checkMixedInvariants()
            if failure == nil {
                log("upgrade all")
                for node in nodes.indices where nodes[node].replica.manifest.version < 3 {
                    try await upgrade(node, to: 3)
                }
                try await drain()
            }
        }
        if failure == nil { failure = try await checkInvariants() }
        log("end failure=\(failure ?? "none")")
        return SimulationReport(
            seed: seed, failure: failure, trace: trace, traceHash: fnv1a(trace), opCount: opCount,
            messagesSent: sent, messagesDropped: dropped, upgrades: upgrades,
            finishedAtMillis: scheduler.now)
    }

    /// Runs until no message or timer is left.
    private func drain() async throws {
        let deadline = max(scheduler.now, config.activeMillis) + config.settleLimitMillis
        while failure == nil, let action = scheduler.next() {
            guard scheduler.now <= deadline else {
                failure = "[network] still busy \(config.settleLimitMillis) ms after going quiet"
                break
            }
            try await process(action)
        }
    }

    private func process(_ action: Action) async throws {
        switch action {
        case .deliver(let from, let to, let epoch, let data):
            guard epoch == epochs[[from, to], default: 0] else {
                log("stale n\(to)<-n\(from)")
                return
            }
            let message = try Message(decoding: data)
            log("recv n\(to)<-n\(from) \(describe(message))")
            try await handle(to, from, .received(message))
        case .timer(let node, let peer, let epoch, let id):
            guard epoch == epochs[[node, peer], default: 0] else { return }
            try await handle(node, peer, .timerFired(id))
        case .act(let node):
            guard active else { return }
            setClock(node)
            let change = try await RandomUser.change(on: nodes[node].replica, list: list, rng: &rng)
            if case .deleteItem(let item, _) = change { deleted.insert(item) }
            let ops = try await nodes[node].replica.perform(change)
            opCount += ops.count
            created.formUnion(ops.map { $0.encoded() })
            log("act n\(node) \(change.kind) ops=\(ops.count)")
            try await localChanged(node, except: nil)
            scheduler.schedule(.act(node: node), afterMillis: actionDelay())
        case .upgrade(let node, let version):
            guard active else { return }
            try await upgrade(node, to: version)
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

    /// Reopens the node's store as `version`, like an app update. Leaving v1 runs the
    /// explicit-priority migration, so several nodes may emit the same migration ops.
    private func upgrade(_ node: Int, to version: UInt64) async throws {
        if let broken = try await checkView(node) {
            failure = broken
            return
        }
        setClock(node)
        let old = nodes[node].replica
        nodes[node].replica = try await Replica.open(
            database: old.database, wallClock: nodes[node].clock,
            manifest: TaskListSchema.versions[Int(version) - 1])
        upgrades += 1
        log("upgrade n\(node) v\(old.manifest.version)->v\(version)")
        if old.manifest.version == 1 {
            let migration = TaskListSchema.explicitPriority
            let items = try await old.database.orSet(DocID.self, doc: list, field: Field.items)
                .elements.sorted()
            let new = try await nodes[node].replica.migrate(migration, documents: items)
            opCount += new
            created.formUnion(items.map { migration.op(for: $0).encoded() })
            log("migrate n\(node) items=\(items.count) new=\(new)")
        }
        // An update restarts the app: every connection drops and reconnects.
        for peer in nodes.indices where peer != node {
            epochs[[node, peer], default: 0] += 1
            for (a, b) in [(node, peer), (peer, node)] {
                nodes[a].sessions[b] = SyncSession(
                    replicaID: nodes[a].replica.id,
                    schemaVersions: 1...nodes[a].replica.manifest.version)
            }
            try await handle(node, peer, .connected(local: try await vector(node)))
            try await handle(peer, node, .connected(local: try await vector(peer)))
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
                failure = "[apply] n\(node) rejected ops from n\(peer): \(error)"
                return
            }
            try await handle(node, peer, .applied(local: try await vector(node)))
            try await localChanged(node, except: peer)
        case .load(let vector):
            let ops = try await nodes[node].replica.database.ops(missingFrom: vector.counters)
            try await handle(node, peer, .loaded(ops))
        case .setTimer(let id, let delay):
            scheduler.schedule(
                .timer(node: node, peer: peer, epoch: epochs[[node, peer], default: 0], id),
                afterMillis: millis(delay))
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
        let delivery = Action.deliver(
            from: from, to: to, epoch: epochs[[from, to], default: 0], data)
        scheduler.schedule(delivery, afterMillis: latency())
        if active && Double.random(in: 0..<1, using: &rng) < config.duplicateRate {
            scheduler.schedule(delivery, afterMillis: latency())
            log("dup n\(from)->n\(to)")
        }
    }

    private func checkInvariants() async throws -> String? {
        let reference = try await nodes[0].replica.database.stateSnapshot()
        let referenceVector = try await vector(0)
        for (index, node) in nodes.enumerated() {
            let db = node.replica.database
            if try await db.stateSnapshot() != reference {
                return "[convergence] n\(index) state differs from n0"
            }
            if try await vector(index) != referenceVector {
                return "[convergence] n\(index) version vector differs from n0"
            }
            do {
                try await db.verify()
            } catch {
                return "[storage] n\(index) fails verify(): \(error)"
            }
            let visible = Set(try await db.items(inList: list).map(\.id))
            if let back = deleted.first(where: visible.contains) {
                return
                    "[resurrection] n\(index) shows deleted item \(back.bytes.prefix(2).map { String($0) })"
            }
            for (peer, session) in node.sessions where session.unackedBatches > 0 {
                return "[acks] n\(index) still has unacked batches for n\(peer)"
            }
        }
        guard config.mixedVersions else { return nil }
        for index in nodes.indices {
            if let failure = try await checkNoLoss(index) { return failure }
            if let failure = try await checkView(index) { return failure }
        }
        if try await allV3State() != reference {
            return "[upgrade] state differs from a v3 replica fed the same ops"
        }
        return nil
    }

    private func checkMixedInvariants() async throws -> String? {
        for index in nodes.indices {
            if let failure = try await checkNoLoss(index) { return failure }
            if let failure = try await checkView(index) { return failure }
            do {
                try await nodes[index].replica.database.verify()
            } catch {
                return "[storage] n\(index) fails verify(): \(error)"
            }
        }
        return nil
    }

    /// Every op ever created is in the node's log, byte for byte, whatever its version.
    private func checkNoLoss(_ index: Int) async throws -> String? {
        let replica = nodes[index].replica
        let log = Set(try await replica.database.ops(missingFrom: [:]).map { $0.encoded() })
        guard log != created else { return nil }
        return "[no-loss] n\(index) (v\(replica.manifest.version)) lacks "
            + "\(created.subtracting(log).count) ops and has \(log.subtracting(created).count) unknown"
    }

    /// The node's view is sound for its version: `known` matches its manifest, nothing it
    /// knows is pending, and every field it shows reads with the right type.
    private func checkView(_ index: Int) async throws -> String? {
        let replica = nodes[index].replica
        let manifest = replica.manifest
        let name = "n\(index) (v\(manifest.version))"
        for row in try await replica.database.stateSnapshot() {
            let known = manifest.field(row.field) != nil
            if row.known != known { return "[views] \(name) marks \(row.field) known=\(row.known)" }
            if row.pending && known {
                return "[views] \(name) has known field \(row.field) pending"
            }
        }
        let fields = manifest.documents.first { $0.type == "item" }?.fields ?? []
        for item in try await replica.database.items(inList: list) {
            for spec in fields where spec.kind != .orSet {
                do {
                    switch spec.valueType {
                    case .string:
                        _ = try await replica.read(String.self, spec.name, of: item.id, in: "item")
                    case .bool:
                        _ = try await replica.read(Bool.self, spec.name, of: item.id, in: "item")
                    case .docID:
                        _ = try await replica.read(DocID.self, spec.name, of: item.id, in: "item")
                    case .int64:
                        let value = try await replica.read(
                            Int64.self, spec.name, of: item.id, in: "item")
                        if spec.id == Field.priority, let value, !(0...2).contains(value) {
                            return "[views] \(name) shows priority \(value)"
                        }
                    }
                } catch {
                    return "[views] \(name) can't read \(spec.name): \(error)"
                }
            }
        }
        return nil
    }

    /// The state a fresh v3 replica reaches from every op created.
    private func allV3State() async throws -> [StateRow] {
        let ops = try created.map { try Op(decoding: $0) }.sorted {
            $0.replicaID != $1.replicaID ? $0.replicaID < $1.replicaID : $0.counter < $1.counter
        }
        let newest = (ops.map(\.hlc).max() ?? 0) >> 16
        let fresh = try await Replica.open(
            path: ":memory:", wallClock: FakeClock(millis: newest + 1), manifest: TaskListSchema.v3)
        try await fresh.apply(ops)
        return try await fresh.database.stateSnapshot()
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
        case .hello(_, _, let vector, let schemas, _):
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
