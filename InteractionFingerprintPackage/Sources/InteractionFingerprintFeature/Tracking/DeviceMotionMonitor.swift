import CoreMotion
import Foundation
import Observation
import simd

/// Reads the phone's inertial sensors and reports what they can legitimately say about
/// the gaze measurement: how far the phone has turned recently, how hard it is being
/// accelerated, and how it is being held.
///
/// The gyroscope measures the phone, never the eye. Its job here is not to improve the
/// gaze estimate, which it cannot do, but to say how much the screen has moved under the
/// eyes, so frames captured mid-movement can be marked. See `MotionGate` for the decision
/// and `docs/product/10-MOTION-FUSION.md` for the reasoning.
///
/// Two quantities are kept deliberately separate. **Rotation rate** is what a resting hand
/// produces continuously: tremor at eight to twelve hertz has a high angular velocity and
/// almost no net displacement. **Net rotation** over a short window is what actually moves
/// the screen under the eyes. The gate uses the second; the first is recorded as a
/// covariate only.
@MainActor
@Observable
public final class DeviceMotionMonitor {

    /// Smoothing window for rate and acceleration, in seconds.
    nonisolated public static let smoothingWindow = 0.15
    /// How much attitude history to keep, in seconds. Longer than any window the gate asks for.
    nonisolated public static let historyDuration = 0.6

    /// Smoothed angular speed, radians per second.
    public private(set) var rotationRate: Double = 0
    /// Smoothed linear acceleration with gravity removed, in g.
    public private(set) var acceleration: Double = 0
    /// Angle the phone has turned over `MotionGate.window`, in radians. Direction-free.
    public private(set) var netRotation: Double = 0
    /// How far the screen leans back from vertical, in radians. Zero held upright, π/2
    /// lying flat facing up. From the gravity vector, so it does not drift.
    public private(set) var tilt: Double = 0
    /// Sideways lean of the phone's long axis, in radians. Positive when the top of the
    /// phone leans towards the participant's right.
    public private(set) var roll: Double = 0
    public private(set) var isAvailable = false

    private let manager = CMMotionManager()
    private var lastUpdate: TimeInterval?
    private var attitudes: [(timestamp: TimeInterval, orientation: simd_quatd)] = []

    public init() {
        isAvailable = manager.isDeviceMotionAvailable
    }

    public func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 100.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            MainActor.assumeIsolated {
                let q = motion.attitude.quaternion
                self.ingest(
                    rotationRate: Self.magnitude(
                        motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z
                    ),
                    acceleration: Self.magnitude(
                        motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z
                    ),
                    attitude: simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w),
                    gravity: SIMD3(motion.gravity.x, motion.gravity.y, motion.gravity.z),
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
        netRotation = 0
        lastUpdate = nil
        attitudes.removeAll()
    }

    /// One inertial sample. Exposed so the arithmetic can be driven under test.
    func ingest(
        rotationRate: Double,
        acceleration: Double,
        attitude: simd_quatd,
        gravity: SIMD3<Double>,
        timestamp: TimeInterval
    ) {
        let elapsed = lastUpdate.map { timestamp - $0 } ?? 0
        lastUpdate = timestamp

        let alpha = elapsed > 0 ? min(elapsed / Self.smoothingWindow, 1) : 1
        self.rotationRate += (rotationRate - self.rotationRate) * alpha
        self.acceleration += (acceleration - self.acceleration) * alpha

        attitudes.append((timestamp, attitude))
        attitudes.removeAll { timestamp - $0.timestamp > Self.historyDuration }
        netRotation = Self.netRotation(in: attitudes, over: MotionGate.window)

        let lean = Self.lean(gravity: gravity)
        tilt = lean.tilt
        roll = lean.roll
    }

    // MARK: Arithmetic

    /// Angle between the latest attitude and the one recorded `window` seconds earlier.
    ///
    /// The angle between two orientations does not depend on which way any axis points,
    /// which is the reason this is used rather than integrating the gyroscope along named
    /// axes: Core Motion's device frame and ARKit's camera frame differ, and a sign error
    /// there would be silent.
    nonisolated static func netRotation(
        in history: [(timestamp: TimeInterval, orientation: simd_quatd)],
        over window: TimeInterval
    ) -> Double {
        guard let latest = history.last else { return 0 }
        let cutoff = latest.timestamp - window
        // The most recent sample at or before the cutoff, or the oldest we have.
        let reference = history.last { $0.timestamp <= cutoff } ?? history[0]
        return angle(between: reference.orientation, and: latest.orientation)
    }

    /// Rotation angle taking one unit quaternion to another, in radians, always in 0...π.
    nonisolated static func angle(between a: simd_quatd, and b: simd_quatd) -> Double {
        let dot = abs(simd_dot(simd_normalize(a).vector, simd_normalize(b).vector))
        return 2 * acos(min(dot, 1))
    }

    /// Tilt and roll from the gravity vector expressed in the device frame, where x points
    /// right, y up the long axis and z out of the screen towards the person.
    nonisolated static func lean(gravity g: SIMD3<Double>) -> (tilt: Double, roll: Double) {
        let length = simd_length(g)
        guard length > 1e-6 else { return (0, 0) }
        let unit = g / length
        let tilt = asin(min(max(-unit.z, -1), 1))
        let roll = atan2(unit.x, -unit.y)
        return (tilt, roll)
    }

    nonisolated static func magnitude(_ x: Double, _ y: Double, _ z: Double) -> Double {
        (x * x + y * y + z * z).squareRoot()
    }
}
