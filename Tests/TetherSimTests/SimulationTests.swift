// Deterministic simulation tests: random edits on 3–5 nodes over 60 s of virtual time, with
// drops, duplicates, reordering and partitions, then quiet until the network is silent.
// TETHER_SIM_SEEDS sets the seed count; a failure prints its seed and the end of its trace.

import Foundation
import Testing

@testable import TetherSim

private let seedCount =
    ProcessInfo.processInfo.environment["TETHER_SIM_SEEDS"].flatMap { Int($0) } ?? 50

@Suite struct SimulationTests {
    @Test(arguments: (0..<UInt64(seedCount)).map { $0 })
    func networkFaultsNeverStopConvergence(seed: UInt64) async throws {
        let report = try await Simulation.run(seed: seed)
        guard let failure = report.failure else { return }
        Issue.record(
            """
            seed \(seed): \(failure)
            \(report.opCount) ops, \(report.messagesSent) messages, \(report.messagesDropped) dropped
            last trace lines:
            \(report.trace.suffix(40).joined(separator: "\n"))
            """)
    }

    /// Regression: with version vectors that record the highest counter seen, this seed
    /// (like every seed tried) diverged for good, because a batch that arrived ahead of a
    /// dropped one made peers skip the dropped ops. See docs/bugs.md.
    @Test func outOfOrderBatchesNeverLoseOps() async throws {
        let report = try await Simulation.run(seed: 0)
        #expect(report.failure == nil, "\(report.failure ?? "")")
        #expect(report.messagesDropped > 0)
    }

    @Test func sameSeedSameRun() async throws {
        let first = try await Simulation.run(seed: 42)
        let second = try await Simulation.run(seed: 42)
        #expect(first.trace.count == second.trace.count)
        #expect(first.traceHash == second.traceHash)
        let other = try await Simulation.run(seed: 43)
        #expect(other.traceHash != first.traceHash)
    }

    @Test func faultsActuallyHappen() async throws {
        let report = try await Simulation.run(seed: 7)
        #expect(report.failure == nil)
        #expect(report.messagesDropped > 0)
        #expect(report.trace.contains { $0.contains(" partition ") })
        #expect(report.trace.contains { $0.contains(" dup ") })
        #expect(report.opCount > 100)
    }
}
