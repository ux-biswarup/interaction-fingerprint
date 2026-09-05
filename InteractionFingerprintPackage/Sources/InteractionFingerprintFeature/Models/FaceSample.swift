import CoreGraphics
import Foundation

/// Head position and orientation for one frame, relative to the camera.
///
/// Position is in metres. Rotation values are Euler angles in radians about the face
/// anchor's x, y and z axes, which for a head-on face correspond to pitch, yaw and roll.
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

    /// Combined off-axis head rotation in radians, used for the quality envelope.
    public var offAxisRotation: Double { (pitch * pitch + yaw * yaw).squareRoot() }
}

/// How the phone was being held and moved on one frame.
///
/// A covariate, not a signal. Tilt and roll come from the gravity vector, so they do not
/// drift; the disturbance figure is how far the screen moved under the eyes over the
/// reaction window, which is what decides the `device_moving` quality flag.
/// See `docs/product/10-MOTION-FUSION.md`.
public struct DeviceAttitude: Codable, Sendable, Equatable {
    /// Lean of the screen back from vertical, radians. Zero upright, π/2 lying flat face up.
    public let tilt: Double
    /// Sideways lean of the long axis, radians. Positive when the top leans to the
    /// participant's right.
    public let roll: Double
    /// Smoothed angular speed of the phone, radians per second.
    public let rotationRate: Double
    /// Displacement of the screen under the eyes over the last `MotionGate.window`, metres.
    public let disturbance: Double

    public init(tilt: Double, roll: Double, rotationRate: Double, disturbance: Double) {
        self.tilt = tilt
        self.roll = roll
        self.rotationRate = rotationRate
        self.disturbance = disturbance
    }
}

/// One frame of observable face and gaze measurements.
///
/// Raw sensor data only. It carries no interpretation: `eyeSquint_L` is a number, never
/// a claim about how someone feels. See `.claude/skills/privacy-responsible-ai`.
///
/// The gaze **angles** are recorded alongside the eye position, not just the final screen
/// coordinate. Angles plus eye position are the physical measurement and are independent
/// of the calibration in force at recording time, so any session can be re-mapped offline
/// with a better model later. Storing only the screen coordinate would strand every
/// recording behind whichever calibration happened to be loaded that day.
public struct FaceSample: Codable, Sendable, Equatable {
    /// Frame time from `ARFrame.timestamp`, in seconds on the device monotonic clock.
    /// The master clock for the project. Interaction events are stamped from the same
    /// time base through `ProcessInfo.systemUptime`.
    public let timestamp: TimeInterval

    public let isTracked: Bool

    /// False when either eye is more than half closed. Gaze during a blink is meaningless
    /// and must be filtered before fixation detection, but the sample is still recorded so
    /// blink rate stays measurable.
    public let eyesOpen: Bool

    /// Why this frame is or is not trustworthy, as a stable string for analysis.
    public let quality: String

    /// Eye midpoint in camera-space metres. z is negative, in front of the camera.
    public let eyeX: Double?
    public let eyeY: Double?
    public let eyeZ: Double?

    /// Gaze direction ratios from ARKit's convergence point: dx/dz and dy/dz.
    public let convergenceU: Double?
    public let convergenceV: Double?

    /// Gaze direction ratios from each eye's own orientation, averaged.
    public let perEyeU: Double?
    public let perEyeV: Double?

    /// Gaze mapped onto the screen, origin top left, range 0...1. Values outside that
    /// range mean the estimate fell off the display and are kept as they are.
    public let gazeX: Double?
    public let gazeY: Double?

    /// False when the mapping came from the uncalibrated geometric fallback. Those
    /// samples must not be pooled with calibrated ones.
    public let isCalibrated: Bool

    /// The V0 blend-shape subset, keyed by `ARFaceAnchor.BlendShapeLocation` raw value.
    public let signals: [String: Double]

    public let head: HeadPose?

    /// How the phone was held and moved on this frame. Nil when motion data was unavailable.
    public let device: DeviceAttitude?

    public init(
        timestamp: TimeInterval,
        isTracked: Bool,
        eyesOpen: Bool,
        quality: String,
        eyeX: Double?, eyeY: Double?, eyeZ: Double?,
        convergenceU: Double?, convergenceV: Double?,
        perEyeU: Double?, perEyeV: Double?,
        gazeX: Double?, gazeY: Double?,
        isCalibrated: Bool,
        signals: [String: Double],
        head: HeadPose?,
        device: DeviceAttitude? = nil
    ) {
        self.timestamp = timestamp
        self.isTracked = isTracked
        self.eyesOpen = eyesOpen
        self.quality = quality
        self.eyeX = eyeX
        self.eyeY = eyeY
        self.eyeZ = eyeZ
        self.convergenceU = convergenceU
        self.convergenceV = convergenceV
        self.perEyeU = perEyeU
        self.perEyeV = perEyeV
        self.gazeX = gazeX
        self.gazeY = gazeY
        self.isCalibrated = isCalibrated
        self.signals = signals
        self.head = head
        self.device = device
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, isTracked, eyesOpen, quality
        case eyeX, eyeY, eyeZ
        case convergenceU, convergenceV, perEyeU, perEyeV
        case gazeX, gazeY, isCalibrated
        case signals, head, device
    }

    /// Written by hand because the synthesised encoder omits nil optionals entirely.
    /// Analysis reads these exports into a DataFrame and needs a stable column set, so
    /// absent values must appear as explicit nulls rather than missing keys.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(isTracked, forKey: .isTracked)
        try container.encode(eyesOpen, forKey: .eyesOpen)
        try container.encode(quality, forKey: .quality)
        try container.encode(isCalibrated, forKey: .isCalibrated)
        try container.encode(signals, forKey: .signals)

        try encodeOrNull(eyeX, .eyeX, into: &container)
        try encodeOrNull(eyeY, .eyeY, into: &container)
        try encodeOrNull(eyeZ, .eyeZ, into: &container)
        try encodeOrNull(convergenceU, .convergenceU, into: &container)
        try encodeOrNull(convergenceV, .convergenceV, into: &container)
        try encodeOrNull(perEyeU, .perEyeU, into: &container)
        try encodeOrNull(perEyeV, .perEyeV, into: &container)
        try encodeOrNull(gazeX, .gazeX, into: &container)
        try encodeOrNull(gazeY, .gazeY, into: &container)

        if let head { try container.encode(head, forKey: .head) }
        else { try container.encodeNil(forKey: .head) }
        if let device { try container.encode(device, forKey: .device) }
        else { try container.encodeNil(forKey: .device) }
    }

    private func encodeOrNull(
        _ value: Double?,
        _ key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if let value { try container.encode(value, forKey: key) }
        else { try container.encodeNil(forKey: key) }
    }
}
