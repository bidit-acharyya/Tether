// Wall clocks for the HLC: the real one, and a fake that tests can set and jump.

import Foundation

public protocol WallClock: Sendable {
    func nowMillis() -> UInt64
}

public struct SystemClock: WallClock {
    public init() {}

    public func nowMillis() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }
}

public final class FakeClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var millis: UInt64

    public init(millis: UInt64) {
        self.millis = millis
    }

    public func nowMillis() -> UInt64 {
        lock.withLock { millis }
    }

    public func set(_ millis: UInt64) {
        lock.withLock { self.millis = millis }
    }

    public func advance(by delta: Int64) {
        lock.withLock { millis = UInt64(clamping: Int64(clamping: millis) + delta) }
    }
}
