// Shared test helpers: temp directories, a seeded RNG, and random op histories.

import Foundation
import TetherStorage

/// Runs `body` with a fresh, empty directory and deletes the directory afterwards, even if
/// `body` throws.
///
/// This is closure-based rather than a class that cleans up in `deinit`, because Swift may
/// release an object right after its last use, which could delete the directory while a
/// test still has a database open in it.
func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("TetherTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try await body(url)
}

/// Ops from a few replicas touching a few fields, with small HLCs so ties happen.
func randomHistory(count: Int, using rng: inout SeededGenerator) -> [Op] {
    let replicas = (0..<3).map { _ in ReplicaID.random(using: &rng) }
    let docs = (0..<4).map { _ in DocID.random(using: &rng) }
    var counters = [ReplicaID: UInt64]()
    return (0..<count).map { _ in
        let replica = replicas.randomElement(using: &rng) ?? replicas[0]
        counters[replica, default: 0] += 1
        return Op(
            replicaID: replica, counter: counters[replica, default: 0],
            hlc: UInt64.random(in: 0...50, using: &rng),
            docID: docs.randomElement(using: &rng) ?? docs[0],
            field: ["title", "done", "position"].randomElement(using: &rng) ?? "title",
            kind: 0, body: Data([UInt8.random(in: .min ... .max, using: &rng)]))
    }
}

/// SplitMix64: a tiny deterministic RNG, so a failing seed can be replayed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
