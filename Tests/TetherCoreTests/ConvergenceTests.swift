// Convergence harness: 3–5 replicas make random edits with skewed clocks and partial
// syncs, then each gets every op in its own shuffled order with duplicates. All must end
// byte-identical and match a rebuild of their own log. TETHER_CONVERGENCE_SEEDS sets the
// seed count; a failure prints its seed and a minimized op list.

import Foundation
import Testing
import TetherStorage

@testable import TetherCore

private let start: UInt64 = 1_800_000_000_000
private let list = DocID(bytes: Data(repeating: 0x11, count: 16))!

enum Convergence {
    struct Run {
        var ops: [Op] = []
        var failure: String?
    }

    static func run(seed: UInt64) async throws -> Run {
        var rng = SeededGenerator(seed: seed)
        let count = Int.random(in: 3...5, using: &rng)
        let clocks = (0..<count).map { _ in
            FakeClock(millis: UInt64(Int64(start) + Int64.random(in: -2_000...2_000, using: &rng)))
        }
        var replicas: [Replica] = []
        for clock in clocks {
            let id = ReplicaID.random(using: &rng)
            replicas.append(
                try await Replica.open(path: ":memory:", wallClock: clock, replicaID: id))
        }

        var run = Run()
        run.ops = try await replicas[0].perform(.createList(list, title: "List"))
        for replica in replicas.dropFirst() { try await replica.apply(run.ops) }

        // Generate: replicas take turns acting until each has made its 50–500 ops, with
        // occasional one-way partial syncs.
        var remaining = (0..<count).map { _ in Int.random(in: 50...500, using: &rng) }
        while let index = remaining.indices.filter({ remaining[$0] > 0 }).randomElement(using: &rng)
        {
            clocks[index].advance(by: Int64.random(in: 0...30, using: &rng))
            if Int.random(in: 0..<10, using: &rng) == 0 {
                let source = replicas[(index + Int.random(in: 1..<count, using: &rng)) % count]
                let missing = try await source.database.ops(
                    missingFrom: replicas[index].database.versionVector())
                try await replicas[index].apply(missing)
            }
            let made = try await act(replicas[index], rng: &rng)
            remaining[index] -= made.count
            run.ops += made
        }

        // Deliver: every op to every replica, shuffled, ~10% duplicates, random batch sizes.
        for replica in replicas {
            try await deliver(run.ops, to: replica, rng: &rng)
        }
        run.failure = try await compare(replicas)
        return run
    }

    /// One random user action, chosen from what this replica currently sees.
    static func act(_ replica: Replica, rng: inout SeededGenerator) async throws -> [Op] {
        let db = replica.database
        let ids = try await db.orSet(DocID.self, doc: list, field: Field.items).elements.sorted()
        let roll = ids.isEmpty ? 0 : Int.random(in: 0..<15, using: &rng)
        let item = ids.randomElement(using: &rng) ?? DocID.random(using: &rng)
        let tag = ["home", "work", "urgent"].randomElement(using: &rng) ?? "home"

        // Only creates and moves need the display order.
        var positions: [DocID: String] = [:]
        if roll < 4 || (10..<12).contains(roll) {
            for (doc, value) in try await db.stateValues(field: Field.position) {
                positions[doc] = try LWWRegister<String>(decoding: value).value
            }
        }
        let order = FractionalIndex.sorted(ids.map { ($0, positions[$0] ?? "") })

        func key(at slot: Int, in order: [DocID]) throws -> String {
            let lower = slot > 0 ? positions[order[slot - 1]] : nil
            let upper = slot < order.count ? positions[order[slot]] : nil
            // Concurrent inserts can leave equal keys; nothing fits strictly between them.
            return try FractionalIndex.between(lower, upper == lower ? nil : upper)
        }

        let change: Change
        switch roll {
        case 0..<4:
            let slot = Int.random(in: 0...order.count, using: &rng)
            change = .addItem(
                DocID.random(using: &rng), toList: list, title: "item",
                position: try key(at: slot, in: order))
        case 4..<7:
            change = .setTitle(item: item, "t\(Int.random(in: 0..<1_000, using: &rng))")
        case 7:
            change = .renameList(list, title: "L\(Int.random(in: 0..<1_000, using: &rng))")
        case 8..<10:
            let done =
                try await db.register(Bool.self, doc: item, field: Field.done)?.value ?? false
            change = .setDone(item: item, !done)
        case 10..<12:
            let others = order.filter { $0 != item }
            let slot = Int.random(in: 0...others.count, using: &rng)
            change = .move(item: item, position: try key(at: slot, in: others))
        case 12:
            change = .addTag(item: item, tag)
        case 13:
            change = .removeTag(item: item, tag)
        default:
            change = .deleteItem(item, fromList: list)
        }
        return try await replica.perform(change)
    }

