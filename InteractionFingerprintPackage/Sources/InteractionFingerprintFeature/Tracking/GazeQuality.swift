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
    case notCalibrated
    case outsideCalibratedRange(Double)

    /// Comfortable working range for a hand-held phone, in metres.
    public static let nearLimit = 0.22
    public static let farLimit = 0.65
    /// Beyond this head rotation the eye model degrades sharply, in radians. About 20°.
    public static let maximumHeadRotation = 0.35

    /// True when a sample from this frame belongs in an analysis.
    public var isUsable: Bool {
        switch self {
        case .good, .notCalibrated, .outsideCalibratedRange: true
        case .noFace, .blinking, .tooClose, .tooFar, .headTurned: false
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
        case .notCalibrated: "Not calibrated"
        case .outsideCalibratedRange: "Outside the calibrated distance"
        }
    }

    public static func evaluate(
        isTracked: Bool,
        eyesOpen: Bool,
        distance: Double?,
        headRotation: Double?,
        model: GazeModel?
    ) -> GazeQuality {
        guard isTracked, let distance else { return .noFace }
        if !eyesOpen { return .blinking }
        if distance < nearLimit { return .tooClose(distance) }
        if distance > farLimit { return .tooFar(distance) }
        if let headRotation, headRotation > maximumHeadRotation { return .headTurned(headRotation) }
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
