import Foundation

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
