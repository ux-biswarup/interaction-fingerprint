import Foundation

/// Decides whether the phone moved enough, recently enough, to spoil a gaze frame.
///
/// The question is asked in the unit that matters: **how far did the screen move under the
/// eyes** during the time the eyes need to react. Rotation contributes its angle scaled
/// by viewing distance, translation contributes half the acceleration times the window
/// squared. Both come out in metres on the display and are compared with the tracker's
/// own accuracy.
///
/// Earlier versions gated on angular velocity and felt over-sensitive however the
/// thresholds were tuned. That was the wrong quantity: a resting hand trembles at eight to
/// twelve hertz with a peak velocity that looks like a deliberate movement, yet rotates
/// back before the eye has had time to notice. Net displacement over the reaction window
/// separates the two cleanly. See `docs/product/10-MOTION-FUSION.md` section 5.
public struct MotionGate: Sendable, Equatable {

    /// The window the displacement is measured over, in seconds. On the order of the
    /// latency of smooth pursuit and corrective saccades.
    public static let window: TimeInterval = 0.12

    /// Displacement above which the frame is judged spoiled, in metres on the display.
    /// About twice the measured gaze accuracy of 11 mm.
    public static let movingThreshold = 0.020
    /// Displacement below which the phone is judged still again. The band between the two
    /// is what stops the verdict chattering.
    public static let steadyThreshold = 0.008

    /// Viewing distance assumed when no face is tracked, in metres.
    public static let fallbackDistance = 0.40

    /// Standard gravity, for converting an acceleration in g to metres per second squared.
    static let gravity = 9.80665

    public private(set) var isSteady = true
    /// Latest displacement estimate, in metres on the display.
    public private(set) var disturbance: Double = 0

    public init() {}

    /// Feed the latest inertial summary and current viewing distance.
    ///
    /// - Parameters:
    ///   - netRotation: angle turned over `window`, in radians.
    ///   - acceleration: smoothed linear acceleration, in g.
    ///   - distance: viewing distance in metres, or nil when no face is tracked.
    @discardableResult
    public mutating func update(netRotation: Double, acceleration: Double, distance: Double?) -> Bool {
        disturbance = Self.disturbance(netRotation: netRotation, acceleration: acceleration, distance: distance)
        isSteady = Self.verdict(wasSteady: isSteady, disturbance: disturbance)
        return isSteady
    }

    public mutating func reset() {
        isSteady = true
        disturbance = 0
    }

    /// How far the screen moved under the eyes, in metres.
    public static func disturbance(netRotation: Double, acceleration: Double, distance: Double?) -> Double {
        let viewing = distance ?? fallbackDistance
        let fromRotation = abs(netRotation) * viewing
        let fromTranslation = 0.5 * abs(acceleration) * gravity * window * window
        return fromRotation + fromTranslation
    }

    /// Asymmetric thresholds: harder to be declared moving than to be declared still again.
    public static func verdict(wasSteady: Bool, disturbance: Double) -> Bool {
        if wasSteady { return disturbance <= movingThreshold }
        return disturbance < steadyThreshold
    }
}
