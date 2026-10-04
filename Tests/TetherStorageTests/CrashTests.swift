// Kill -9 test: SIGKILL the TetherCrashWriter mid-write, then check the store is intact.
// TETHER_CRASH_ITERATIONS sets the iteration count; TETHER_CRASH_SEED replays a failing run.

import Foundation
import Testing

@testable import TetherStorage

private final class BundleMarker {}

private let batchSize: Int64 = 4

/// The writer is built next to the test bundle, in both SwiftPM and Xcode builds.
private func crashWriterURL() throws -> URL {
    let url = Bundle(for: BundleMarker.self).bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("TetherCrashWriter")
    try #require(
        FileManager.default.isExecutableFile(atPath: url.path), "writer not found at \(url.path)")
    return url
}

/// Runs the writer, kills it after `delay`, and returns the last counter it reported.
private func runAndKill(writer: URL, path: String, delay: Duration) async throws -> Int64 {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = writer
    process.arguments = [path]
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()

    try await Task.sleep(for: delay)
    kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()

    let errors = try readAll(stderr)
    try #require(process.terminationReason == .uncaughtSignal, "writer exited early: \(errors)")
    return try readAll(stdout).split(separator: "\n").compactMap { Int64($0) }.last ?? 0
}

private func readAll(_ pipe: Pipe) throws -> String {
    String(decoding: try pipe.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
}

@Suite(.serialized) struct CrashTests {
    @Test func survivesKill9() async throws {
        let environment = ProcessInfo.processInfo.environment
        let iterations = environment["TETHER_CRASH_ITERATIONS"].flatMap { Int($0) } ?? 50
        let seed =
            environment["TETHER_CRASH_SEED"].flatMap { UInt64($0) } ?? .random(in: .min ... .max)
        print("kill -9 test: \(iterations) iterations, TETHER_CRASH_SEED=\(seed)")

        var rng = SeededGenerator(seed: seed)
        let writer = try crashWriterURL()

        for iteration in 0..<iterations {
            let context = "seed \(seed), iteration \(iteration)"
            let delays = (0..<2).map { _ in Int.random(in: 5...200, using: &rng) }
            try await withTemporaryDirectory { directory in
                let path = directory.appendingPathComponent("crash.sqlite").path
                var reported: Int64 = 0
                // Two runs on the same file, so the second one starts from a crashed store.
                for delay in delays {
                    let last = try await runAndKill(
                        writer: writer, path: path, delay: .milliseconds(delay))
                    reported = max(reported, last)
                }

                let db = try await Database.openStore(path: path)
                let integrity = try await db.query("PRAGMA integrity_check").first
                #expect(try integrity?.text("integrity_check") == "ok", "\(context)")

                // Every reported op is present, counters have no gaps, and no batch is partial.
                let counters = try await db.query("SELECT counter FROM ops ORDER BY counter")
                    .map { try $0.int("counter") }
                let stored = Int64(counters.count)
                #expect(counters == Array(stride(from: 1, through: stored, by: 1)), "\(context)")
                #expect(stored >= reported, "lost committed ops: \(context)")
                #expect(stored % batchSize == 0, "partial batch: \(context)")

                let live = try await db.stateSnapshot()
                try await db.rebuildState()
                #expect(try await db.stateSnapshot() == live, "\(context)")
                await db.close()
            }
        }
    }
}
