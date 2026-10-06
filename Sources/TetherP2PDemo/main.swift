// Peer-to-peer smoke test: run two copies (one Mac, or two Macs on the same Wi-Fi) and watch
// them find each other over Bonjour and sync one shared list.
// Usage: swift run TetherP2PDemo <db-path>
// Commands: add <title> | done <n> | rename <n> <title> | del <n> | list | peers | quit

import Foundation
import TetherCore
import TetherStorage
import TetherSync
import TetherTransportP2P

let list = DocID(bytes: Data(repeating: 0x7E, count: 16))!

guard CommandLine.arguments.count == 2 else {
    print("usage: TetherP2PDemo <db-path>")
    exit(2)
}

let replica = try await Replica.open(path: CommandLine.arguments[1])
let transport = P2PTransport(replicaID: replica.id)
let port = try await transport.start()
let engine = SyncEngine(replica: replica, transport: transport)
let me = transport.peerID.rawValue.prefix(8)
print("replica \(me) on port \(port), browsing \(P2PTransport.serviceType)")

if try await replica.database.listTitle(list) == nil {
    try await replica.perform(.createList(list, title: "Shared list"))
}

func printList() async throws {
    let items = try await replica.database.items(inList: list)
    print("— \(try await replica.database.listTitle(list) ?? "") (\(items.count)) —")
    for (index, item) in items.enumerated() {
        print("\(index + 1). [\(item.done ? "x" : " ")] \(item.title)")
    }
}

Task { await engine.run() }
Task {
    for await _ in await replica.changes() { try? await printList() }
}

for try await line in FileHandle.standardInput.bytes.lines {
    let words = line.split(separator: " ", maxSplits: 2).map(String.init)
    guard let command = words.first else { continue }
    let items = try await replica.database.items(inList: list)
    let index = words.count > 1 ? Int(words[1]).map { $0 - 1 } : nil
    let item = index.flatMap { items.indices.contains($0) ? items[$0] : nil }
    switch (command, item) {
    case ("add", _):
        let title = words.dropFirst().joined(separator: " ")
        let position = try FractionalIndex.between(items.last?.position, nil)
        try await replica.perform(
            .addItem(.random(), toList: list, title: title, position: position))
    case ("done", let item?):
        try await replica.perform(.setDone(item: item.id, !item.done))
    case ("rename", let item?) where words.count == 3:
        try await replica.perform(.setTitle(item: item.id, words[2]))
    case ("del", let item?):
        try await replica.perform(.deleteItem(item.id, fromList: list))
    case ("list", _):
        try await printList()
    case ("peers", _):
        for status in await engine.statuses() {
            print(
                "\(status.peer.rawValue.prefix(8)) \(status.phase) unacked=\(status.unackedBatches)"
            )
        }
    case ("quit", _):
        transport.stop()
        exit(0)
    default:
        print(
            "commands: add <title> | done <n> | rename <n> <title> | del <n> | list | peers | quit")
    }
}