    static func deliver(_ ops: [Op], to replica: Replica, rng: inout SeededGenerator) async throws {
        var delivery = ops.shuffled(using: &rng)
        for _ in 0..<(ops.count / 10) {
            guard let duplicate = ops.randomElement(using: &rng) else { break }
            delivery.insert(duplicate, at: Int.random(in: 0...delivery.count, using: &rng))
        }
        var index = 0
        while index < delivery.count {
            let end = min(index + Int.random(in: 1...20, using: &rng), delivery.count)
            try await replica.apply(Array(delivery[index..<end]))
            index = end
        }
    }

    /// nil if every replica has identical state and passes verify(), else what went wrong.
    static func compare(_ replicas: [Replica]) async throws -> String? {
        let reference = try await replicas[0].database.stateSnapshot()
        let referenceVector = try await replicas[0].database.versionVector()
        for (index, replica) in replicas.enumerated() {
            if try await replica.database.stateSnapshot() != reference {
                return "replica \(index) state differs from replica 0"
            }
            if try await replica.database.versionVector() != referenceVector {
                return "replica \(index) version vector differs from replica 0"
            }
            do {
                try await replica.database.verify()
            } catch {
                return "replica \(index) fails verify(): \(error)"
            }
        }
        return nil
    }

    /// Whether `ops`, delivered to fresh replicas in several orders, still fails to converge.
    static func reproduces(_ ops: [Op], seed: UInt64) async -> Bool {
        var rng = SeededGenerator(seed: seed ^ 0x5EED)
        do {
            var replicas: [Replica] = []
            for byte: UInt8 in [0xF1, 0xF2, 0xF3] {
                let id = ReplicaID(bytes: Data(repeating: byte, count: 16))
                let replica = try await Replica.open(
                    path: ":memory:", wallClock: FakeClock(millis: start), replicaID: id)
                try await deliver(ops, to: replica, rng: &rng)
                replicas.append(replica)
            }
            return try await compare(replicas) != nil
        } catch {
            return true
        }
    }

    /// Repeatedly drops chunks of ops while the failure still reproduces.
    static func minimize(_ ops: [Op], seed: UInt64) async -> [Op] {
        var current = ops
        var chunk = max(current.count / 2, 1)
        while chunk >= 1 {
            var index = 0
            var shrank = false
            while index < current.count {
                let candidate = Array(
                    current[..<index] + current[min(index + chunk, current.count)...])
                if await reproduces(candidate, seed: seed) {
                    current = candidate
                    shrank = true
                } else {
                    index += chunk
                }
            }
            if !shrank { chunk /= 2 }
        }
        return current
    }

    static func describe(_ ops: [Op]) -> String {
        ops.map { op in
            let replica = op.replicaID.bytes.prefix(2).map { String(format: "%02x", $0) }.joined()
            let doc = op.docID.bytes.prefix(2).map { String(format: "%02x", $0) }.joined()
            return "  \(replica)#\(op.counter) hlc=\(op.hlc) doc=\(doc) \(op.field) kind=\(op.kind)"
        }.joined(separator: "\n")
    }
}

private let seedCount =
    ProcessInfo.processInfo.environment["TETHER_CONVERGENCE_SEEDS"].flatMap { Int($0) } ?? 100

@Suite struct ConvergenceTests {
    @Test(arguments: (0..<UInt64(seedCount)).map { $0 })
    func replicasConverge(seed: UInt64) async throws {
        let run = try await Convergence.run(seed: seed)
        guard let failure = run.failure else { return }
        let minimal =
            await Convergence.reproduces(run.ops, seed: seed)
            ? await Convergence.minimize(run.ops, seed: seed) : run.ops
        Issue.record(
            """
            seed \(seed), \(run.ops.count) ops: \(failure)
            minimized to \(minimal.count) ops:
            \(Convergence.describe(minimal))
            """)
    }
}
