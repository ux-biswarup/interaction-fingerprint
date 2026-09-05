import ARKit
import CoreGraphics
import Foundation
import Observation
import simd

/// Runs `ARFaceTrackingConfiguration` and turns each frame into a `FaceSample`.
///
/// Gaze is computed by casting a ray from the midpoint of the eyes through ARKit's
/// convergence estimate and intersecting it with the plane of the display. A fitted
/// `GazeCalibration` then maps that physical intersection to screen coordinates.
///
/// Threading: `ARSession` delivers frames on `delegateQueue`, pinned here to the main
/// queue, so all published state is main-actor isolated and safe to read from SwiftUI.
///
/// Accuracy: this is an eye-convergence estimate from a face model, not a pupil tracker.
/// Even calibrated, expect error of a centimetre or more. Areas of interest must be
/// sized accordingly. See `.claude/skills/eye-tracking-concepts`.
@MainActor
@Observable
public final class FaceTrackingSession {

    public enum State: Equatable {
        case idle
        case running
        case failed(String)
    }

    // MARK: Published state

    public private(set) var state: State = .idle

    /// The most recent frame's measurements, unfiltered.
    public private(set) var latest: FaceSample?

    /// Smoothed, calibrated gaze for drawing only, normalised 0...1. Nil while the face
    /// is untracked or the eyes are closed.
    public private(set) var displayGaze: CGPoint?

    public private(set) var frameCount: Int = 0
    public private(set) var trackedFrameCount: Int = 0

    /// Measured delivery rate, refreshed about once a second. Expect roughly 60.
    public private(set) var measuredHz: Double = 0

    /// Share of frames since start where the face was tracked, 0...1.
    public var trackedShare: Double {
        frameCount == 0 ? 0 : Double(trackedFrameCount) / Double(frameCount)
    }

    // MARK: Configuration

    /// Fitted mapping from screen-plane metres to normalised screen coordinates. When
    /// nil, the uncalibrated geometric fallback is used and samples are flagged as such.
    public var calibration: GazeCalibration?

    /// Physical display geometry, supplied by the view.
    public private(set) var screenGeometry: ScreenGeometry?

    // MARK: Private

    private let session = ARSession()
    private let proxy = ARSessionProxy()
    private var horizontalFilter = OneEuroFilter()
    private var verticalFilter = OneEuroFilter()
    private var hzWindowStart: TimeInterval = 0
    private var hzWindowFrames: Int = 0

    public init(calibration: GazeCalibration? = GazeCalibrationStore.load()) {
        self.calibration = calibration
        proxy.onFrame = { [weak self] frame in self?.handle(frame) }
        proxy.onFailure = { [weak self] error in
            self?.state = .failed(error.localizedDescription)
        }
        session.delegateQueue = .main
        session.delegate = proxy
    }

    // MARK: Control

    /// Supplied by the view. Reading the size and scale from the view avoids the
    /// deprecated `UIScreen.main` and keeps the geometry correct on any device.
    public func updateGeometry(pointSize: CGSize, displayScale: Double) {
        guard pointSize.width > 0, pointSize.height > 0 else { return }
        let updated = ScreenGeometry(pointSize: pointSize, displayScale: displayScale)
        if updated != screenGeometry { screenGeometry = updated }
    }

    public func start() {
        guard FaceTrackingSupport.isSupported else {
            state = .failed("Face tracking is not supported on this device.")
            return
        }
        guard state != .running else { return }

        frameCount = 0
        trackedFrameCount = 0
        hzWindowFrames = 0
        hzWindowStart = 0
        measuredHz = 0
        displayGaze = nil
        latest = nil
        horizontalFilter.reset()
        verticalFilter.reset()

        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1
        configuration.worldAlignment = .camera
        configuration.isLightEstimationEnabled = false

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        state = .running
    }

    public func stop() {
        guard state == .running else { return }
        session.pause()
        state = .idle
    }

    // MARK: Frame handling

