import CoreGraphics
import Foundation

/// Head position and orientation for one frame.
///
/// Position is in metres relative to the camera. Rotation values are Euler angles in
/// radians about the face anchor's x, y and z axes, which for a head-on face correspond
/// approximately to pitch, yaw and roll.
public struct HeadPose: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double
    public let pitch: Double
    public let yaw: Double
    public let roll: Double

    public init(x: Double, y: Double, z: Double, pitch: Double, yaw: Double, roll: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.pitch = pitch
        self.yaw = yaw
        self.roll = roll
    }
}

/// One frame of observable face and gaze measurements.
///
/// Raw sensor data only. It carries no interpretation: `eyeSquint_L` is a number, never
/// a claim about how someone feels. See `.claude/skills/privacy-responsible-ai`.
///
/// Both the raw and the mapped gaze are kept. The raw screen-plane intersection in metres
/// is the physical measurement and does not depend on the calibration in force at
/// recording time, so a session can be re-mapped offline if a better calibration is
/// fitted later. Discarding it would make old recordings unusable.
public struct FaceSample: Codable, Sendable, Equatable {
    /// Frame time from `ARFrame.timestamp`, in seconds on the device monotonic clock.
    /// This is the master clock for the project. Interaction events are stamped from the
    /// same time base through `ProcessInfo.systemUptime`.
    public let timestamp: TimeInterval

    /// False when ARKit has lost the face. Gaps are data and are recorded, not dropped.
    public let isTracked: Bool

    /// False when either eye's blend shape says the eye is more than half closed. Gaze
    /// during a blink is meaningless and must be filtered before fixation detection,
    /// but the sample is still recorded so blink rate stays measurable.
    public let eyesOpen: Bool

    /// Where the gaze ray met the plane of the screen, in metres in camera space.
    /// The physical measurement, independent of any calibration.
    public let rawGazeX: Double?
    public let rawGazeY: Double?

    /// Gaze normalised to the screen, origin top left, range 0...1. Values outside that
    /// range mean the estimate fell off the display and are kept as they are.
    public let gazeX: Double?
    public let gazeY: Double?

    /// True when a fitted calibration produced `gazeX` and `gazeY`. When false those
    /// values came from the uncalibrated geometric fallback and should not be trusted
    /// for analysis.
    public let isCalibrated: Bool

    /// The V0 blend-shape subset, keyed by `ARFaceAnchor.BlendShapeLocation` raw value.
    public let signals: [String: Double]

    public let head: HeadPose?

    public init(
        timestamp: TimeInterval,
        isTracked: Bool,
        eyesOpen: Bool,
        rawGazeX: Double?,
        rawGazeY: Double?,
        gazeX: Double?,
        gazeY: Double?,
        isCalibrated: Bool,
        signals: [String: Double],
        head: HeadPose?
    ) {
        self.timestamp = timestamp
        self.isTracked = isTracked
        self.eyesOpen = eyesOpen
        self.rawGazeX = rawGazeX
        self.rawGazeY = rawGazeY
        self.gazeX = gazeX
        self.gazeY = gazeY
        self.isCalibrated = isCalibrated
        self.signals = signals
        self.head = head
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, isTracked, eyesOpen
        case rawGazeX, rawGazeY, gazeX, gazeY, isCalibrated
        case signals, head
    }

    /// Written by hand because the synthesised encoder omits nil optionals entirely.
    /// Analysis reads these exports into a DataFrame and needs a stable column set, so
    /// absent values must appear as explicit nulls rather than missing keys.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(isTracked, forKey: .isTracked)
        try container.encode(eyesOpen, forKey: .eyesOpen)
        try container.encode(isCalibrated, forKey: .isCalibrated)
        try container.encode(signals, forKey: .signals)

        if let rawGazeX { try container.encode(rawGazeX, forKey: .rawGazeX) }
        else { try container.encodeNil(forKey: .rawGazeX) }

        if let rawGazeY { try container.encode(rawGazeY, forKey: .rawGazeY) }
        else { try container.encodeNil(forKey: .rawGazeY) }

        if let gazeX { try container.encode(gazeX, forKey: .gazeX) }
        else { try container.encodeNil(forKey: .gazeX) }

        if let gazeY { try container.encode(gazeY, forKey: .gazeY) }
        else { try container.encodeNil(forKey: .gazeY) }

        if let head { try container.encode(head, forKey: .head) }
        else { try container.encodeNil(forKey: .head) }
    }
}
