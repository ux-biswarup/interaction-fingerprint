import ARKit

/// The blend shapes recorded in V0.
///
/// ARKit exposes more than fifty coefficients. The setup guide deliberately starts
/// with a small, hypothesis-driven subset rather than recording everything, so the
/// dataset stays small and every column has a stated reason to exist.
/// See `docs/INTERACTION_FINGERPRINT_XCODE_SETUP.md` section 7.
public enum TrackedBlendShapes {

    /// Expression coefficients named in the setup guide: blink, squint, widen, brows.
    public static let expression: [ARFaceAnchor.BlendShapeLocation] = [
        .eyeBlinkLeft, .eyeBlinkRight,
        .eyeSquintLeft, .eyeSquintRight,
        .eyeWideLeft, .eyeWideRight,
        .browInnerUp, .browOuterUpLeft, .browOuterUpRight,
    ]

    /// Eye direction as expression coefficients.
    ///
    /// A second readout of gaze from the same ARKit model that produces the eye
    /// transforms. Recorded because it may carry appearance information, such as eyelid
    /// shape, that the transform does not, and offered to the calibration as optional
    /// inputs that cross-validation is free to reject. See
    /// `docs/product/10-MOTION-FUSION.md` section 7.
    public static let eyeDirection: [ARFaceAnchor.BlendShapeLocation] = [
        .eyeLookUpLeft, .eyeLookDownLeft, .eyeLookInLeft, .eyeLookOutLeft,
        .eyeLookUpRight, .eyeLookDownRight, .eyeLookInRight, .eyeLookOutRight,
    ]

    public static let all: [ARFaceAnchor.BlendShapeLocation] = expression + eyeDirection

    /// Raw-value keys in the same order, for stable column ordering in exports.
    ///
    /// Important: these are ARKit's own raw strings, which differ from the Swift case
    /// names. `.eyeBlinkLeft` has the raw value `eyeBlink_L`, not `eyeBlinkLeft`. The
    /// setup guide lists the Swift names; exported data and Python analysis will see
    /// the raw values below. Verified by test rather than assumed.
    ///
    ///     eyeBlink_L    eyeBlink_R
    ///     eyeSquint_L   eyeSquint_R
    ///     eyeWide_L     eyeWide_R
    ///     browInnerUp   browOuterUp_L   browOuterUp_R
    ///     eyeLookUp_L   eyeLookDown_L   eyeLookIn_L   eyeLookOut_L
    ///     eyeLookUp_R   eyeLookDown_R   eyeLookIn_R   eyeLookOut_R
    public static let keys: [String] = all.map(\.rawValue)

    /// The expression subset only, for the instrument readout.
    public static let expressionKeys: [String] = expression.map(\.rawValue)

    /// Above this value on either eye, that eye counts as closed.
    public static let blinkThreshold = 0.5

    /// Gaze during a blink is meaningless: the eye model has nothing to work from, and
    /// the estimate swings wildly. Samples are still recorded so blink rate stays
    /// measurable, but they are flagged so analysis can drop them before detecting
    /// fixations. See `.claude/skills/eye-tracking-concepts`.
    public static func eyesOpen(in signals: [String: Double], threshold: Double = blinkThreshold) -> Bool {
        let left = signals[ARFaceAnchor.BlendShapeLocation.eyeBlinkLeft.rawValue] ?? 0
        let right = signals[ARFaceAnchor.BlendShapeLocation.eyeBlinkRight.rawValue] ?? 0
        return left < threshold && right < threshold
    }

    /// The eight eye-direction coefficients folded into one horizontal and one vertical
    /// term, each in roughly -1...1.
    ///
    /// "In" means towards the nose, so for the two eyes it points in opposite directions
    /// and the signs below make the two agree. Whether the result comes out positive to
    /// the participant's left or right does not matter: the calibration fits a sign along
    /// with everything else.
    public static func eyeLookTerms(in signals: [String: Double]) -> (u: Double, v: Double) {
        func value(_ location: ARFaceAnchor.BlendShapeLocation) -> Double {
            signals[location.rawValue] ?? 0
        }
        let horizontal = (value(.eyeLookInLeft) - value(.eyeLookOutLeft))
            + (value(.eyeLookOutRight) - value(.eyeLookInRight))
        let vertical = (value(.eyeLookUpLeft) - value(.eyeLookDownLeft))
            + (value(.eyeLookUpRight) - value(.eyeLookDownRight))
        return (horizontal / 2, vertical / 2)
    }
}
