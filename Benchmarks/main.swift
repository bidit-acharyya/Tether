// Storage benchmark: 10,000 op inserts in one transaction on a real file.
// Run in release mode: swift run -c release TetherBenchmarks

import Foundation
import TetherStorage

let count = 10_000
let runs = 5
var timings: [Duration] = []

for _ in 0..<runs {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TetherBench-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appendingPathComponent("bench.sqlite").path
    let db = try await Database.openStore(path: path)
    let replica = try await db.replicaID()
    let ops = (1...count).map { i in
        Op(
            replicaID: replica, counter: UInt64(i), hlc: UInt64(i), docID: .random(),
            field: "title", kind: 0, body: Data(repeating: 0x61, count: 32))
    }
    let elapsed = try await ContinuousClock().measure { try await db.append(ops) }
    timings.append(elapsed)
    await db.close()
}

let sorted = timings.sorted()
let os = ProcessInfo.processInfo.operatingSystemVersionString
print("\(count) inserts in one transaction, \(runs) runs (\(os))")
for timing in timings {
    print("  \(timing.formatted(.units(allowed: [.milliseconds])))")
}
print("median: \(sorted[runs / 2].formatted(.units(allowed: [.milliseconds])))")
