import Foundation

/// Head position and orientation for one frame.
///
/// Position is in metres relative to the camera. Rotation values are Euler angles
/// in radians about the face anchor's x, y and z axes respectively, which for a
/// head-on face correspond approximately to pitch, yaw and roll.
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
/// This is raw sensor data only. It carries no interpretation: values such as
/// `eyeSquintLeft` are recorded as numbers and are never labelled as emotions.
/// See `.claude/skills/privacy-responsible-ai`.
public struct FaceSample: Codable, Sendable, Equatable {
    /// Frame time from `ARFrame.timestamp`, in seconds on the device monotonic
    /// clock. This is the master clock for the whole project. Interaction events
    /// must be stamped from the same time base via `ProcessInfo.systemUptime`.
    public let timestamp: TimeInterval

    /// False when ARKit has lost the face. Gaps are data and are recorded, not dropped.
    public let isTracked: Bool

    /// Gaze position normalised to the viewport, origin top left, range 0...1.
    /// Values outside 0...1 mean the estimate fell off screen and are kept as-is.
    /// Nil when the face is not tracked.
    public let gazeX: Double?
    public let gazeY: Double?

    /// The V0 blend-shape subset, keyed by `ARFaceAnchor.BlendShapeLocation` raw value.
    public let signals: [String: Double]

    /// Nil when the face is not tracked.
    public let head: HeadPose?

    public init(
        timestamp: TimeInterval,
        isTracked: Bool,
        gazeX: Double?,
        gazeY: Double?,
        signals: [String: Double],
        head: HeadPose?
    ) {
        self.timestamp = timestamp
        self.isTracked = isTracked
        self.gazeX = gazeX
        self.gazeY = gazeY
        self.signals = signals
        self.head = head
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, isTracked, gazeX, gazeY, signals, head
    }

    /// Written by hand because the synthesised encoder omits nil optionals entirely.
    /// Analysis reads these exports into a DataFrame and needs a stable column set,
    /// so absent values must appear as explicit nulls rather than missing keys.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(isTracked, forKey: .isTracked)
        try container.encode(signals, forKey: .signals)

        if let gazeX { try container.encode(gazeX, forKey: .gazeX) }
        else { try container.encodeNil(forKey: .gazeX) }

        if let gazeY { try container.encode(gazeY, forKey: .gazeY) }
        else { try container.encodeNil(forKey: .gazeY) }

        if let head { try container.encode(head, forKey: .head) }
        else { try container.encodeNil(forKey: .head) }
    }
}
