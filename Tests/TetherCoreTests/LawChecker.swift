// checkLaws: asserts merge is commutative, associative and idempotent on random triples.
// Reused for every CRDT type.

import Testing

@testable import TetherCore

func merged<T: CRDT>(_ a: T, _ b: T) -> T {
    var result = a
    result.merge(b)
    return result
}

func checkLaws<T: CRDT>(
    seed: UInt64, trials: Int = 1000, _ generate: (inout SeededGenerator) -> T,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    var rng = SeededGenerator(seed: seed)
    for trial in 0..<trials {
        let (a, b, c) = (generate(&rng), generate(&rng), generate(&rng))
        let context = "seed \(seed), trial \(trial)"
        guard merged(a, b) == merged(b, a) else {
            Issue.record(
                "not commutative (\(context)): \(a) and \(b)", sourceLocation: sourceLocation)
            return
        }
        guard merged(merged(a, b), c) == merged(a, merged(b, c)) else {
            Issue.record("not associative (\(context))", sourceLocation: sourceLocation)
            return
        }
        guard merged(a, a) == a else {
            Issue.record("not idempotent (\(context)): \(a)", sourceLocation: sourceLocation)
            return
        }
    }
}

/// Keeps whichever side merge was called on, so a ⊔ b ≠ b ⊔ a.
private struct FirstWins: CRDT {
    var value: Int
    mutating func merge(_ other: FirstWins) {}
}

@Suite struct LawCheckerTests {
    @Test func catchesANonCommutativeMerge() {
        withKnownIssue {
            checkLaws(seed: 1) { rng in FirstWins(value: Int.random(in: 0..<5, using: &rng)) }
        }
    }
}
