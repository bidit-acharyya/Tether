// 16-byte identifiers: ReplicaID names a device's database, DocID names a document.

import Foundation

public struct ReplicaID: Hashable, Sendable {
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    public static func random() -> ReplicaID {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> ReplicaID {
        ReplicaID(unchecked: randomBytes(using: &generator))
    }

    private init(unchecked bytes: Data) {
        self.bytes = bytes
    }
}

public struct DocID: Hashable, Sendable {
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    public static func random() -> DocID {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> DocID {
        DocID(unchecked: randomBytes(using: &generator))
    }

    private init(unchecked bytes: Data) {
        self.bytes = bytes
    }
}

private func randomBytes<G: RandomNumberGenerator>(using generator: inout G) -> Data {
    Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}
