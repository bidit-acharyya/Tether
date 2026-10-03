// Table-based CRC-32 (IEEE 802.3, the same one zip and PNG use).

import Foundation

public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 {
            crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
        }
        return crc
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
