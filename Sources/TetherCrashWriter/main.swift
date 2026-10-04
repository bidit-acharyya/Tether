// Test helper for the kill -9 test: appends ops to the store at argv[1] until killed,
// printing the last counter of each batch after its transaction commits.

import Foundation
import TetherStorage

let batchSize: UInt64 = 4

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: TetherCrashWriter <db-path>\n".utf8))
    exit(2)
}

let db = try await Database.openStore(path: CommandLine.arguments[1])
let replica = try await db.replicaID()
let docs = (0..<8).map { _ in DocID.random() }
var next = try await db.nextCounter()

while true {
    let batch = (next..<next + batchSize).map { counter in
        Op(
            replicaID: replica, counter: counter, hlc: counter,
            docID: docs[Int(counter % UInt64(docs.count))],
            field: counter % 2 == 0 ? "title" : "done", kind: 0,
            body: Data(repeating: UInt8(truncatingIfNeeded: counter), count: 64))
    }
    try await db.append(batch)
    next += batchSize
    // Unbuffered write, so the parent sees the counter the moment the commit returns.
    FileHandle.standardOutput.write(Data("\(next - 1)\n".utf8))
}
