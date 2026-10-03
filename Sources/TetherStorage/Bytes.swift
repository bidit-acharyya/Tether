// ByteWriter and ByteReader: the building blocks of Tether's binary formats.

import Foundation

public struct ByteWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func write(_ byte: UInt8) {
        data.append(byte)
    }

    /// Unsigned LEB128: 7 bits per byte, high bit set on every byte but the last.
    public mutating func writeVarint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(truncatingIfNeeded: value) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    public mutating func writeFixed(_ bytes: Data) {
        data.append(bytes)
    }

    public mutating func writeBytes(_ bytes: Data) {
        writeVarint(UInt64(bytes.count))
        data.append(bytes)
    }

    public mutating func writeString(_ string: String) {
        writeBytes(Data(string.utf8))
    }
}

public struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    public init(_ data: Data) {
        bytes = [UInt8](data)
    }

    public var isAtEnd: Bool { offset == bytes.count }

    public mutating func read() throws -> UInt8 {
        guard offset < bytes.count else { throw StorageError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func readVarint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 7) {
            let byte = try read()
            // The 10th byte holds only the top bit of a UInt64.
            guard shift < 63 || byte <= 1 else {
                throw StorageError.invalidEncoding("varint overflows UInt64")
            }
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
        }
        throw StorageError.invalidEncoding("varint longer than 10 bytes")
    }

    public mutating func readFixed(_ count: Int) throws -> Data {
        guard count <= bytes.count - offset else { throw StorageError.truncated }
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }

    public mutating func readBytes() throws -> Data {
        let length = try readVarint()
        guard length <= UInt64(bytes.count - offset) else { throw StorageError.truncated }
        return try readFixed(Int(length))
    }

    public mutating func readString() throws -> String {
        guard let string = String(data: try readBytes(), encoding: .utf8) else {
            throw StorageError.invalidEncoding("string is not valid UTF-8")
        }
        return string
    }
}
