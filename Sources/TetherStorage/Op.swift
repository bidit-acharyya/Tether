// Op: one immutable change, and its hand-written binary encoding.

import Foundation

public struct Op: Sendable, Equatable {
    public var replicaID: ReplicaID
    public var counter: UInt64
    public var hlc: UInt64
    public var docID: DocID
    public var field: String
    public var kind: UInt8
    public var body: Data

    public init(
        replicaID: ReplicaID, counter: UInt64, hlc: UInt64, docID: DocID, field: String,
        kind: UInt8, body: Data
    ) {
        self.replicaID = replicaID
        self.counter = counter
        self.hlc = hlc
        self.docID = docID
        self.field = field
        self.kind = kind
        self.body = body
    }
}

extension Op {
    public static let formatVersion: UInt8 = 1

    // Layout: version, replicaID, counter, hlc, docID, field, kind, body.
    public func encoded() -> Data {
        var writer = ByteWriter()
        writer.write(Op.formatVersion)
        writer.writeFixed(replicaID.bytes)
        writer.writeVarint(counter)
        writer.writeVarint(hlc)
        writer.writeFixed(docID.bytes)
        writer.writeString(field)
        writer.write(kind)
        writer.writeBytes(body)
        return writer.data
    }

    public init(decoding data: Data) throws {
        var reader = ByteReader(data)
        let version = try reader.read()
        guard version == Op.formatVersion else {
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
        self.init(
            replicaID: replicaID, counter: counter, hlc: hlc, docID: docID,
            field: try reader.readString(), kind: try reader.read(), body: try reader.readBytes())
        guard reader.isAtEnd else { throw StorageError.invalidEncoding("trailing bytes") }
    }
}
