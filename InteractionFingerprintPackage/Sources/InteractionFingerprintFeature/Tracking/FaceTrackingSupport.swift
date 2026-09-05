import ARKit
import EyeTracking

/// Runtime capability check for TrueDepth face tracking.
///
/// ARKit face tracking is unavailable in the iOS Simulator and on devices without Face ID.
/// Apple recommends checking `ARFaceTrackingConfiguration.isSupported` before starting a session.
public enum FaceTrackingSupport {
    /// `true` when this device can run `ARFaceTrackingConfiguration`.
    public static var isSupported: Bool {
        ARFaceTrackingConfiguration.isSupported
    }

    /// Human-readable status for the debug UI.
    public static var statusDescription: String {
        isSupported
            ? "Face tracking supported"
            : "Face tracking unavailable on this device (requires a Face ID iPhone; not available in Simulator)"
    }
}
