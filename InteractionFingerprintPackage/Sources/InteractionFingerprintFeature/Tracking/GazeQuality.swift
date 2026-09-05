import Foundation

/// Whether the gaze estimate can be trusted on this frame, and if not, why.
///
/// Apple's own Eye Tracking works well partly because it defines an operating envelope
/// and says plainly when you have left it. A tracker that keeps drawing a confident dot
/// in conditions it cannot handle is worse than one that admits the gap, both for the
/// person using it and for the dataset, which would otherwise fill with plausible
/// looking nonsense.
public enum GazeQuality: Equatable, Sendable {
    case good
    case noFace
    case blinking
    case tooClose(Double)
    case tooFar(Double)
    case headTurned(Double)
    case deviceMoving
    case notCalibrated
    case outsideCalibratedRange(Double)

    /// Comfortable working range for a hand-held phone, in metres.
    public static let nearLimit = 0.22
    public static let farLimit = 0.65
    /// Beyond this head yaw the eye model degrades sharply, in radians. About 20°.
    public static let maximumHeadYaw = 0.35
    /// Pitch gets more room, about 34°. Looking down at a phone held below eye level is the
    /// ordinary posture, and the second recording flagged 5% of frames at a pitch of 20°
    /// with the yaw near zero. The camera sees a face from below in nearly every use of
    /// this device and ARKit is built for it.
    public static let maximumHeadPitch = 0.60

    /// True when a sample from this frame belongs in an analysis.
    public var isUsable: Bool {
        switch self {
        case .good, .notCalibrated, .outsideCalibratedRange: true
        case .noFace, .blinking, .tooClose, .tooFar, .headTurned, .deviceMoving: false
        }
    }

    /// True when the dot should be drawn at full strength.
    public var isConfident: Bool { self == .good }

    public var guidance: String {
        switch self {
        case .good: "Tracking"
        case .noFace: "Look at the screen"
        case .blinking: "Blink"
        case .tooClose: "Hold the phone further away"
        case .tooFar: "Hold the phone closer"
        case .headTurned: "Face the screen straight on"
        case .deviceMoving: "Hold the phone still"
        case .notCalibrated: "Not calibrated"
        case .outsideCalibratedRange: "Outside the calibrated distance"
        }
    }

    public static func evaluate(
        isTracked: Bool,
        eyesOpen: Bool,
        distance: Double?,
        headYaw: Double?,
        headPitch: Double?,
        deviceIsSteady: Bool = true,
        model: GazeModel?
    ) -> GazeQuality {
        guard isTracked, let distance else { return .noFace }
        if !eyesOpen { return .blinking }
        // Checked before the geometry tests: while the phone is being moved, ARKit's face
        // anchor and camera transform disagree and every derived number is unreliable,
        // including the distance those tests depend on.
        if !deviceIsSteady { return .deviceMoving }
        if distance < nearLimit { return .tooClose(distance) }
        if distance > farLimit { return .tooFar(distance) }
        if let headYaw, let headPitch,
           abs(headYaw) > maximumHeadYaw || abs(headPitch) > maximumHeadPitch {
            return .headTurned((headYaw * headYaw + headPitch * headPitch).squareRoot())
        }
        guard let model else { return .notCalibrated }

        // A little slack around the calibrated band: the fit degrades gradually rather
        // than falling off a cliff, so a few centimetres either side is still fine.
        let slack = 0.08
        let lower = model.calibratedDistanceRange.lowerBound - slack
        let upper = model.calibratedDistanceRange.upperBound + slack
        if distance < lower || distance > upper { return .outsideCalibratedRange(distance) }

        return .good
    }
}
