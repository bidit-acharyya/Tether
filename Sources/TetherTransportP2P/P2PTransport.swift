// P2PTransport: peer-to-peer sync over TCP on the local network. Advertises and discovers
// peers with Bonjour (_tether._tcp, replica id in the TXT record) and frames messages with
// a 4-byte length prefix. Each connection opens with a preface frame: the sender's replica id.
// The dialing side redials with backoff when a connection drops, and the listener and
// browser restart if the system kills them (e.g. while an iOS app is in the background).

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
    private var listenPort = NWEndpoint.Port.any
    private var browser: NWBrowser?
    private var stopped = false
    private var links: [PeerID: Link] = [:]
    private var open: [ObjectIdentifier: Link] = [:]
    private var dialing: Set<PeerID> = []
    /// Where to redial each peer this side dials.
    private var endpoints: [PeerID: NWEndpoint] = [:]
    private var redialAttempts: [PeerID: Int] = [:]

    // Queue-confined, like the transport itself.
    private final class Flag: @unchecked Sendable {
        var isSet = false
    }

    private final class Link: @unchecked Sendable {
        let connection: NWConnection
        let outbound: Bool
        /// For outbound links, the peer we meant to reach (known before its preface).
        let target: PeerID?
        var decoder = FrameDecoder()
        var peer: PeerID?
        var superseded = false
        var closed = false

        init(connection: NWConnection, outbound: Bool, target: PeerID?) {
            self.connection = connection
            self.outbound = outbound
            self.target = target
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
        let listener = try makeListener(on: port)
        let bound: UInt16 = try await withCheckedThrowingContinuation { result in
            let resumed = Flag()
            listener.stateUpdateHandler = { [weak self] state in
                guard resumed.isSet else {
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
                    return
                }
                if case .failed(let error) = state { self?.listenerFailed(error) }
            }
            listener.start(queue: queue)
        }
        queue.sync {
            self.listener = listener
            listenPort = port
            if bonjour { startBrowsing() }
        }
        return bound
    }

    /// Dials a peer directly, without Bonjour (tests and the CLI demo on one machine).
    public func connect(to endpoint: NWEndpoint) {
        queue.async {
            self.dial(endpoint, target: nil)
        }
    }

    public func stop() {
        queue.sync {
            stopped = true
            listener?.cancel()
            browser?.cancel()
            for link in open.values { link.connection.cancel() }
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
        let parameters = NWParameters(tls: nil, tcp: tcpOptions())
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    // TCP doesn't notice a silent network drop by itself, so a dead connection could look
    // live for minutes. Keepalive catches it when idle (about 11 s), the drop time when ops
    // are stuck unacknowledged; either way the link closes and the redial loop takes over.
    static func tcpOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionDropTime = 15
        tcp.connectionTimeout = 10
        return tcp
    }

    // MARK: Listener and browser

    private func makeListener(on port: NWEndpoint.Port) throws -> NWListener {
        let listener = try NWListener(using: Self.parameters(), on: port)
        if bonjour {
            listener.service = NWListener.Service(
                name: peerID.rawValue, type: Self.serviceType,
                txtRecord: NWTXTRecord(["id": peerID.rawValue]))
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.openLink(connection, outbound: false, target: nil)
        }
        return listener
    }

    private func listenerFailed(_ error: NWError) {
        logger.error("listener failed: \(error); restarting")
        listener?.cancel()
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !stopped else { return }
            do {
                let replacement = try makeListener(on: listenPort)
                replacement.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state { self?.listenerFailed(error) }
                }
                replacement.start(queue: queue)
                listener = replacement
            } catch {
                listenerFailed(.posix(.EADDRINUSE))
            }
        }
    }

    // Only the peer with the lower replica id dials, so two devices don't both connect.
    private func startBrowsing() {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: Self.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                guard case .bonjour(let txt) = result.metadata, let id = txt["id"],
                    peerID.rawValue < id
                else { continue }
                let peer = PeerID(id)
                endpoints[peer] = result.endpoint
                if links[peer] == nil, !dialing.contains(peer) {
                    dial(result.endpoint, target: peer)
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self, case .failed(let error) = state else { return }
            logger.error("browser failed: \(error); restarting")
            browser.cancel()
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !stopped else { return }
                startBrowsing()
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    // MARK: Connections

    private func dial(_ endpoint: NWEndpoint, target: PeerID?) {
        if let target { dialing.insert(target) }
        openLink(
            NWConnection(to: endpoint, using: Self.parameters()), outbound: true, target: target)
    }

    private func openLink(_ connection: NWConnection, outbound: Bool, target: PeerID?) {
        let link = Link(connection: connection, outbound: outbound, target: target)
        open[ObjectIdentifier(link)] = link
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                connection.send(
                    content: FrameDecoder.frame(replicaID.bytes), completion: .idempotent)
                receive(on: link)
            case .waiting(let error) where outbound:
                // Unreachable for now (peer gone, Wi-Fi off): give up and redial with backoff.
                logger.debug("dial waiting: \(error)")
                connection.cancel()
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
        }
        if link.outbound { endpoints[peer] = link.connection.endpoint }
        redialAttempts[peer] = 0
        let isNew = links[peer] == nil
        links[peer] = link
        if isNew { continuation.yield(.connected(peer)) }
    }

    private func close(_ link: Link) {
        guard !link.closed else { return }
        link.closed = true
        open[ObjectIdentifier(link)] = nil
        let peer = link.peer ?? link.target
        if let peer { dialing.remove(peer) }
        if let registered = link.peer, !link.superseded, links[registered] === link {
            links[registered] = nil
            continuation.yield(.disconnected(registered))
        }
        if link.outbound, !link.superseded, let peer, links[peer] == nil {
            scheduleRedial(peer)
        }
    }

    // Backoff 1, 2, 4 … 30 s; a Bonjour result for the peer dials immediately anyway.
    private func scheduleRedial(_ peer: PeerID) {
        guard !stopped, endpoints[peer] != nil else { return }
        let attempt = redialAttempts[peer, default: 0]
        redialAttempts[peer] = attempt + 1
        let delay = Double(min(1 << min(attempt, 5), 30))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !stopped, links[peer] == nil, !dialing.contains(peer),
                let endpoint = endpoints[peer]
            else { return }
            dial(endpoint, target: peer)
        }
    }
}
