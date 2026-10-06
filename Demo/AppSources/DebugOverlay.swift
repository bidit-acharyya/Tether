// Debug overlay for the demo video: this replica, its version vector, and each peer.

import SwiftUI

struct DebugOverlay: View {
    let info: AppModel.DebugInfo
    let itemCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("replica \(info.replica) · \(itemCount) items")
                .bold()
            Text(vectorText)
            if info.peers.isEmpty {
                Text("no peers yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(info.peers, id: \.peer) { status in
                Text(
                    "peer \(status.peer.rawValue.prefix(8)) · \(String(describing: status.phase)) · \(status.unackedBatches) unacked"
                )
            }
        }
        .font(.caption.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.thinMaterial, in: .rect(cornerRadius: 10))
        .padding(.horizontal)
    }

    private var vectorText: String {
        let entries = info.vector.map { "\($0.replica):\($0.counter)" }
        return "vector [" + entries.joined(separator: " ") + "]"
    }
}
