// Transport: how the sync engine reaches peers. Implementations only move messages; the
// engine never imports Network or CloudKit.

public struct PeerID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum TransportEvent: Sendable, Equatable {
    case connected(PeerID)
    case disconnected(PeerID)
    case received(Message, from: PeerID)
}

public protocol Transport: Sendable {
    var events: AsyncStream<TransportEvent> { get }
    func send(_ message: Message, to peer: PeerID) async throws
}
