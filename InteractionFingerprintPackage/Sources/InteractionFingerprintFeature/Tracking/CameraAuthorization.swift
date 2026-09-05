import AVFoundation

/// Camera permission handling.
///
/// ARKit would prompt implicitly on the first `session.run`, but that gives no
/// control over timing. Requesting explicitly lets the app show the study
/// explanation before the system dialog appears.
/// See `.claude/skills/ios-camera-privacy`.
public enum CameraAuthorization {
    public static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    public static var isAuthorized: Bool { status == .authorized }

    /// Returns true when access is granted. Never prompts twice; once denied,
    /// only Settings can change the answer.
    public static func request() async -> Bool {
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    public static var statusDescription: String {
        switch status {
        case .authorized: "Camera access granted"
        case .notDetermined: "Camera access not requested yet"
        case .denied: "Camera access denied. Enable it in Settings."
        case .restricted: "Camera access restricted by device policy."
        @unknown default: "Camera access state unknown"
        }
    }
}
