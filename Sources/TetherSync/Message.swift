// The sync protocol's three messages and their binary encoding.

import Foundation
import TetherStorage

public enum SyncError: Error, Equatable {
    case unsupportedMessageVersion(UInt8)
    case unknownMessageType(UInt8)
    case notConnected(PeerID)
}

public enum Message: Sendable, Equatable {
    /// Sent on connect: who I am, which protocol I speak, and what I have.
    case hello(replicaID: ReplicaID, protocolVersion: UInt64, vector: VersionVector)
    /// A batch of ops the receiver is missing.
    case ops([Op])
    /// Sent after a batch is durably committed: what I now have.
    case ack(VersionVector)

    public static let formatVersion: UInt8 = 1
    public static let protocolVersion: UInt64 = 1
}

// Layout: format version, type byte, then the message's fields. Ops are length-prefixed
// encodings of Op, so the op format can evolve independently of the message format.
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
        case .hello(let replicaID, let protocolVersion, let vector):
            writer.write(Kind.hello.rawValue)
            writer.writeFixed(replicaID.bytes)
            writer.writeVarint(protocolVersion)
            vector.write(to: &writer)
        case .ops(let ops):
            writer.write(Kind.ops.rawValue)
            writer.writeVarint(UInt64(ops.count))
            for op in ops { writer.writeBytes(op.encoded()) }
        case .ack(let vector):
            writer.write(Kind.ack.rawValue)
            vector.write(to: &writer)
        }
        return writer.data
    }

    public init(decoding data: Data) throws {
        var reader = ByteReader(data)
        let version = try reader.read()
        guard version == Message.formatVersion else {
            throw SyncError.unsupportedMessageVersion(version)
        }
        let type = try reader.read()
        switch Kind(rawValue: type) {
        case .hello:
            guard let replicaID = ReplicaID(bytes: try reader.readFixed(16)) else {
                throw StorageError.truncated
            }
            self = .hello(
                replicaID: replicaID, protocolVersion: try reader.readVarint(),
                vector: try VersionVector.read(from: &reader))
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
        guard reader.isAtEnd else { throw StorageError.invalidEncoding("trailing bytes") }
    }
}
