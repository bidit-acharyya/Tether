# Tether

A Swift package that stores app data locally on raw SQLite, lets iPhone and Mac edit offline, and merges every change deterministically when they reconnect, even when the devices run different versions of the app.

## Why not just use Core Data + CloudKit?

Core Data migrations upgrade one device at a time and assume everything moves to the new model together. CloudKit only lets you add to a schema once it's live, and older app versions just don't see the new fields. Neither one really handles two devices on different app versions editing the same data.

In Tether, every change is a small op that says how to merge itself, so an older version can still store and sync fields it doesn't understand. Renames and defaults happen at read time, so stored data never gets rewritten.

If your app only ever runs one version, or you want Apple to run the sync server, Core Data + CloudKit is still the easier choice.

## Requirements

- Swift 6.1 (Xcode 16.3), Swift 6 language mode, zero warnings
- iOS 17, macOS 14, watchOS 10
- System SQLite, tested against 3.54.0 (macOS 27)

## Benchmarks

| Measurement | Result | Run |
|---|---|---|
| 10,000 op inserts, one transaction, `synchronous=FULL` | 40 ms median of 5 | MacBook Air, macOS 27.0.1, `swift run -c release TetherBenchmarks` |

## Testing

| Test | What it proves | Result |
|---|---|---|
| Convergence harness (`ConvergenceTests`) | 3–5 replicas, 50–500 ops each, ±2 s clock skew, partial syncs, every op delivered in a different order with ~10% duplicates: all replicas end byte-identical and match a rebuild of their own log | 10,000 seeds green in 12.3 min (release) |
| Network simulation (`SimulationTests`) | 3–5 nodes running the real sync protocol over 60 s of virtual time with 5–20% drops, duplicates, reordering and partitions, then quiet until the network is silent: identical state, equal version vectors, no deleted item reappears, nothing left unacked. Same seed, same trace | 1,000 seeds green in 62 s (release) |
| Merge laws (`checkLaws`) | Commutative, associative, idempotent for every CRDT, 1,000 random triples per seed | Green |
| Kill -9 (`CrashTests`) | A writer killed mid-transaction never loses a committed op or leaves a partial batch | 200 iterations green |
| Corruption (`CorruptionTests`) | Damaged files are refused or serve exactly the original data | 165/200 random overwrites detected, the rest harmless |

**Mutation checks.** Making LWW keep the last-applied op made every convergence seed fail, and the minimizer cut the failure to 2 ops. Making the OR-Set remove-wins failed 3 scenario tests but *not* convergence: it is wrong but still deterministic. Convergence tests show replicas agree; scenario tests show they agree on the right answer.

Run more seeds with `TETHER_CONVERGENCE_SEEDS=10000 swift test -c release -Xswiftc -enable-testing --filter ConvergenceTests` (default 100). Replay a crash run with `TETHER_CRASH_SEED`.
