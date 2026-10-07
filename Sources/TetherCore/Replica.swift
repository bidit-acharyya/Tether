// Replica: one device's store. Turns local changes into stamped ops and applies remote
// ops idempotently, each in a single transaction, and publishes which documents changed.

import Foundation
import TetherStorage

public actor Replica {
    public nonisolated let id: ReplicaID
    public nonisolated let database: Database
    /// What this app version knows about its data.
    public nonisolated let manifest: SchemaManifest
    private let wallClock: any WallClock
    private var subscribers: [UUID: AsyncStream<Set<DocID>>.Continuation] = [:]

    private init(
        database: Database, id: ReplicaID, manifest: SchemaManifest, wallClock: any WallClock
    ) {
        self.database = database
        self.id = id
        self.manifest = manifest
        self.wallClock = wallClock
    }

    /// Opens a store as the app version described by `manifest`. Upgrading from the store's
    /// last manifest is checked first; opening it with an older app version is allowed.
    /// When the manifest changes, state is rebuilt from the op log, so fields that just
    /// became known or mergeable (like pending counters) are computed from every op.
    public static func open(
        path: String, wallClock: any WallClock = SystemClock(), replicaID: ReplicaID? = nil,
        manifest: SchemaManifest = TaskListSchema.v1
    ) async throws -> Replica {
        try manifest.validate()
        let database = try await Database.openStore(path: path, replicaID: replicaID)
        await database.setMergeRules(FieldMerger.rules(for: manifest))
        let previous = try await database.storedManifest()
        if let previous, previous.version < manifest.version {
            try manifest.validate(upgradingFrom: previous)
        }
        if previous != manifest {
            try await database.rebuildState()
            try await database.saveManifest(manifest)
        }
        return Replica(
            database: database, id: try await database.replicaID(), manifest: manifest,
            wallClock: wallClock)
    }

    /// Ids of documents changed by each local change or remote batch, as they commit.
    public func changes() -> AsyncStream<Set<DocID>> {
        let (stream, continuation) = AsyncStream<Set<DocID>>.makeStream()
        let key = UUID()
        subscribers[key] = continuation
        continuation.onTermination = { _ in Task { await self.unsubscribe(key) } }
        return stream
    }

    // The clock is rebuilt from the store inside each transaction, so concurrent calls can't
    // hand out the same HLC even though actor methods can interleave at an await.

    /// Applies a local change and returns the ops it produced.
    @discardableResult
    public func perform(_ change: Change) async throws -> [Op] {
        let (id, wallClock, manifest) = (self.id, self.wallClock, self.manifest)
        let ops = try await database.transaction { db in
            let clock = HybridLogicalClock(wallClock: wallClock, last: try db.lastHLC())
            var writer = OpWriter(
                replica: id, manifest: manifest, clock: clock, counter: try db.nextCounter())
            try db.write(change, into: &writer)
            // A version only writes what its manifest declares.
            for op in writer.ops {
                guard let spec = manifest.field(op.field), spec.kind.opKinds.contains(op.kind)
                else { throw CoreError.notInManifest(field: op.field, kind: op.kind) }
            }
            _ = try db.appendInTransaction(writer.ops)
            try db.saveHLC(writer.clock.last)
            return writer.ops
        }
        publish(ops)
        return ops
    }

    /// Applies ops from another replica. Ops already present are skipped; returns how many
    /// were new. Throws, applying nothing, if any op's HLC is too far ahead of this clock.
    @discardableResult
    public func apply(_ ops: [Op]) async throws -> Int {
        let wallClock = self.wallClock
        let inserted = try await database.transaction { db in
            var clock = HybridLogicalClock(wallClock: wallClock, last: try db.lastHLC())
            for op in ops {
                _ = try clock.receive(HLCTimestamp(rawValue: op.hlc))
            }
            let inserted = try db.appendInTransaction(ops)
            try db.saveHLC(clock.last)
            return inserted
        }
        if inserted > 0 { publish(ops) }
        return inserted
    }

    private func publish(_ ops: [Op]) {
        let docs = Set(ops.map(\.docID))
        guard !docs.isEmpty else { return }
        for continuation in subscribers.values { continuation.yield(docs) }
    }

    private func unsubscribe(_ key: UUID) {
        subscribers[key] = nil
    }
}
