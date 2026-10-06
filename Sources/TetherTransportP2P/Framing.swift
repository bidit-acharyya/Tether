// Length-prefixed framing for a TCP byte stream: each frame is a 4-byte big-endian length
// followed by that many bytes. The decoder accumulates bytes and yields whole frames.

import Foundation

public enum FrameError: Error, Equatable {
    case frameTooLarge(Int)
}

public struct FrameDecoder: Sendable {
    /// Batches are capped at 256 KB, so anything near this is a bug or an attack.
    public static let maxFrameBytes = 8 * 1024 * 1024

    private var buffer: [UInt8] = []

    public init() {}

    public static func frame(_ payload: Data) -> Data {
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) } + payload
    }

    /// Adds received bytes and returns every frame now complete, in order.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(contentsOf: data)
        var frames: [Data] = []
        var offset = 0
        while buffer.count - offset >= 4 {
            let length = buffer[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length <= Self.maxFrameBytes else { throw FrameError.frameTooLarge(length) }
            guard buffer.count - offset - 4 >= length else { break }
            frames.append(Data(buffer[(offset + 4)..<(offset + 4 + length)]))
            offset += 4 + length
        }
        buffer.removeFirst(offset)
        return frames
    }
}
