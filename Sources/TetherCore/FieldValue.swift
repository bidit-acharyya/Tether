// FieldValue: a value a CRDT can hold, with its binary encoding.

import Foundation
import TetherStorage

public protocol FieldValue: Sendable, Equatable {
    func write(to writer: inout ByteWriter)
    static func read(from reader: inout ByteReader) throws -> Self
}

/// A value an ORSet can hold. Each one encodes as length-prefixed bytes, so a set of any
/// element type can be merged as a set of raw Data without knowing the type.
public protocol SetElement: FieldValue, Hashable {}

extension String: SetElement {}
extension Data: SetElement {}
extension DocID: SetElement {}

extension DocID: FieldValue {
    public func write(to writer: inout ByteWriter) {
        writer.writeBytes(bytes)
    }

    public static func read(from reader: inout ByteReader) throws -> DocID {
        guard let id = DocID(bytes: try reader.readBytes()) else {
            throw StorageError.invalidEncoding("doc id is not 16 bytes")
        }
        return id
    }
}

extension String: FieldValue {
    public func write(to writer: inout ByteWriter) {
        writer.writeString(self)
    }

    public static func read(from reader: inout ByteReader) throws -> String {
        try reader.readString()
    }
}

extension Bool: FieldValue {
    public func write(to writer: inout ByteWriter) {
        writer.write(self ? 1 : 0)
    }

    public static func read(from reader: inout ByteReader) throws -> Bool {
        switch try reader.read() {
        case 0: return false
        case 1: return true
        default: throw StorageError.invalidEncoding("bool is not 0 or 1")
        }
    }
}

extension Int64: FieldValue {
    // Zigzag, so small negative numbers stay short as varints.
    public func write(to writer: inout ByteWriter) {
        writer.writeVarint(UInt64(bitPattern: (self << 1) ^ (self >> 63)))
    }

    public static func read(from reader: inout ByteReader) throws -> Int64 {
        let raw = try reader.readVarint()
        return Int64(bitPattern: raw >> 1) ^ -Int64(bitPattern: raw & 1)
    }
}

extension Data: FieldValue {
    public func write(to writer: inout ByteWriter) {
        writer.writeBytes(self)
    }

    public static func read(from reader: inout ByteReader) throws -> Data {
        try reader.readBytes()
    }
}
