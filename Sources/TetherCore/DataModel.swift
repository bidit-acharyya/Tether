// The task-list data model (see docs/data-model.md): user changes, how they become ops,
// and typed reads of the merged state.

import Foundation
import TetherStorage

public enum Field {
    public static let title = "title"
    public static let items = "items"
    public static let done = "done"
    public static let position = "position"
    public static let deleted = "deleted"
    public static let tags = "tags"
    public static let priority = "priority"
    public static let views = "views"
}

/// One user action. Positions come from FractionalIndex.
public enum Change: Sendable {
    case createList(DocID, title: String)
    case renameList(DocID, title: String)
    case addItem(DocID, toList: DocID, title: String, position: String)
    case setTitle(item: DocID, String)
    case setDone(item: DocID, Bool)
    case move(item: DocID, position: String)
    case deleteItem(DocID, fromList: DocID)
    case addTag(item: DocID, String)
    case removeTag(item: DocID, String)
    /// v2 and later.
    case setPriority(item: DocID, Int64)
    /// v3 and later.
    case incrementViews(item: DocID, by: Int64)
}

public struct Item: Sendable, Equatable, Identifiable {
    public let id: DocID
    public let title: String
    public let done: Bool
    public let position: String
    public let tags: Set<String>
}

/// Builds the ops for one change, each with its own counter and HLC tick.
struct OpWriter {
    let replica: ReplicaID
    let schemaVersion: UInt64
    var clock: HybridLogicalClock
    var counter: UInt64
    private(set) var ops: [Op] = []

    init(replica: ReplicaID, schemaVersion: UInt64, clock: HybridLogicalClock, counter: UInt64) {
        self.replica = replica
        self.schemaVersion = schemaVersion
        self.clock = clock
        self.counter = counter
    }

    mutating func set<Value: FieldValue>(_ value: Value, doc: DocID, field: String) throws {
        let register = LWWRegister(
            value: value, stamp: Stamp(hlc: try clock.tick(), replicaID: replica))
        append(.set(register, docID: doc, field: field, counter: counter))
    }

    mutating func add<E: SetElement>(_ element: E, to set: ORSet<E>, doc: DocID, field: String)
        throws
    {
        append(
            .add(
                element, to: set, docID: doc, field: field, replicaID: replica, counter: counter,
                hlc: try clock.tick()))
    }

    mutating func remove<E: SetElement>(
        _ element: E, from set: ORSet<E>, doc: DocID, field: String
    ) throws {
        append(
            .remove(
                element, from: set, docID: doc, field: field, replicaID: replica,
                counter: counter, hlc: try clock.tick()))
    }

    mutating func increment(_ amount: Int64, of current: PNCounter, doc: DocID, field: String)
        throws
    {
        append(
            .increment(
                amount, of: current, docID: doc, field: field, replicaID: replica,
                opCounter: counter, hlc: try clock.tick()))
    }

    private mutating func append(_ op: Op) {
        var stamped = op
        stamped.schemaVersion = schemaVersion
        ops.append(stamped)
        counter += 1
    }
}

extension Database {
    func write(_ change: Change, into writer: inout OpWriter) throws {
        switch change {
        case .createList(let list, let title), .renameList(let list, let title):
            try writer.set(title, doc: list, field: Field.title)
        case .addItem(let item, let list, let title, let position):
            try writer.set(title, doc: item, field: Field.title)
            try writer.set(false, doc: item, field: Field.done)
            try writer.set(position, doc: item, field: Field.position)
            try writer.add(item, to: ORSet(), doc: list, field: Field.items)
        case .setTitle(let item, let title):
            try writer.set(title, doc: item, field: Field.title)
        case .setDone(let item, let done):
            try writer.set(done, doc: item, field: Field.done)
        case .move(let item, let position):
            try writer.set(position, doc: item, field: Field.position)
        case .deleteItem(let item, let list):
            // Both halves: off the list, and a flag so a late edit can't bring it back.
            try writer.set(true, doc: item, field: Field.deleted)
            let slice = try orSet(item, doc: list, field: Field.items)
            try writer.remove(item, from: slice, doc: list, field: Field.items)
        case .addTag(let item, let tag):
            try writer.add(tag, to: ORSet(), doc: item, field: Field.tags)
        case .removeTag(let item, let tag):
            let slice = try orSet(tag, doc: item, field: Field.tags)
            try writer.remove(tag, from: slice, doc: item, field: Field.tags)
        case .setPriority(let item, let priority):
            try writer.set(priority, doc: item, field: Field.priority)
        case .incrementViews(let item, let amount):
            let current = try counter(doc: item, field: Field.views) ?? PNCounter()
            try writer.increment(amount, of: current, doc: item, field: Field.views)
        }
    }

    /// A counter field, or nil if it was never written or is still pending.
    public func counter(doc: DocID, field: String) throws -> PNCounter? {
        guard try !isPending(docID: doc, field: field) else { return nil }
        return try stateValue(docID: doc, field: field).map { try PNCounter(decoding: $0) }
    }

    public func register<Value: FieldValue>(_: Value.Type, doc: DocID, field: String) throws
        -> LWWRegister<Value>?
    {
        try stateValue(docID: doc, field: field).map { try LWWRegister<Value>(decoding: $0) }
    }

    /// The whole set, gathered from its per-element sub-fields.
    public func orSet<E: SetElement>(_: E.Type, doc: DocID, field: String) throws -> ORSet<E> {
        var set = ORSet<E>()
        for value in try stateValues(docID: doc, fieldPrefix: ORSet<E>.subfieldPrefix(field)) {
            set.merge(try ORSet<E>(decoding: value))
        }
        return set
    }

    /// Just one element's slice of the set: enough to build a remove op for it.
    func orSet<E: SetElement>(_ element: E, doc: DocID, field: String) throws -> ORSet<E> {
        try stateValue(docID: doc, field: ORSet.subfield(field, for: element))
            .map { try ORSet<E>(decoding: $0) } ?? ORSet()
    }

    public func listTitle(_ list: DocID) throws -> String? {
        try register(String.self, doc: list, field: Field.title)?.value
    }

    /// The visible items of a list, in display order.
    public func items(inList list: DocID) throws -> [Item] {
        let ids = try orSet(DocID.self, doc: list, field: Field.items).elements
        return Item.sorted(try ids.compactMap(visibleItem))
    }

    /// One item if it is on `list` and not deleted, else nil. Lets a view reload just the
    /// documents a change touched.
    public func item(_ id: DocID, inList list: DocID) throws -> Item? {
        guard try orSet(id, doc: list, field: Field.items).contains(id) else { return nil }
        return try visibleItem(id)
    }

    private func visibleItem(_ id: DocID) throws -> Item? {
        guard try register(Bool.self, doc: id, field: Field.deleted)?.value != true else {
            return nil
        }
        return Item(
            id: id, title: try register(String.self, doc: id, field: Field.title)?.value ?? "",
            done: try register(Bool.self, doc: id, field: Field.done)?.value ?? false,
            position: try register(String.self, doc: id, field: Field.position)?.value ?? "",
            tags: try orSet(String.self, doc: id, field: Field.tags).elements)
    }
}

extension Item {
    /// Display order: by position, ties (keys made concurrently) broken by id.
    public static func sorted(_ items: [Item]) -> [Item] {
        items.sorted { $0.position != $1.position ? $0.position < $1.position : $0.id < $1.id }
    }
}
