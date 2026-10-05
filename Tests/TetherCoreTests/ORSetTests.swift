// Tests for the OR-Set: merge laws, add-wins scenarios, encoding, and add/remove ops.

import Foundation
import Testing
import TetherStorage

@testable import TetherCore

private let a = ReplicaID(bytes: Data(repeating: 0xA, count: 16))!
private let b = ReplicaID(bytes: Data(repeating: 0xB, count: 16))!

/// One replica's view of a set, issuing add/remove deltas with its own counters.
private struct Node {
    let id: ReplicaID
    var set = ORSet<String>()
    var counter: UInt64 = 0

    @discardableResult
    mutating func add(_ element: String) -> ORSet<String> {
        counter += 1
        let delta = set.addition(of: element, tag: AddTag(replicaID: id, counter: counter))
        set.merge(delta)
        return delta
    }

    @discardableResult
    mutating func remove(_ element: String) -> ORSet<String> {
        let delta = set.removal(of: element)
        set.merge(delta)
        return delta
    }
}

@Suite struct ORSetTests {
    @Test(arguments: 0..<5)
    func mergeObeysTheLaws(seed: UInt64) {
        // A tag always belongs to the same element, as it would in real use.
        let domain = [a, b].flatMap { replica in
            (1...6).map { AddTag(replicaID: replica, counter: $0) }
        }
        checkLaws(seed: seed) { rng in
            var adds: [String: Set<AddTag>] = [:]
            for tag in domain where Bool.random(using: &rng) {
                adds["e\(tag.counter % 3)", default: []].insert(tag)
            }
            let tombstones = Set(domain.filter { _ in Int.random(in: 0..<3, using: &rng) == 0 })
            return ORSet(adds: adds, tombstones: tombstones)
        }
    }

    @Test func concurrentAddAndRemoveKeepsTheElement() {
        var nodeA = Node(id: a)
        var nodeB = Node(id: b)
        nodeB.set.merge(nodeA.add("milk"))

        // B removes milk while A, without seeing that, adds milk again.
        let removal = nodeB.remove("milk")
        let readd = nodeA.add("milk")
        nodeA.set.merge(removal)
        nodeB.set.merge(readd)

        #expect(nodeA.set.contains("milk"))
        #expect(nodeA.set == nodeB.set)
    }

    @Test func removeOfAnUnseenAddDoesNothing() {
        var nodeA = Node(id: a)
        var nodeB = Node(id: b)
        let add = nodeA.add("eggs")
        let removal = nodeB.remove("eggs")  // B never saw the add.
        nodeA.set.merge(removal)
        nodeB.set.merge(add)
        #expect(nodeA.set.contains("eggs"))
        #expect(nodeB.set.contains("eggs"))
    }

    @Test func removeAfterSeeingTheAddDeletes() {
        var nodeA = Node(id: a)
        var nodeB = Node(id: b)
        nodeB.set.merge(nodeA.add("bread"))
        nodeA.set.merge(nodeB.remove("bread"))
        #expect(!nodeA.set.contains("bread"))
        #expect(!nodeB.set.contains("bread"))
        #expect(nodeA.set.elements.isEmpty)
    }

    @Test func addAgainAfterRemoveIsPresent() {
        var node = Node(id: a)
        node.add("tea")
        node.remove("tea")
        #expect(!node.set.contains("tea"))
        node.add("tea")
        #expect(node.set.contains("tea"))
        #expect(node.set.elements == ["tea"])
    }

    @Test func encodingRoundTripsAndIsDeterministic() throws {
        var node = Node(id: a)
        for item in ["x", "y", "z", "🧵"] { node.add(item) }
        node.remove("y")
        let encoded = node.set.encoded()
        #expect(try ORSet<String>(decoding: encoded) == node.set)

        // Built in a different order, same contents: must encode to the same bytes.
        var rebuilt = ORSet<String>(adds: [:], tombstones: [AddTag(replicaID: a, counter: 2)])
        for (counter, item) in [(4, "🧵"), (1, "x"), (3, "z"), (2, "y")] {
            let tag = AddTag(replicaID: a, counter: UInt64(counter))
            rebuilt.merge(rebuilt.addition(of: item, tag: tag))
        }
        #expect(rebuilt == node.set)
        #expect(rebuilt.encoded() == encoded)
    }

    @Test func truncatedEncodingThrows() {
        var node = Node(id: a)
        node.add("x")
        node.remove("x")
        let encoded = node.set.encoded()
        for length in 0..<encoded.count {
            #expect(throws: StorageError.self) {
                try ORSet<String>(decoding: encoded.prefix(length))
            }
        }
    }

    @Test func addAndRemoveOpsConvergeInAnyOrder() throws {
        let doc = DocID.random()
        let hlc = HLCTimestamp(rawValue: 1)
        var local = ORSet<String>()
        let add1 = Op.add(
            "red", to: local, docID: doc, field: "tags", replicaID: a, counter: 1, hlc: hlc)
        local.merge(try ORSet(decoding: add1.body))
        let add2 = Op.add(
            "blue", to: local, docID: doc, field: "tags", replicaID: a, counter: 2, hlc: hlc)
        local.merge(try ORSet(decoding: add2.body))
        let remove = Op.remove(
            "red", from: local, docID: doc, field: "tags", replicaID: a, counter: 3, hlc: hlc)
        #expect(add1.kind == OpKind.add.rawValue)
        #expect(remove.kind == OpKind.remove.rawValue)

        let ops = [add1, add2, remove]
        for order in [[0, 1, 2], [2, 1, 0], [1, 2, 0], [2, 0, 1]] {
            var replica = ORSet<String>()
            for index in order { replica.merge(try ORSet(decoding: ops[index].body)) }
            #expect(replica.elements == ["blue"], "order \(order)")
        }
    }
}
