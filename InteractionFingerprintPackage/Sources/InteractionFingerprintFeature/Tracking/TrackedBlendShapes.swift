import ARKit

/// The blend shapes recorded in V0.
///
/// ARKit exposes more than fifty coefficients. The setup guide deliberately starts
/// with a small, hypothesis-driven subset rather than recording everything, so the
/// dataset stays small and every column has a stated reason to exist.
/// See `docs/INTERACTION_FINGERPRINT_XCODE_SETUP.md` section 7.
public enum TrackedBlendShapes {
    public static let all: [ARFaceAnchor.BlendShapeLocation] = [
        .eyeBlinkLeft, .eyeBlinkRight,
        .eyeSquintLeft, .eyeSquintRight,
        .eyeWideLeft, .eyeWideRight,
        .browInnerUp, .browOuterUpLeft, .browOuterUpRight,
    ]

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
    public static let keys: [String] = all.map(\.rawValue)
}
