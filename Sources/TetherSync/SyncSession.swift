// SyncSession: the sync protocol for one peer, as a pure state machine. handle(event)
// returns effects and does no I/O, so the real engine and the deterministic simulator
// drive exactly the same logic. States are drawn in docs/sync-session.md.

import TetherStorage

public struct SyncSession: Sendable {
    public enum Phase: Sendable, Equatable {
        case idle, handshaking, live
    }

    public enum TimerID: Hashable, Sendable {
        case hello
        case batch(UInt64)
    }

    public enum Event: Sendable {
        /// The transport connected; `local` is this replica's vector right now.
        case connected(local: VersionVector)
        case received(Message)
        case timerFired(TimerID)
        /// This replica's store changed (a local edit, or ops from any peer).
        case localChanged(VersionVector)
        /// The ops a `.load` effect asked for.
        case loaded([Op])
        /// A `.apply` effect committed; `local` is this replica's vector after it.
        case applied(local: VersionVector)
    }

    public enum Effect: Sendable, Equatable {
        case send(Message)
        case apply([Op])
        /// Read the ops in this store that a peer with `missingFrom` lacks.
        case load(missingFrom: VersionVector)
        case setTimer(TimerID, after: Duration)
    }

    struct Batch: Sendable {
        let ops: [Op]
        let vector: VersionVector
        var attempt = 0
    }

    public static let maxBatchBytes = 256 * 1024
    public static let helloRetry = Duration.seconds(2)
    public static let maxBackoff = Duration.seconds(30)

    public let replicaID: ReplicaID
    /// App schema versions this replica can read: 1 up to its manifest's version.
    public let schemaVersions: ClosedRange<UInt64>
    public private(set) var phase = Phase.idle
    public private(set) var peerReplicaID: ReplicaID?
    public private(set) var peerSchemaVersions: ClosedRange<UInt64>?
    /// What the peer has told us it has, via hello and acks.
    public private(set) var peerVector = VersionVector()
    /// peerVector plus everything sent and not yet acked: no need to send it again.
    private var promised = VersionVector()
    private var local = VersionVector()
    private var inFlight: [UInt64: Batch] = [:]
    private var nextBatchID: UInt64 = 1
    private var loading = false
    private var reloadNeeded = false

    public init(replicaID: ReplicaID, schemaVersions: ClosedRange<UInt64> = 1...1) {
        self.replicaID = replicaID
        self.schemaVersions = schemaVersions
    }

    public var unackedBatches: Int { inFlight.count }

    /// Retry delay after `attempt` failed sends: 1 s, 2 s, 4 s, ... capped at 30 s.
    public static func backoff(attempt: Int) -> Duration {
        min(.seconds(1 << min(attempt, 5)), maxBackoff)
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .connected(let vector):
            local = vector
            phase = .handshaking
            return [.send(hello()), .setTimer(.hello, after: Self.helloRetry)]

        case .timerFired(.hello):
            guard phase == .handshaking else { return [] }
            return [.send(hello()), .setTimer(.hello, after: Self.helloRetry)]

        case .timerFired(.batch(let id)):
            guard var batch = inFlight[id] else { return [] }
            guard !peerVector.dominates(batch.vector) else {
                inFlight[id] = nil
                return []
            }
            batch.attempt += 1
            inFlight[id] = batch
            return [
                .send(.ops(batch.ops)),
                .setTimer(.batch(id), after: Self.backoff(attempt: batch.attempt)),
            ]

        case .received(.hello(let id, _, let vector, let peerSchemas)):
            // A peer on a newer schema is accepted, never refused: ops for fields this
            // version doesn't know are still stored, merged and forwarded.
            peerReplicaID = id
            peerSchemaVersions = peerSchemas
            peerVector.merge(vector)
            promised.merge(vector)
            // A repeated hello means ours was lost: answer it so the peer can go live.
            let wasLive = phase == .live
            phase = .live
            return (wasLive ? [.send(hello())] : []) + loadIfNeeded()

        case .received(.ops(let ops)):
            guard !ops.isEmpty else { return [] }
            // Peers only send ops from their gap-free prefix, so this proves the peer has
            // everything up to these counters; without it we'd echo its ops straight back.
            let sent = Self.vector(of: ops)
            peerVector.merge(sent)
            promised.merge(sent)
            return [.apply(ops)]

        case .received(.ack(let vector)):
            peerVector.merge(vector)
            promised.merge(vector)
            inFlight = inFlight.filter { !peerVector.dominates($0.value.vector) }
            return loadIfNeeded()

        case .applied(let vector):
            local = vector
            return [.send(.ack(vector))] + loadIfNeeded()

        case .localChanged(let vector):
            local = vector
            return loadIfNeeded()

        case .loaded(let ops):
            loading = false
            let fresh = ops.filter { $0.counter > promised[$0.replicaID] }
            var effects: [Effect] = []
            for chunk in Self.batches(of: fresh) {
                let id = nextBatchID
                nextBatchID += 1
                let batch = Batch(ops: chunk, vector: Self.vector(of: chunk))
                inFlight[id] = batch
                promised.merge(batch.vector)
                effects += [
                    .send(.ops(chunk)), .setTimer(.batch(id), after: Self.backoff(attempt: 0)),
                ]
            }
            if reloadNeeded {
                reloadNeeded = false
                effects += loadIfNeeded()
            }
            return effects
        }
    }

    private func hello() -> Message {
        .hello(
            replicaID: replicaID, protocolVersion: Message.protocolVersion, vector: local,
            schemaVersions: schemaVersions)
    }

    /// Asks for whatever the peer may lack, unless a load is already outstanding.
    private mutating func loadIfNeeded() -> [Effect] {
        guard phase == .live, !promised.dominates(local) else { return [] }
        guard !loading else {
            reloadNeeded = true
            return []
        }
        loading = true
        return [.load(missingFrom: promised)]
    }

    /// Splits ops into batches of at most maxBatchBytes (a single bigger op goes alone).
    static func batches(of ops: [Op]) -> [[Op]] {
        var batches: [[Op]] = []
        var current: [Op] = []
        var size = 0
        for op in ops {
            let opSize = op.encoded().count + 4
            if !current.isEmpty && size + opSize > maxBatchBytes {
                batches.append(current)
                current = []
                size = 0
            }
            current.append(op)
            size += opSize
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    static func vector(of ops: [Op]) -> VersionVector {
        var counters: [ReplicaID: UInt64] = [:]
        for op in ops { counters[op.replicaID] = max(counters[op.replicaID] ?? 0, op.counter) }
        return VersionVector(counters)
    }
}
