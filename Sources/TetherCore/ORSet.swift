// Observed-remove set (add-wins): every add gets a unique tag, and a remove tombstones
// only the tags it has seen, so an add concurrent with a remove survives.

import Foundation
import TetherStorage

/// Names one add: the replica and op counter that created it.
public struct AddTag: Hashable, Comparable, Sendable {
    public let replicaID: ReplicaID
    public let counter: UInt64

    public init(replicaID: ReplicaID, counter: UInt64) {
        self.replicaID = replicaID
        self.counter = counter
    }

    public static func < (lhs: AddTag, rhs: AddTag) -> Bool {
        lhs.replicaID != rhs.replicaID ? lhs.replicaID < rhs.replicaID : lhs.counter < rhs.counter
    }
}

public struct ORSet<Element: SetElement>: CRDT {
    public private(set) var adds: [Element: Set<AddTag>] = [:]
    public private(set) var tombstones: Set<AddTag> = []

    public init() {}

    init(adds: [Element: Set<AddTag>], tombstones: Set<AddTag>) {
        self.adds = adds
        self.tombstones = tombstones
    }

    public var elements: Set<Element> {
        Set(adds.compactMap { element, tags in tags.isSubset(of: tombstones) ? nil : element })
    }

    public func contains(_ element: Element) -> Bool {
        adds[element].map { !$0.isSubset(of: tombstones) } ?? false
    }

    public mutating func merge(_ other: ORSet) {
        adds.merge(other.adds) { $0.union($1) }
        tombstones.formUnion(other.tombstones)
    }

    /// The delta for adding `element` under a fresh `tag`.
    public func addition(of element: Element, tag: AddTag) -> ORSet {
        var delta = ORSet()
        delta.adds[element] = [tag]
        return delta
    }

    /// The delta for removing `element`: tombstones for exactly the tags seen so far.
    public func removal(of element: Element) -> ORSet {
        var delta = ORSet()
        delta.tombstones = adds[element] ?? []
        return delta
    }
}

// Layout: element count, then each element and its tags, then the tombstones.
// Elements and tags are sorted so equal sets always encode to identical bytes.
extension ORSet {
    public func encoded() -> Data {
        let entries = adds.map { element, tags in
            var writer = ByteWriter()
            element.write(to: &writer)
            return (element: writer.data, tags: tags)
        }.sorted { bytesPrecede($0.element, $1.element) }

        var writer = ByteWriter()
        writer.writeVarint(UInt64(entries.count))
        for entry in entries {
            writer.writeFixed(entry.element)
            writeTags(entry.tags, to: &writer)
        }
        writeTags(tombstones, to: &writer)
        return writer.data
    }

    public init(decoding data: Data) throws {
        var reader = ByteReader(data)
        self.init()
        for _ in 0..<(try reader.readVarint()) {
            let element = try Element.read(from: &reader)
            adds[element, default: []].formUnion(try readTags(from: &reader))
        }
        tombstones = try readTags(from: &reader)
        guard reader.isAtEnd else { throw StorageError.invalidEncoding("trailing bytes") }
    }
}

/// Byte-wise order via memcmp; much faster than iterating Data.
private func bytesPrecede(_ lhs: Data, _ rhs: Data) -> Bool {
    lhs.withUnsafeBytes { left in
        rhs.withUnsafeBytes { right in
            let shared = min(left.count, right.count)
            if shared > 0, let l = left.baseAddress, let r = right.baseAddress {
                let order = memcmp(l, r, shared)
                if order != 0 { return order < 0 }
            }
            return left.count < right.count
        }
    }
}

private func writeTags(_ tags: Set<AddTag>, to writer: inout ByteWriter) {
    writer.writeVarint(UInt64(tags.count))
    for tag in tags.sorted() {
        writer.writeFixed(tag.replicaID.bytes)
        writer.writeVarint(tag.counter)
    }
}

private func readTags(from reader: inout ByteReader) throws -> Set<AddTag> {
    var tags: Set<AddTag> = []
    for _ in 0..<(try reader.readVarint()) {
        guard let replicaID = ReplicaID(bytes: try reader.readFixed(16)) else {
            throw StorageError.truncated
        }
        tags.insert(AddTag(replicaID: replicaID, counter: try reader.readVarint()))
    }
    return tags
}

// Storage layout: each element lives in its own sub-field, `field/<hex of element>`.
// Every add and remove names one element, so an op rewrites one small row, not the set.
extension ORSet {
    public static func subfield(_ field: String, for element: Element) -> String {
        var writer = ByteWriter()
        element.write(to: &writer)
        let hex = writer.data.flatMap { byte in
            [hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0xF)]]
        }
        return field + "/" + String(decoding: hex, as: UTF8.self)
    }

    /// The sub-field prefix shared by every element of `field`.
    public static func subfieldPrefix(_ field: String) -> String {
        field + "/"
    }
}

private let hexDigits = Array("0123456789abcdef".utf8)

extension Op {
    /// An `add` op; its tag is the op's own (replica, counter), so it is unique.
    public static func add<Element>(
        _ element: Element, to set: ORSet<Element>, docID: DocID, field: String,
        replicaID: ReplicaID, counter: UInt64, hlc: HLCTimestamp
    ) -> Op {
        let delta = set.addition(of: element, tag: AddTag(replicaID: replicaID, counter: counter))
        return Op(
            replicaID: replicaID, counter: counter, hlc: hlc.rawValue, docID: docID,
            field: ORSet.subfield(field, for: element), kind: OpKind.add.rawValue,
            body: delta.encoded())
    }

    /// A `remove` op tombstoning the tags `set` has observed for `element`.
    public static func remove<Element>(
        _ element: Element, from set: ORSet<Element>, docID: DocID, field: String,
        replicaID: ReplicaID, counter: UInt64, hlc: HLCTimestamp
    ) -> Op {
        Op(
            replicaID: replicaID, counter: counter, hlc: hlc.rawValue, docID: docID,
            field: ORSet.subfield(field, for: element), kind: OpKind.remove.rawValue,
            body: set.removal(of: element).encoded())
    }
}