    private func handle(_ frame: ARFrame) {
        frameCount += 1
        updateRate(with: frame.timestamp)

        guard
            let anchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first,
            anchor.isTracked
        else {
            latest = FaceSample(
                timestamp: frame.timestamp,
                isTracked: false,
                eyesOpen: false,
                rawGazeX: nil, rawGazeY: nil,
                gazeX: nil, gazeY: nil,
                isCalibrated: calibration != nil,
                signals: [:],
                head: nil
            )
            displayGaze = nil
            return
        }

        trackedFrameCount += 1

        let signals = Self.signals(from: anchor)
        let eyesOpen = TrackedBlendShapes.eyesOpen(in: signals)

        let faceInCamera = simd_mul(simd_inverse(frame.camera.transform), anchor.transform)
        let raw = GazeRay.ray(
            faceInCamera: faceInCamera,
            leftEye: anchor.leftEyeTransform,
            rightEye: anchor.rightEyeTransform,
            lookAtPoint: anchor.lookAtPoint
        ).flatMap(GazeRay.intersectScreenPlane)

        let normalised = raw.map(mapToScreen)

        latest = FaceSample(
            timestamp: frame.timestamp,
            isTracked: true,
            eyesOpen: eyesOpen,
            rawGazeX: raw.map { Double($0.x) },
            rawGazeY: raw.map { Double($0.y) },
            gazeX: normalised.map { Double($0.x) },
            gazeY: normalised.map { Double($0.y) },
            isCalibrated: calibration != nil,
            signals: signals,
            head: Self.headPose(from: anchor.transform)
        )

        // A blink would otherwise drag the drawn dot across the screen and back.
        guard eyesOpen, let normalised else {
            return
        }

        displayGaze = CGPoint(
            x: horizontalFilter.filter(Double(normalised.x), timestamp: frame.timestamp),
            y: verticalFilter.filter(Double(normalised.y), timestamp: frame.timestamp)
        )
    }

    /// Calibrated when a fit exists, otherwise the geometric estimate.
    private func mapToScreen(_ raw: CGPoint) -> CGPoint {
        if let calibration {
            return calibration.apply(to: raw)
        }
        return screenGeometry?.normalise(metres: raw) ?? .zero
    }

    private func updateRate(with timestamp: TimeInterval) {
        if hzWindowStart == 0 {
            hzWindowStart = timestamp
            hzWindowFrames = 0
            return
        }
        hzWindowFrames += 1
        let elapsed = timestamp - hzWindowStart
        if elapsed >= 1 {
            measuredHz = Double(hzWindowFrames) / elapsed
            hzWindowStart = timestamp
            hzWindowFrames = 0
        }
    }

    // MARK: Conversion helpers

    private static func signals(from anchor: ARFaceAnchor) -> [String: Double] {
        var result: [String: Double] = [:]
        result.reserveCapacity(TrackedBlendShapes.all.count)
        for location in TrackedBlendShapes.all {
            if let value = anchor.blendShapes[location] {
                result[location.rawValue] = value.doubleValue
            }
        }
        return result
    }

    private static func headPose(from transform: simd_float4x4) -> HeadPose {
        let translation = transform.columns.3
        let angles = eulerAngles(from: simd_quatf(transform))
        return HeadPose(
            x: Double(translation.x),
            y: Double(translation.y),
            z: Double(translation.z),
            pitch: Double(angles.pitch),
            yaw: Double(angles.yaw),
            roll: Double(angles.roll)
        )
    }

    /// Standard quaternion to intrinsic Euler conversion. `pitch`, `yaw` and `roll` are
    /// rotations about the anchor's x, y and z axes.
    private static func eulerAngles(from q: simd_quatf) -> (pitch: Float, yaw: Float, roll: Float) {
        let w = q.real, x = q.imag.x, y = q.imag.y, z = q.imag.z

        let pitch = atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y))

        let sinYaw = 2 * (w * y - z * x)
        let yaw = abs(sinYaw) >= 1
            ? Float(copysign(Double.pi / 2, Double(sinYaw)))
            : asin(sinYaw)

        let roll = atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))

        return (pitch, yaw, roll)
    }
}

/// Keeps `ARSessionDelegate` conformance off the observable class.
///
/// `@preconcurrency` is required because `ARSessionDelegate` carries no isolation while
/// this proxy is main-actor isolated. That pairing is sound only because `delegateQueue`
/// is pinned to the main queue in `FaceTrackingSession.init`.
@MainActor
private final class ARSessionProxy: NSObject, @preconcurrency ARSessionDelegate {
    var onFrame: ((ARFrame) -> Void)?
    var onFailure: ((Error) -> Void)?

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        onFrame?(frame)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onFailure?(error)
    }
}
