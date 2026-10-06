// RandomUser: picks a random task-list action from what a replica currently sees.

import TetherCore
import TetherStorage

public enum RandomUser {
    public static func change(
        on replica: Replica, list: DocID, rng: inout SeededGenerator
    ) async throws -> Change {
        let db = replica.database
        let ids = try await db.orSet(DocID.self, doc: list, field: Field.items).elements.sorted()
        let roll = ids.isEmpty ? 0 : Int.random(in: 0..<15, using: &rng)
        let item = ids.randomElement(using: &rng) ?? DocID.random(using: &rng)
        let tag = ["home", "work", "urgent"].randomElement(using: &rng) ?? "home"

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

        switch roll {
        case 0..<4:
            let slot = Int.random(in: 0...order.count, using: &rng)
            return .addItem(
                DocID.random(using: &rng), toList: list, title: "item",
                position: try key(at: slot, in: order))
        case 4..<7:
            return .setTitle(item: item, "t\(Int.random(in: 0..<1_000, using: &rng))")
        case 7:
            return .renameList(list, title: "L\(Int.random(in: 0..<1_000, using: &rng))")
        case 8..<10:
            let done =
                try await db.register(Bool.self, doc: item, field: Field.done)?.value ?? false
            return .setDone(item: item, !done)
        case 10..<12:
            let others = order.filter { $0 != item }
            let slot = Int.random(in: 0...others.count, using: &rng)
            return .move(item: item, position: try key(at: slot, in: others))
        case 12:
            return .addTag(item: item, tag)
        case 13:
            return .removeTag(item: item, tag)
        default:
            return .deleteItem(item, fromList: list)
        }
    }
}
