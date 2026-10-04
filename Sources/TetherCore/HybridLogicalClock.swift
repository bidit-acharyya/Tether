// Hybrid logical clock (Kulkarni et al., 2014): 48 bits of wall-clock milliseconds plus a
// 16-bit counter, so timestamps track real time but never go backwards.

import Foundation
import TetherStorage
import os

public struct HLCTimestamp: Comparable, Hashable, Sendable {
    public static let maxMillis: UInt64 = (1 << 48) - 1

    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(millis: UInt64, counter: UInt16) throws {
        guard millis <= Self.maxMillis else { throw ClockError.wallClockOutOfRange }
        rawValue = millis << 16 | UInt64(counter)
    }

    public var millis: UInt64 { rawValue >> 16 }
    public var counter: UInt16 { UInt16(truncatingIfNeeded: rawValue) }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ClockError: Error, Equatable {
    case counterOverflow
    case wallClockOutOfRange
    case remoteTooFarAhead(millis: UInt64)
}

public struct HybridLogicalClock: Sendable {
    public static let maxSkewMillis: UInt64 = 5 * 60 * 1000

    public private(set) var last: HLCTimestamp
    private let wallClock: any WallClock

    public init(wallClock: any WallClock, last: HLCTimestamp = HLCTimestamp(rawValue: 0)) {
        self.wallClock = wallClock
        self.last = last
    }

    /// A timestamp for a local event, greater than every timestamp issued or received so far.
    public mutating func tick() throws -> HLCTimestamp {
        let now = wallClock.nowMillis()
        let next =
            now > last.millis
            ? try HLCTimestamp(millis: now, counter: 0)
            : try bumped(millis: last.millis, counter: last.counter)
        last = next
        return next
    }

    /// Advances past a remote timestamp. Rejects one too far ahead of this device's clock.
    public mutating func receive(_ remote: HLCTimestamp) throws -> HLCTimestamp {
        let now = wallClock.nowMillis()
        guard remote.millis <= now + Self.maxSkewMillis else {
            logger.warning("Rejected HLC \(remote.millis) ms; local wall clock is \(now) ms")
            throw ClockError.remoteTooFarAhead(millis: remote.millis)
        }
        let millis = max(now, last.millis, remote.millis)
        let next: HLCTimestamp
        switch (millis == last.millis, millis == remote.millis) {
        case (true, true):
            next = try bumped(millis: millis, counter: max(last.counter, remote.counter))
        case (true, false):
            next = try bumped(millis: millis, counter: last.counter)
        case (false, true):
            next = try bumped(millis: millis, counter: remote.counter)
        case (false, false):
            next = try HLCTimestamp(millis: millis, counter: 0)
        }
        last = next
        return next
    }

    private func bumped(millis: UInt64, counter: UInt16) throws -> HLCTimestamp {
        guard counter < .max else { throw ClockError.counterOverflow }
        return try HLCTimestamp(millis: millis, counter: counter + 1)
    }
}

// Persistence, so a restart can never issue a timestamp below one already used.
extension Database {
    /// The highest HLC this store has issued or seen: the saved one, or the newest op if higher.
    public func lastHLC() throws -> HLCTimestamp {
        var saved: UInt64 = 0
        if let bytes = try meta(hlcKey), bytes.count == 8 {
            saved = bytes.reduce(0) { $0 << 8 | UInt64($1) }
        }
        let newest = try query("SELECT max(hlc) AS top FROM ops").first?.value("top")
        guard case .int(let top) = newest, let topOp = UInt64(exactly: top) else {
            return HLCTimestamp(rawValue: saved)
        }
        return HLCTimestamp(rawValue: max(saved, topOp))
    }

    public func saveHLC(_ timestamp: HLCTimestamp) throws {
        try setMeta(hlcKey, withUnsafeBytes(of: timestamp.rawValue.bigEndian) { Data($0) })
    }
}

private let hlcKey = "hlc"
private let logger = Logger(subsystem: "Tether", category: "hlc")
