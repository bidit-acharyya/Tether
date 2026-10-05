// InMemoryTransport: direct, fault-free delivery between transports on one InMemoryNetwork.
// Messages still go through encode and decode, so unit tests exercise the wire format.

import Foundation

public actor InMemoryNetwork {
    private var endpoints: [PeerID: InMemoryTransport] = [:]
    private var links: Set<Set<PeerID>> = []

    public init() {}

    public func makeTransport(_ id: PeerID) -> InMemoryTransport {
        let transport = InMemoryTransport(id: id, network: self)
        endpoints[id] = transport
        return transport
    }

    public func connect(_ a: PeerID, _ b: PeerID) {
        guard links.insert([a, b]).inserted else { return }
        endpoints[a]?.emit(.connected(b))
        endpoints[b]?.emit(.connected(a))
    }

    public func disconnect(_ a: PeerID, _ b: PeerID) {
        guard links.remove([a, b]) != nil else { return }
        endpoints[a]?.emit(.disconnected(b))
        endpoints[b]?.emit(.disconnected(a))
    }

    func deliver(_ data: Data, from sender: PeerID, to receiver: PeerID) throws {
        guard links.contains([sender, receiver]), let endpoint = endpoints[receiver] else {
            throw SyncError.notConnected(receiver)
        }
        endpoint.emit(.received(try Message(decoding: data), from: sender))
    }
}

public final class InMemoryTransport: Transport {
    public let id: PeerID
    public let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let network: InMemoryNetwork

    init(id: PeerID, network: InMemoryNetwork) {
        self.id = id
        self.network = network
        (events, continuation) = AsyncStream.makeStream()
    }

    public func send(_ message: Message, to peer: PeerID) async throws {
        try await network.deliver(message.encoded(), from: id, to: peer)
    }

    func emit(_ event: TransportEvent) {
        continuation.yield(event)
    }
}
