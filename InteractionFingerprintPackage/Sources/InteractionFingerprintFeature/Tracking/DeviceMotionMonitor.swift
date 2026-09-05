import CoreMotion
import Foundation
import Observation

/// Watches the gyroscope and accelerometer so the tracker knows when the phone itself is
/// being moved, rather than merely held by a human hand.
///
/// That distinction is the whole difficulty. A hand at rest still rotates a few tenths of a
/// radian per second and accelerates a tenth of a g, continuously. A threshold tight enough
/// to catch a deliberate reposition will also fire on tremor, dozens of times a second,
/// and a gate that chatters is worse than no gate: each flip discards a frame, the drawn
/// dot freezes, and it lurches when the gate reopens.
///
/// Three things prevent that. The signal is smoothed over a short window so a single spike
/// cannot trip it. The thresholds are set well above hand tremor. And they are asymmetric,
/// so once the phone is judged to be moving it has to become properly still again before
/// that verdict is withdrawn.
@MainActor
@Observable
public final class DeviceMotionMonitor {

    /// Angular speed at which the phone is judged to be in motion, radians per second.
    /// About 86°/s, far above the tremor of a steady hand.
    nonisolated public static let rotationMovingThreshold = 1.5
    /// It must fall back below this before being judged still again. The gap is what stops
    /// the verdict flickering.
    nonisolated public static let rotationSteadyThreshold = 0.9

    /// Acceleration at which the phone is judged to be in motion, in g, gravity excluded.
    nonisolated public static let accelerationMovingThreshold = 0.60
    nonisolated public static let accelerationSteadyThreshold = 0.35

    /// Smoothing window for the motion signal, in seconds. Long enough to ignore a single
    /// jolt, short enough to notice a real reposition immediately.
    nonisolated public static let smoothingWindow = 0.15

    public private(set) var rotationRate: Double = 0
    public private(set) var acceleration: Double = 0
    public private(set) var isAvailable = false

    /// False only while the phone is genuinely being moved.
    public private(set) var isSteady = true

    private let manager = CMMotionManager()
    private var lastUpdate: TimeInterval?

    public init() {
        isAvailable = manager.isDeviceMotionAvailable
    }

    public func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            MainActor.assumeIsolated {
                self.ingest(
                    rotation: Self.magnitude(
                        motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z
                    ),
                    acceleration: Self.magnitude(
                        motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z
                    ),
                    timestamp: motion.timestamp
                )
            }
        }
    }

    public func stop() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
        rotationRate = 0
        acceleration = 0
        isSteady = true
        lastUpdate = nil
    }

    func ingest(rotation: Double, acceleration: Double, timestamp: TimeInterval) {
        let elapsed = lastUpdate.map { timestamp - $0 } ?? 0
        lastUpdate = timestamp

        let alpha = elapsed > 0
            ? min(elapsed / Self.smoothingWindow, 1)
            : 1
        rotationRate += (rotation - rotationRate) * alpha
        self.acceleration += (acceleration - self.acceleration) * alpha

        isSteady = Self.updatedSteadiness(
            wasSteady: isSteady,
            rotation: rotationRate,
            acceleration: self.acceleration
        )
    }

    /// Asymmetric thresholds: harder to be declared moving than to be declared still again.
    nonisolated static func updatedSteadiness(
        wasSteady: Bool,
        rotation: Double,
        acceleration: Double
    ) -> Bool {
        if wasSteady {
            let movingNow = rotation > rotationMovingThreshold
                || acceleration > accelerationMovingThreshold
            return !movingNow
        }
        return rotation < rotationSteadyThreshold && acceleration < accelerationSteadyThreshold
    }

    nonisolated static func magnitude(_ x: Double, _ y: Double, _ z: Double) -> Double {
        (x * x + y * y + z * z).squareRoot()
    }
}
