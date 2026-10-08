// Debug overlay for the demo video: this replica and app version, its version vector, what
// it is preserving for newer versions, and each peer.

import SwiftUI
import TetherSync

struct DebugOverlay: View {
    let info: AppModel.DebugInfo
    let itemCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("replica \(info.replica) · v\(info.version) · \(itemCount) items")
                .bold()
            Text(vectorText)
            if info.preserved > 0 {
                Text(
                    "\(info.preserved) fields from a newer version, preserved"
                        + (info.pending > 0 ? " (\(info.pending) pending)" : ""))
            }
            if info.peers.isEmpty {
                Text("no peers connected")
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
