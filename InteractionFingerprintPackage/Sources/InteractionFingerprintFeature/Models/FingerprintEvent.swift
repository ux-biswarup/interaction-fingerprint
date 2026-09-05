import Foundation

/// One row of the Interaction Fingerprint dataset.
///
/// Sensor samples and product events share a single type and a single stream, because the
/// whole point of the fingerprint is that they are comparable in time. Splitting them into
/// separate tables would push the join into analysis, where an off-by-one in the merge
/// would be invisible.
///
/// Raw observations only. No field here names an emotion or an intent. `eyeSquint_L` is a
/// number; whether it means anything is a question for analysis, not for the recorder.
/// See `.claude/skills/privacy-responsible-ai`.
public struct FingerprintEvent: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    /// Monotonically increasing within a session. A gap in this column means events were
    /// lost, which is something analysis must be able to detect rather than infer.
    public let sequence: Int
    /// Seconds on the device monotonic clock, shared with `ARFrame.timestamp`.
    public let timestamp: TimeInterval
    public let event: String

    public let screen: String?
    public let target: String?
    public let productID: String?

    /// Position of a tap, or of the gaze, normalised to the screen with the origin at the
    /// top left.
    public let x: Double?
    public let y: Double?

    /// Duration of whatever just ended: a dwell on a region, a press, a screen visit.
    public let durationMs: Double?

    /// Event-specific numbers. Scroll velocity, touch contact area, ambient intensity.
    /// Kept as a dictionary so a new measurement does not force a schema version bump,
    /// but every key that appears must be documented in `05-DATA-SCHEMA.md`.
    public let metrics: [String: Double]

    /// True while the eyes were open and the frame was inside the trusted envelope.
    public let eyesOpen: Bool?
    /// Why the gaze on this row is or is not trustworthy.
    public let quality: String?
    /// Blend-shape coefficients, keyed by ARKit raw value.
    public let signals: [String: Double]

    public init(
        sequence: Int,
        timestamp: TimeInterval,
        event: EventKind,
        screen: ScreenID? = nil,
        target: TargetID? = nil,
        productID: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        durationMs: Double? = nil,
        metrics: [String: Double] = [:],
        eyesOpen: Bool? = nil,
        quality: String? = nil,
        signals: [String: Double] = [:]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.sequence = sequence
        self.timestamp = timestamp
        self.event = event.rawValue
        self.screen = screen?.rawValue
        self.target = target?.rawValue
        self.productID = productID
        self.x = x
        self.y = y
        self.durationMs = durationMs
        self.metrics = metrics
        self.eyesOpen = eyesOpen
        self.quality = quality
        self.signals = signals
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sequence, timestamp, event
        case screen, target, productID
        case x, y, durationMs, metrics
        case eyesOpen, quality, signals
    }

    /// Written by hand because the synthesised encoder omits nil optionals, and analysis
    /// reads these files into a DataFrame that needs the same columns on every row.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(sequence, forKey: .sequence)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(event, forKey: .event)
        try c.encode(metrics, forKey: .metrics)
        try c.encode(signals, forKey: .signals)

        try encodeOrNull(screen, .screen, into: &c)
        try encodeOrNull(target, .target, into: &c)
        try encodeOrNull(productID, .productID, into: &c)
        try encodeOrNull(quality, .quality, into: &c)
        try encodeOrNull(x, .x, into: &c)
        try encodeOrNull(y, .y, into: &c)
        try encodeOrNull(durationMs, .durationMs, into: &c)

        if let eyesOpen { try c.encode(eyesOpen, forKey: .eyesOpen) }
        else { try c.encodeNil(forKey: .eyesOpen) }
    }

    private func encodeOrNull<T: Encodable>(
        _ value: T?, _ key: CodingKeys, into c: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if let value { try c.encode(value, forKey: key) } else { try c.encodeNil(forKey: key) }
    }
}

/// Everything about a session that is not a per-event measurement.
public struct SessionRecord: Codable, Sendable, Equatable {
    public let id: String
    public let appID: String
    public let appVersion: String
    public let clockAnchor: SessionClock.Anchor
    public let device: DeviceRecord
    /// The gaze model in force, so a recording can be re-mapped later or excluded if the
    /// calibration was poor.
    public let calibration: GazeModel?
    /// Which physical eye each ARKit channel reported on, verified by the wink test.
    /// A session without this cannot support any claim about one eye against the other.
    public let eyeLaterality: EyeLaterality?
    public let startedAt: TimeInterval
    public var endedAt: TimeInterval?

    public init(
        id: String = UUID().uuidString,
        appID: String,
        appVersion: String,
        clockAnchor: SessionClock.Anchor = SessionClock.Anchor(),
        device: DeviceRecord,
        calibration: GazeModel?,
        eyeLaterality: EyeLaterality?,
        startedAt: TimeInterval = SessionClock.now,
        endedAt: TimeInterval? = nil
    ) {
        self.id = id
        self.appID = appID
        self.appVersion = appVersion
        self.clockAnchor = clockAnchor
        self.device = device
        self.calibration = calibration
        self.eyeLaterality = eyeLaterality
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// Device context. No identifiers: the model and OS explain variance between sessions,
/// while a serial number or advertising ID would identify a person and is never collected.
public struct DeviceRecord: Codable, Sendable, Equatable {
    public let model: String
    public let systemVersion: String
    public let screenPointWidth: Double
    public let screenPointHeight: Double
    public let displayScale: Double

    public init(
        model: String,
        systemVersion: String,
        screenPointWidth: Double,
        screenPointHeight: Double,
        displayScale: Double
    ) {
        self.model = model
        self.systemVersion = systemVersion
        self.screenPointWidth = screenPointWidth
        self.screenPointHeight = screenPointHeight
        self.displayScale = displayScale
    }
}
