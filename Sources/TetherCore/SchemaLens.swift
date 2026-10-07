// Reading and writing through a manifest: names resolve to stable field ids (renames are
// a read-time lens), never-written fields read as the manifest default without writing
// anything, and migrations that must write emit the same ops on every device.

import CryptoKit
import Foundation
import TetherStorage

extension SchemaManifest {
    /// The spec behind `name`, checked against how the caller wants to use it.
    func spec(_ name: String, in documentType: String, kind: CRDTKind, valueType: ValueType?)
        throws -> FieldSpec
    {
        guard let spec = field(named: name, in: documentType) else {
            throw CoreError.unknownField(name)
        }
        guard spec.kind == kind, spec.valueType == valueType else {
            throw CoreError.typeMismatch(name)
        }
        return spec
    }
}

extension Replica {
    /// Reads a field by the name this version uses. A field that was never written, or a
    /// counter still pending, reads as the manifest's default; the default is never stored.
    public nonisolated func read<V: FieldValue>(
        _: V.Type, _ name: String, of doc: DocID, in documentType: String
    ) async throws -> V? {
        guard let kind = manifest.field(named: name, in: documentType)?.kind else {
            throw CoreError.unknownField(name)
        }
        let spec = try manifest.spec(name, in: documentType, kind: kind, valueType: V.valueType)
        let stored: V?
        switch spec.kind {
        case .lww:
            stored = try await database.register(V.self, doc: doc, field: spec.id)?.value
        case .counter:
            stored = try await database.counter(doc: doc, field: spec.id)?.value as? V
        case .orSet:
            throw CoreError.typeMismatch(name)
        }
        if let stored { return stored }
        guard let encoded = spec.defaultValue else { return nil }
        var reader = ByteReader(encoded)
        return try V.read(from: &reader)
    }

    /// Runs `migration` on `documents`. Safe to run on every device and to repeat: each
    /// device emits identical ops, so the copies collapse. Returns how many ops were new.
    @discardableResult
    public func migrate(_ migration: DataMigration, documents: [DocID]) async throws -> Int {
        guard let spec = manifest.field(migration.field) else {
            throw CoreError.unknownField(migration.field)
        }
        guard spec.kind == .lww, spec.valueType == migration.valueType else {
            throw CoreError.typeMismatch(migration.field)
        }
        return try await apply(documents.map(migration.op))
    }
}

/// A migration that has to write, e.g. storing a default explicitly. Its op for a document
/// has replica id = hash(migration id, document id), counter 1 and HLC 0, so any real edit
/// wins; the body depends only on constants, never on local state.
public struct DataMigration: Sendable {
    public let id: String
    /// Stable field id.
    public let field: String
    /// Stamped on the ops; part of the migration, so every device writes the same bytes.
    public let schemaVersion: UInt64
    let valueType: ValueType?
    private let body: @Sendable (ReplicaID) -> Data

    public init<V: FieldValue>(id: String, field: String, value: V, schemaVersion: UInt64) {
        self.id = id
        self.field = field
        self.schemaVersion = schemaVersion
        self.valueType = V.valueType
        self.body = { author in
            LWWRegister(
                value: value, stamp: Stamp(hlc: HLCTimestamp(rawValue: 0), replicaID: author)
            )
            .encoded()
        }
    }

    public func op(for doc: DocID) -> Op {
        let author = author(of: doc)
        var op = Op(
            replicaID: author, counter: 1, hlc: 0, docID: doc, field: field,
            kind: OpKind.set.rawValue, body: body(author))
        op.schemaVersion = schemaVersion
        return op
    }

    /// The migration's replica id for `doc`: the first 16 bytes of SHA-256 over both ids.
    func author(of doc: DocID) -> ReplicaID {
        var writer = ByteWriter()
        writer.writeString("tether.migration")
        writer.writeString(id)
        writer.writeFixed(doc.bytes)
        let digest = Data(SHA256.hash(data: writer.data).prefix(16))
        guard let id = ReplicaID(bytes: digest) else { preconditionFailure("16-byte digest") }
        return id
    }
}
