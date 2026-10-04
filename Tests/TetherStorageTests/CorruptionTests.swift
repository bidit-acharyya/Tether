// Corruption test: overwrite random bytes near the end of a closed store, then reopen.
// The engine must either refuse with a StorageError or serve exactly the original data.

import Foundation
import Testing

@testable import TetherStorage

@Suite struct CorruptionTests {
    @Test func flippedBytesAreDetectedOrHarmless() async throws {
        try await withTemporaryDirectory { directory in
            var rng = SeededGenerator(seed: 2026)
            let original = directory.appendingPathComponent("original.sqlite")
            let db = try await Database.openStore(path: original.path)
            try await db.append(randomHistory(count: 500, using: &rng))
            let expectedState = try await db.stateSnapshot()
            let expectedOps = try await db.ops(missingFrom: [:])
            await db.close()

            let size = try #require(
                try FileManager.default.attributesOfItem(atPath: original.path)[.size] as? Int)
            let trials = 200
            var detected = 0
            for trial in 0..<trials {
                let copy = directory.appendingPathComponent("copy-\(trial).sqlite")
                try FileManager.default.copyItem(at: original, to: copy)
                defer { try? FileManager.default.removeItem(at: copy) }

                // Overwrite 1–16 random bytes somewhere in the last quarter of the file.
                let offset = Int.random(in: (size * 3 / 4)..<(size - 16), using: &rng)
                let garbage = (0..<Int.random(in: 1...16, using: &rng)).map { _ in
                    UInt8.random(in: .min ... .max, using: &rng)
                }
                let handle = try FileHandle(forUpdating: copy)
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: Data(garbage))
                try handle.close()

                do {
                    let damaged = try await Database.openStore(path: copy.path)
                    try await damaged.verify()
                    let context = "trial \(trial), offset \(offset)"
                    #expect(try await damaged.stateSnapshot() == expectedState, "\(context)")
                    #expect(try await damaged.ops(missingFrom: [:]) == expectedOps, "\(context)")
                    await damaged.close()
                } catch is StorageError {
                    detected += 1
                }
            }
            print("corruption: \(detected)/\(trials) detected; the rest changed no live data")
            #expect(detected > 0)
        }
    }

    @Test func checksumMismatchIsReportedAsCorrupt() async throws {
        var rng = SeededGenerator(seed: 5)
        let db = try await Database.openStore(path: ":memory:")
        try await db.append(randomHistory(count: 10, using: &rng))
        try await db.execute("UPDATE ops SET crc32 = crc32 + 1 WHERE rowid = 1")
        await #expect(throws: StorageError.corrupt("op checksum mismatch")) {
            try await db.rebuildState()
        }
    }

    @Test func tamperedIndexColumnIsReportedAsCorrupt() async throws {
        var rng = SeededGenerator(seed: 6)
        let db = try await Database.openStore(path: ":memory:")
        try await db.append(randomHistory(count: 10, using: &rng))
        try await db.execute("UPDATE ops SET hlc = hlc + 1000 WHERE rowid = 1")
        await #expect(throws: StorageError.corrupt("op columns don't match payload")) {
            try await db.verify()
        }
    }

    @Test func editedStateIsReportedAsCorrupt() async throws {
        var rng = SeededGenerator(seed: 7)
        let db = try await Database.openStore(path: ":memory:")
        try await db.append(randomHistory(count: 10, using: &rng))
        try await db.execute("UPDATE state SET value = x'00ff' WHERE rowid = 1")
        await #expect(throws: StorageError.corrupt("state doesn't match op log")) {
            try await db.verify()
        }
    }

    @Test func healthyStoreVerifies() async throws {
        var rng = SeededGenerator(seed: 8)
        let db = try await Database.openStore(path: ":memory:")
        try await db.append(randomHistory(count: 100, using: &rng))
        try await db.verify()
        #expect(try await db.stateSnapshot().isEmpty == false)
    }
}
