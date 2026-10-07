// The sync protocol's three messages and their binary encoding.
// Format 2 adds the schema version range to Hello and a trailing extension area that
// decoders skip, so later additions don't break peers running this code.

import Foundation
import TetherStorage

public enum SyncError: Error, Equatable {
    case unsupportedMessageVersion(UInt8)
    case unknownMessageType(UInt8)
    case notConnected(PeerID)
}

public enum Message: Sendable, Equatable {
    /// Sent on connect: who I am, which protocol and app schema versions I speak, and what I
    /// have. A peer on a newer schema is still synced with; the range is informational.
    case hello(
        replicaID: ReplicaID, protocolVersion: UInt64, vector: VersionVector,
        schemaVersions: ClosedRange<UInt64> = 1...1)
    /// A batch of ops the receiver is missing.
    case ops([Op])
    /// Sent after a batch is durably committed: what I now have.
    case ack(VersionVector)

    public static let formatVersion: UInt8 = 2
    public static let protocolVersion: UInt64 = 2
}

// Layout: format version, type byte, the message's fields, then (format 2) an extension
// count and (tag, length-prefixed bytes) entries. Ops are length-prefixed encodings of Op,
// so the op format can evolve independently of the message format.
extension Message {
    private enum Kind: UInt8 {
        case hello = 1
        case ops = 2
        case ack = 3
    }

    public func encoded() -> Data {
        var writer = ByteWriter()
        writer.write(Message.formatVersion)
        switch self {
        case .hello(let replicaID, let protocolVersion, let vector, let schemaVersions):
            writer.write(Kind.hello.rawValue)
            writer.writeFixed(replicaID.bytes)
            writer.writeVarint(protocolVersion)
            vector.write(to: &writer)
            writer.writeVarint(schemaVersions.lowerBound)
            writer.writeVarint(schemaVersions.upperBound)
        case .ops(let ops):
            writer.write(Kind.ops.rawValue)
            writer.writeVarint(UInt64(ops.count))
            for op in ops { writer.writeBytes(op.encoded()) }
        case .ack(let vector):
            writer.write(Kind.ack.rawValue)
            vector.write(to: &writer)
        }
        writer.writeVarint(0)  // No extensions yet.
        return writer.data
    }

    public init(decoding data: Data) throws {
        var reader = ByteReader(data)
        let version = try reader.read()
        guard version == 1 || version == 2 else {
            throw SyncError.unsupportedMessageVersion(version)
        }
        let type = try reader.read()
        switch Kind(rawValue: type) {
        case .hello:
            guard let replicaID = ReplicaID(bytes: try reader.readFixed(16)) else {
                throw StorageError.truncated
            }
            let protocolVersion = try reader.readVarint()
            let vector = try VersionVector.read(from: &reader)
            var schemaVersions: ClosedRange<UInt64> = 1...1
            if version == 2 {
                let lower = try reader.readVarint()
                let upper = try reader.readVarint()
                guard lower <= upper else {
                    throw StorageError.invalidEncoding("empty schema version range")
                }
                schemaVersions = lower...upper
            }
            self = .hello(
                replicaID: replicaID, protocolVersion: protocolVersion, vector: vector,
                schemaVersions: schemaVersions)
        case .ops:
            var ops: [Op] = []
            for _ in 0..<(try reader.readVarint()) {
                ops.append(try Op(decoding: try reader.readBytes()))
            }
            self = .ops(ops)
        case .ack:
            self = .ack(try VersionVector.read(from: &reader))
        case nil:
            throw SyncError.unknownMessageType(type)
        }
        if version == 2 {
            for _ in 0..<(try reader.readVarint()) {
                _ = try reader.readVarint()
                _ = try reader.readBytes()
            }
        }
        guard reader.isAtEnd else { throw StorageError.invalidEncoding("trailing bytes") }
    }
}
