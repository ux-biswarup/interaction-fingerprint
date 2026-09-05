import CoreMotion
import Foundation
import Observation

/// Watches the gyroscope and accelerometer so the tracker knows when the phone itself is
/// moving.
///
/// This matters for two separate reasons.
///
/// For data quality: while the device is being moved, ARKit's face anchor and its camera
/// transform are momentarily out of step, because both are estimates arriving with
/// slightly different latency. Gaze computed from a mismatched pair swings wildly. It
/// looks like the tracker has lost the eyes when in fact the geometry was stale. Frames
/// captured during rapid movement are marked rather than trusted.
///
/// As a research signal: how steadily someone holds a phone is itself observable behaviour,
/// and it costs nothing extra to record now that the sensor is running.
///
/// Raw accelerometer and gyroscope access needs no permission prompt. Only activity and
/// pedometer data do, and neither is used here.
@MainActor
@Observable
public final class DeviceMotionMonitor {

    /// Angular speed above which the phone counts as being moved rather than held, in
    /// radians per second. About 34 degrees per second, which is well clear of the tremor
    /// of a steady hand.
    public static let rotationLimit = 0.60
    /// Acceleration above which the phone counts as being moved, in g, excluding gravity.
    public static let accelerationLimit = 0.25

    /// Magnitude of the current rotation rate, in radians per second.
    public private(set) var rotationRate: Double = 0
    /// Magnitude of the current user acceleration, in g.
    public private(set) var acceleration: Double = 0
    public private(set) var isAvailable = false

    /// False while the phone is being moved quickly enough that the gaze geometry is stale.
    public var isSteady: Bool {
        rotationRate < Self.rotationLimit && acceleration < Self.accelerationLimit
    }

    private let manager = CMMotionManager()

    public init() {
        isAvailable = manager.isDeviceMotionAvailable
    }

    public func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            MainActor.assumeIsolated {
                self.rotationRate = Self.magnitude(
                    motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z
                )
                self.acceleration = Self.magnitude(
                    motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z
                )
            }
        }
    }

    public func stop() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
        rotationRate = 0
        acceleration = 0
    }

    nonisolated static func magnitude(_ x: Double, _ y: Double, _ z: Double) -> Double {
        (x * x + y * y + z * z).squareRoot()
    }
}
