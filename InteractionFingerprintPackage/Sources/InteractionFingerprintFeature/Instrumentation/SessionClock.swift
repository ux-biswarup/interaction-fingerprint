import Foundation

/// The single clock everything in a session is stamped from.
///
/// `ProcessInfo.systemUptime` shares its time base with `ARFrame.timestamp` and
/// `CACurrentMediaTime()`, so a tap and a gaze sample recorded microseconds apart really
/// are microseconds apart. `Date()` cannot be used for ordering: it jumps when the system
/// clock is corrected, and a single NTP adjustment mid-session would silently reorder
/// events and destroy every dwell measurement in that recording.
public enum SessionClock {
    /// Seconds on the device monotonic clock.
    public static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Captured once per session so the monotonic clock can be converted to wall time
    /// during analysis without ever being used for ordering.
    public struct Anchor: Codable, Sendable, Equatable {
        public let uptime: TimeInterval
        public let wallClock: Date

        public init(uptime: TimeInterval = SessionClock.now, wallClock: Date = Date()) {
            self.uptime = uptime
            self.wallClock = wallClock
        }

        public func wallClock(forUptime uptime: TimeInterval) -> Date {
            wallClock.addingTimeInterval(uptime - self.uptime)
        }
    }
}
