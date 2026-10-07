// Op: one immutable change, and its hand-written binary encoding.
// Format 2 adds an extension area of (tag, bytes) pairs. Decoders keep tags they don't
// know and write them back unchanged, so an older device can forward a newer op intact.

import Foundation

public struct Op: Sendable, Equatable {
    public var replicaID: ReplicaID
    public var counter: UInt64
    public var hlc: UInt64
    public var docID: DocID
    public var field: String
    public var kind: UInt8
    public var body: Data
    /// Extension tag → raw bytes, including tags this code doesn't understand.
    public var extensions: [UInt64: Data]

    public init(
        replicaID: ReplicaID, counter: UInt64, hlc: UInt64, docID: DocID, field: String,
        kind: UInt8, body: Data, extensions: [UInt64: Data] = [:]
    ) {
        self.replicaID = replicaID
        self.counter = counter
        self.hlc = hlc
        self.docID = docID
        self.field = field
        self.kind = kind
        self.body = body
        self.extensions = extensions
    }
}

extension Op {
    public enum ExtensionTag {
        public static let schemaVersion: UInt64 = 1
    }

    /// The writer's app schema version; nil for ops written before schema versions existed.
    public var schemaVersion: UInt64? {
        get {
            guard let bytes = extensions[ExtensionTag.schemaVersion] else { return nil }
            var reader = ByteReader(bytes)
            return try? reader.readVarint()
        }
        set {
            guard let newValue else {
                extensions[ExtensionTag.schemaVersion] = nil
                return
            }
            var writer = ByteWriter()
            writer.writeVarint(newValue)
            extensions[ExtensionTag.schemaVersion] = writer.data
        }
    }
}

extension Op {
    public static let formatVersion: UInt8 = 2

    // Layout: version, replicaID, counter, hlc, docID, field, kind, body, then in format 2
    // an extension count and (tag varint, length-prefixed bytes) sorted by tag. An op with
    // no extensions is written as format 1, so ops from before format 2 keep their bytes.
    public func encoded() -> Data {
        var writer = ByteWriter()
        writer.write(extensions.isEmpty ? 1 : 2)
        writer.writeFixed(replicaID.bytes)
        writer.writeVarint(counter)
        writer.writeVarint(hlc)
        writer.writeFixed(docID.bytes)
        writer.writeString(field)
        writer.write(kind)
        writer.writeBytes(body)
        if !extensions.isEmpty {
            writer.writeVarint(UInt64(extensions.count))
            for (tag, bytes) in extensions.sorted(by: { $0.key < $1.key }) {
                writer.writeVarint(tag)
                writer.writeBytes(bytes)
            }
        }
        return writer.data
    }

    public init(decoding data: Data) throws {
        var reader = ByteReader(data)
        let version = try reader.read()
        guard version == 1 || version == 2 else {
            throw StorageError.unknownFormatVersion(version)
        }
        guard let replicaID = ReplicaID(bytes: try reader.readFixed(16)) else {
            throw StorageError.truncated
        }
        let counter = try reader.readVarint()
        let hlc = try reader.readVarint()
        guard let docID = DocID(bytes: try reader.readFixed(16)) else {
            throw StorageError.truncated
        }
        let field = try reader.readString()
        let kind = try reader.read()
        let body = try reader.readBytes()
        var extensions: [UInt64: Data] = [:]
        if version == 2 {
            for _ in 0..<(try reader.readVarint()) {
                let tag = try reader.readVarint()
                guard extensions[tag] == nil else {
                    throw StorageError.invalidEncoding("duplicate extension tag")
                }
                extensions[tag] = try reader.readBytes()
            }
        }
        guard reader.isAtEnd else { throw StorageError.invalidEncoding("trailing bytes") }
        self.init(
            replicaID: replicaID, counter: counter, hlc: hlc, docID: docID, field: field,
            kind: kind, body: body, extensions: extensions)
    }
}
