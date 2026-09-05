import ARKit
import Foundation
import Observation

/// Which physical eye each ARKit blend-shape channel actually reports on.
///
/// Apple documents `eyeBlinkLeft` as the participant's anatomical left eye. Testing on
/// device suggested the opposite. Rather than trust either the documentation or a single
/// observation, the app measures it: the participant winks one named eye and we record
/// which channel responded.
///
/// This is not cosmetic. If the column labelled left is really the right eye, any finding
/// about one eye against the other is inverted, and nothing in the data would reveal it.
public struct EyeLaterality: Codable, Sendable, Equatable {
    /// True when ARKit's `eyeBlink_L` channel responds to the participant's right eye.
    public let arkitLeftIsParticipantRight: Bool
    /// How cleanly the two channels separated during the check, 0...1. Below about 0.25
    /// the result is not trustworthy.
    public let separation: Double
    public let verifiedAt: Date

    public init(arkitLeftIsParticipantRight: Bool, separation: Double, verifiedAt: Date = Date()) {
        self.arkitLeftIsParticipantRight = arkitLeftIsParticipantRight
        self.separation = separation
        self.verifiedAt = verifiedAt
    }

    /// Minimum separation before the measurement counts.
    public static let minimumSeparation = 0.25

    public var isTrustworthy: Bool { separation >= Self.minimumSeparation }

    /// Which of the participant's eyes an ARKit key describes.
    public func participantSide(forARKitKey key: String) -> String? {
        let isLeftChannel: Bool
        if key.hasSuffix("_L") { isLeftChannel = true }
        else if key.hasSuffix("_R") { isLeftChannel = false }
        else { return nil }

        let isParticipantRight = isLeftChannel == arkitLeftIsParticipantRight
        return isParticipantRight ? "right" : "left"
    }

    public var summary: String {
        String(
            format: "ARKit _L = participant's %@ eye · separation %.2f",
            arkitLeftIsParticipantRight ? "right" : "left",
            separation
        )
    }
}

/// Runs the wink test.
///
/// One prompt is enough to resolve the mapping: ask for a named eye, see which channel
/// moves. A second prompt for the other eye is used as a cross-check, because a
/// participant who winks the wrong eye would otherwise silently reverse the whole dataset.
@MainActor
@Observable
public final class EyeLateralityCheck {

    public enum Side: String, Sendable {
        case right, left
        var prompt: String { "Close your \(rawValue) eye only" }
    }

    public enum Phase: Equatable {
        case settling(Side)
        case measuring(Side)
        case finished(EyeLaterality?, disagreed: Bool)
    }

    nonisolated public static let settleDuration: TimeInterval = 1.2
    nonisolated public static let measureDuration: TimeInterval = 1.3

    public private(set) var phase: Phase = .settling(.right)
    /// Live peak of each channel, for the progress display.
    public private(set) var peakLeftChannel: Double = 0
    public private(set) var peakRightChannel: Double = 0

    private var phaseStartedAt: TimeInterval?
    private var firstResult: EyeLaterality?

    public init() {}

    public var currentSide: Side? {
        switch phase {
        case .settling(let side), .measuring(let side): side
        case .finished: nil
        }
    }

    public var instruction: String {
        switch phase {
        case .settling(let side): side.prompt
        case .measuring(let side): "Hold. \(side.prompt.lowercased())"
        case .finished: "Done"
        }
    }

    public func restart() {
        phase = .settling(.right)
        phaseStartedAt = nil
        firstResult = nil
        peakLeftChannel = 0
        peakRightChannel = 0
    }

    /// Feed one tracked frame's blend shapes.
    public func receive(signals: [String: Double], isTracked: Bool, timestamp: TimeInterval) {
        guard let side = currentSide, isTracked else { return }

        let start = phaseStartedAt ?? timestamp
        if phaseStartedAt == nil { phaseStartedAt = timestamp }
        let elapsed = timestamp - start

        if elapsed < Self.settleDuration {
            phase = .settling(side)
            peakLeftChannel = 0
            peakRightChannel = 0
            return
        }

        phase = .measuring(side)
        let left = signals[ARFaceAnchor.BlendShapeLocation.eyeBlinkLeft.rawValue] ?? 0
        let right = signals[ARFaceAnchor.BlendShapeLocation.eyeBlinkRight.rawValue] ?? 0
        peakLeftChannel = max(peakLeftChannel, left)
        peakRightChannel = max(peakRightChannel, right)

        guard elapsed >= Self.settleDuration + Self.measureDuration else { return }
        conclude(side: side, timestamp: timestamp)
    }

    private func conclude(side: Side, timestamp: TimeInterval) {
        let separation = abs(peakLeftChannel - peakRightChannel)
        let leftChannelWon = peakLeftChannel > peakRightChannel

        // If the participant closed their right eye and the _L channel responded, then the
        // _L channel reports on the participant's right eye.
        let arkitLeftIsParticipantRight = side == .right ? leftChannelWon : !leftChannelWon
        let result = EyeLaterality(
            arkitLeftIsParticipantRight: arkitLeftIsParticipantRight,
            separation: separation
        )

        peakLeftChannel = 0
        peakRightChannel = 0
        phaseStartedAt = nil

        guard let first = firstResult else {
            firstResult = result
            phase = .settling(.left)
            return
        }

        // Both prompts must agree, and both must have separated cleanly.
        let agree = first.arkitLeftIsParticipantRight == result.arkitLeftIsParticipantRight
        let combined = EyeLaterality(
            arkitLeftIsParticipantRight: first.arkitLeftIsParticipantRight,
            separation: min(first.separation, result.separation)
        )
        phase = .finished(
            agree && combined.isTrustworthy ? combined : nil,
            disagreed: !agree
        )
    }
}

/// Persists the verified mapping. Moves into the session record with the storage milestone.
public enum EyeLateralityStore {
    private static let key = "interactionFingerprint.eyeLaterality.v1"

    public static func load(from defaults: UserDefaults = .standard) -> EyeLaterality? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(EyeLaterality.self, from: data)
    }

    public static func save(_ value: EyeLaterality, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    public static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
