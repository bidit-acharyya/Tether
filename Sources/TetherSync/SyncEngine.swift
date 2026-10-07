// SyncEngine: runs a SyncSession per connected peer over a Transport, and executes the
// effects: sends, applies (one transaction per batch), loads, and timers.

import Foundation
import TetherCore
import TetherStorage
import os

public actor SyncEngine {
    public struct PeerStatus: Sendable, Equatable {
        public let peer: PeerID
        public let phase: SyncSession.Phase
        public let unackedBatches: Int
        public let peerVector: VersionVector
        /// The peer's app schema versions, once its hello arrives.
        public let peerSchemaVersions: ClosedRange<UInt64>?
    }

    private let replica: Replica
    private let transport: any Transport
    private var sessions: [PeerID: SyncSession] = [:]
    private var timers: [PeerID: [SyncSession.TimerID: Task<Void, Never>]] = [:]
    private let logger = Logger(subsystem: "Tether", category: "sync")

    public init(replica: Replica, transport: any Transport) {
        self.replica = replica
        self.transport = transport
    }

    /// Runs until the transport's event stream ends or the task is cancelled.
    public func run() async {
        let changes = await replica.changes()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in changes { await self.localChanged() }
            }
            group.addTask {
                for await event in self.transport.events { await self.receive(event) }
            }
            await group.next()
            group.cancelAll()
        }
        for peer in sessions.keys { cancelTimers(peer) }
    }

    public func statuses() -> [PeerStatus] {
        sessions.sorted { $0.key.rawValue < $1.key.rawValue }.map { peer, session in
            PeerStatus(
                peer: peer, phase: session.phase, unackedBatches: session.unackedBatches,
                peerVector: session.peerVector, peerSchemaVersions: session.peerSchemaVersions)
        }
    }

    private func receive(_ event: TransportEvent) async {
        switch event {
        case .connected(let peer):
            cancelTimers(peer)
            sessions[peer] = SyncSession(
                replicaID: replica.id, schemaVersions: 1...replica.manifest.version)
            await handle(peer, .connected(local: await localVector()))
        case .disconnected(let peer):
            cancelTimers(peer)
            sessions[peer] = nil
        case .received(let message, let peer):
            await handle(peer, .received(message))
        }
    }

    private func localChanged() async {
        let vector = await localVector()
        for peer in sessions.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            await handle(peer, .localChanged(vector))
        }
    }

    // State is updated before any await, so an interleaved event always sees it.
    private func handle(_ peer: PeerID, _ event: SyncSession.Event) async {
        guard var session = sessions[peer] else { return }
        let effects = session.handle(event)
        sessions[peer] = session
        for effect in effects { await execute(effect, for: peer) }
    }

    private func execute(_ effect: SyncSession.Effect, for peer: PeerID) async {
        switch effect {
        case .send(let message):
            do {
                try await transport.send(message, to: peer)
            } catch {
                logger.debug("send to \(peer) failed: \(error); retry timers will resend")
            }
        case .apply(let ops):
            do {
                try await replica.apply(ops)
                await handle(peer, .applied(local: await localVector()))
            } catch {
                logger.error("rejected \(ops.count) ops from \(peer): \(error)")
            }
        case .load(let vector):
            do {
                let ops = try await replica.database.ops(missingFrom: vector.counters)
                await handle(peer, .loaded(ops))
            } catch {
                logger.error("loading ops for \(peer) failed: \(error)")
                await handle(peer, .loaded([]))
            }
        case .setTimer(let id, let delay):
            timers[peer]?[id]?.cancel()
            timers[peer, default: [:]][id] = Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self.handle(peer, .timerFired(id))
            }
        }
    }

    private func localVector() async -> VersionVector {
        VersionVector((try? await replica.database.versionVector()) ?? [:])
    }

    private func cancelTimers(_ peer: PeerID) {
        for task in timers[peer]?.values ?? [:].values { task.cancel() }
        timers[peer] = nil
    }
}
