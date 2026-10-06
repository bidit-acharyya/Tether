// P2PTransport: peer-to-peer sync over TCP on the local network. Advertises and discovers
// peers with Bonjour (_tether._tcp, replica id in the TXT record) and frames messages with
// a 4-byte length prefix. Each connection opens with a preface frame: the sender's replica id.

import Foundation
import Network
import TetherStorage
import TetherSync
import os

// All mutable state is confined to `queue`, where Network.framework calls every handler.
public final class P2PTransport: Transport, @unchecked Sendable {
    public static let serviceType = "_tether._tcp"

    public let events: AsyncStream<TransportEvent>
    public let peerID: PeerID
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let replicaID: ReplicaID
    private let bonjour: Bool
    private let queue = DispatchQueue(label: "Tether.P2PTransport")
    private let logger = Logger(subsystem: "Tether", category: "p2p")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var links: [PeerID: Link] = [:]
    private var dialing: Set<PeerID> = []

    // Queue-confined, like the transport itself.
    private final class Flag: @unchecked Sendable {
        var isSet = false
    }

    private final class Link: @unchecked Sendable {
        let connection: NWConnection
        let outbound: Bool
        var decoder = FrameDecoder()
        var peer: PeerID?
        var superseded = false

        init(connection: NWConnection, outbound: Bool) {
            self.connection = connection
            self.outbound = outbound
        }
    }

    /// `bonjour: false` skips advertising and browsing; peers are then added with connect(to:).
    public init(replicaID: ReplicaID, bonjour: Bool = true) {
        self.replicaID = replicaID
        self.bonjour = bonjour
        peerID = PeerID(Self.hex(replicaID))
        (events, continuation) = AsyncStream.makeStream()
    }

    public static func hex(_ id: ReplicaID) -> String {
        id.bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Starts listening (and Bonjour, if enabled). Returns the bound TCP port.
    @discardableResult
    public func start(port: NWEndpoint.Port = .any) async throws -> UInt16 {
        let listener = try NWListener(using: Self.parameters(), on: port)
        if bonjour {
            listener.service = NWListener.Service(
                name: peerID.rawValue, type: Self.serviceType,
                txtRecord: NWTXTRecord(["id": peerID.rawValue]))
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.open(connection, outbound: false)
        }
        let bound: UInt16 = try await withCheckedThrowingContinuation { result in
            let resumed = Flag()
            listener.stateUpdateHandler = { state in
                guard !resumed.isSet else { return }
                switch state {
                case .ready:
                    resumed.isSet = true
                    result.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed.isSet = true
                    result.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        queue.sync {
            self.listener = listener
            if bonjour { startBrowsing() }
        }
        return bound
    }

    /// Dials a peer directly, without Bonjour (tests and the CLI demo on one machine).
    public func connect(to endpoint: NWEndpoint) {
        queue.async {
            self.open(NWConnection(to: endpoint, using: Self.parameters()), outbound: true)
        }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            browser?.cancel()
            for link in links.values { link.connection.cancel() }
        }
    }

    public func send(_ message: Message, to peer: PeerID) async throws {
        let frame = FrameDecoder.frame(message.encoded())
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let link = self.links[peer] else {
                    result.resume(throwing: SyncError.notConnected(peer))
                    return
                }
                link.connection.send(
                    content: frame,
                    completion: .contentProcessed { error in
                        if let error { result.resume(throwing: error) } else { result.resume() }
                    })
            }
        }
    }

    private static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        return parameters
    }

    // Only the peer with the lower replica id dials, so two devices don't both connect.
    private func startBrowsing() {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: Self.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                guard case .bonjour(let txt) = result.metadata, let id = txt["id"] else {
                    continue
                }
                let peer = PeerID(id)
                guard peerID.rawValue < id, links[peer] == nil, !dialing.contains(peer) else {
                    continue
                }
                dialing.insert(peer)
                open(NWConnection(to: result.endpoint, using: Self.parameters()), outbound: true)
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func open(_ connection: NWConnection, outbound: Bool) {
        let link = Link(connection: connection, outbound: outbound)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                connection.send(
                    content: FrameDecoder.frame(replicaID.bytes), completion: .idempotent)
                receive(on: link)
            case .failed, .cancelled:
                close(link)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on link: Link) {
        link.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try link.decoder.append(data) { handle(frame, on: link) }
                } catch {
                    logger.error("dropping connection: \(error)")
                    link.connection.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                link.connection.cancel()
            } else {
                receive(on: link)
            }
        }
    }

    private func handle(_ frame: Data, on link: Link) {
        guard let peer = link.peer else {
            guard let id = ReplicaID(bytes: frame), id != replicaID else {
                link.connection.cancel()
                return
            }
            register(link, as: PeerID(Self.hex(id)))
            return
        }
        guard links[peer] === link else { return }
        do {
            continuation.yield(.received(try Message(decoding: frame), from: peer))
        } catch {
            logger.error("bad message from \(peer): \(error)")
        }
    }

    // If both sides connected at once, keep the connection dialed by the lower replica id.
    private func register(_ link: Link, as peer: PeerID) {
        link.peer = peer
        dialing.remove(peer)
        let lower = min(peerID.rawValue, peer.rawValue)
        func dialer(_ candidate: Link) -> String {
            candidate.outbound ? peerID.rawValue : peer.rawValue
        }
        if let existing = links[peer] {
            guard dialer(link) == lower || dialer(existing) != lower else {
                link.superseded = true
                link.connection.cancel()
                return
            }
            existing.superseded = true
            existing.connection.cancel()
            links[peer] = link
            return
        }
        links[peer] = link
        continuation.yield(.connected(peer))
    }

    private func close(_ link: Link) {
        guard let peer = link.peer else { return }
        dialing.remove(peer)
        guard !link.superseded, links[peer] === link else { return }
        links[peer] = nil
        continuation.yield(.disconnected(peer))
    }
}
