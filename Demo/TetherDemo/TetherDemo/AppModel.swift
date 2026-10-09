// The demo's view model: opens the replica as this build's app version, runs peer-to-peer
// sync, and reloads only the documents the replica's change stream reports.

import Foundation
import Observation
import SwiftUI
import TetherCore
import TetherStorage
import TetherSync
import TetherTransportP2P

@MainActor
@Observable
final class AppModel {
    struct DebugInfo {
        var replica = ""
        var version: UInt64 = 0
        var vector: [(replica: String, counter: UInt64)] = []
        var peers: [SyncEngine.PeerStatus] = []
        /// Fields this version doesn't know, kept and synced anyway.
        var preserved = 0
        var pending = 0
    }

    /// The same list id as TetherP2PDemo, so the app and the CLI sync with each other.
    static let list = DocID(bytes: Data(repeating: 0x7E, count: 16))!

    /// This build's app version: the -TetherSchemaVersion launch argument, else the
    /// TETHER_SCHEMA_VERSION build setting (via Info.plist), else v1 on Mac and v2 elsewhere.
    static let manifest: SchemaManifest = {
        let argument = UserDefaults.standard.integer(forKey: "TetherSchemaVersion")
        let setting = (Bundle.main.object(forInfoDictionaryKey: "TetherSchemaVersion") as? String)
            .flatMap { Int($0) }
        #if os(macOS)
            let fallback = 1
        #else
            let fallback = 2
        #endif
        let version = argument > 0 ? argument : setting ?? fallback
        return TaskListSchema.versions[min(max(version, 1), TaskListSchema.versions.count) - 1]
    }()

    let manifest = AppModel.manifest
    var showsPriority: Bool { manifest.field(named: "priority", in: "item") != nil }

    private(set) var title = ""
    private(set) var items: [Item] = []
    private(set) var priorities: [DocID: Int64] = [:]
    private(set) var debug = DebugInfo()
    private(set) var failure: String?

    private var itemsByID: [DocID: Item] = [:]
    private var replica: Replica?
    private var engine: SyncEngine?

    func start() async {
        guard replica == nil else { return }
        do {
            let folder = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                create: true)
            let replica = try await Replica.open(
                path: folder.appendingPathComponent("tether.sqlite").path, manifest: manifest)
            if try await replica.database.listTitle(Self.list) == nil {
                try await replica.perform(.createList(Self.list, title: "Shared list"))
            }
            let transport = P2PTransport(replicaID: replica.id)
            try await transport.start()
            let engine = SyncEngine(replica: replica, transport: transport)
            self.replica = replica
            self.engine = engine
            debug.replica = String(transport.peerID.rawValue.prefix(8))
            debug.version = manifest.version

            let changes = await replica.changes()
            try await reloadAll()
            Task { await engine.run() }
            Task {
                for await changed in changes { await reload(changed) }
            }
            Task {
                while !Task.isCancelled {
                    await refreshDebug()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } catch {
            failure = "Couldn't start: \(error)"
        }
    }

    // MARK: Changes

    func add(_ title: String) {
        let position = try? FractionalIndex.between(items.last?.position, nil)
        perform(.addItem(.random(), toList: Self.list, title: title, position: position ?? "V"))
    }

    func toggle(_ item: Item) {
        perform(.setDone(item: item.id, !item.done))
    }

    func rename(_ item: Item, to title: String) {
        guard title != item.title else { return }
        perform(.setTitle(item: item.id, title))
    }

    /// v2 and later.
    func setPriority(_ item: Item, to priority: Int64) {
        priorities[item.id] = priority
        perform(.set(item.id, type: "item", field: "priority", to: priority))
    }

    func toggleTag(_ tag: String, on item: Item) {
        perform(
            item.tags.contains(tag) ? .removeTag(item: item.id, tag) : .addTag(item: item.id, tag))
    }

    func delete(_ item: Item) {
        perform(.deleteItem(item.id, fromList: Self.list))
    }

    func delete(at offsets: IndexSet) {
        for index in offsets { delete(items[index]) }
    }

    /// A drag writes one new position between the item's new neighbours.
    func move(from source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        let moved = items[from]
        var reordered = items
        reordered.move(fromOffsets: source, toOffset: destination)
        guard let index = reordered.firstIndex(where: { $0.id == moved.id }) else { return }
        let lower = index > 0 ? reordered[index - 1].position : nil
        let upper = index + 1 < reordered.count ? reordered[index + 1].position : nil
        // Concurrent inserts can leave equal keys; nothing fits strictly between them.
        guard let position = try? FractionalIndex.between(lower, upper == lower ? nil : upper)
        else { return }
        items = reordered
        perform(.move(item: moved.id, position: position))
    }

    private func perform(_ change: Change) {
        guard let replica else { return }
        Task {
            do {
                try await replica.perform(change)
            } catch {
                failure = "\(error)"
            }
        }
    }

    // MARK: Reloading

    private func reloadAll() async throws {
        guard let db = replica?.database else { return }
        title = try await db.listTitle(Self.list) ?? ""
        itemsByID = Dictionary(
            uniqueKeysWithValues: try await db.items(inList: Self.list).map { ($0.id, $0) })
        for id in itemsByID.keys { priorities[id] = try await priority(of: id) }
        items = Item.sorted(Array(itemsByID.values))
    }

    /// Read through the manifest, so a never-set priority shows its default.
    private func priority(of id: DocID) async throws -> Int64? {
        guard showsPriority, let replica else { return nil }
        return try await replica.read(Int64.self, "priority", of: id, in: "item")
    }

    private func reload(_ changed: Set<DocID>) async {
        guard let db = replica?.database else { return }
        do {
            var ids = changed.subtracting([Self.list])
            if changed.contains(Self.list) {
                title = try await db.listTitle(Self.list) ?? ""
                // Membership may have changed: look at every item that is or was listed.
                let members = try await db.orSet(DocID.self, doc: Self.list, field: Field.items)
                ids.formUnion(members.elements)
                ids.formUnion(itemsByID.keys)
            }
            for id in ids {
                itemsByID[id] = try await db.item(id, inList: Self.list)
                priorities[id] = try await priority(of: id)
            }
            items = Item.sorted(Array(itemsByID.values))
        } catch {
            failure = "\(error)"
        }
    }

    private func refreshDebug() async {
        guard let replica, let engine else { return }
        let vector = (try? await replica.database.versionVector()) ?? [:]
        debug.vector = vector.sorted { $0.key < $1.key }.map {
            (String(P2PTransport.hex($0.key).prefix(8)), $0.value)
        }
        debug.peers = await engine.statuses()
        // Only what's on screen; deleted items keep their fields as tombstones.
        let visible = Set(itemsByID.keys).union([Self.list])
        let state = ((try? await replica.database.stateSnapshot()) ?? [])
            .filter { visible.contains($0.docID) }
        debug.preserved = state.filter { !$0.known }.count
        debug.pending = state.filter(\.pending).count
    }
}
