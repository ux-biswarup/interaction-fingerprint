import ARKit
import Foundation
import Observation
import simd

/// Runs `ARFaceTrackingConfiguration` and turns each frame into a `FaceSample`.
///
/// This is a deliberately thin wrapper. It starts a headless `ARSession`, reads the
/// `ARFaceAnchor`, projects the gaze estimate into viewport coordinates and publishes
/// the result. It stores nothing; persistence arrives with the storage milestone.
///
/// Threading: `ARSession` delivers frames on `delegateQueue`, which is pinned to the
/// main queue here, so all published state is main-actor isolated and safe to read
/// directly from SwiftUI.
///
/// Note on accuracy: `lookAtPoint` is an eye-convergence estimate derived from the
/// face model, not a pupil tracker. Expect a few centimetres of error. Areas of
/// interest must be sized accordingly. See `.claude/skills/eye-tracking-concepts`.
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

    /// The most recent frame's measurements, raw and unsmoothed.
    public private(set) var latest: FaceSample?

    /// Total frames received since the session started.
    public private(set) var frameCount: Int = 0

    /// Frames in which ARKit reported the face as tracked.
    public private(set) var trackedFrameCount: Int = 0

    /// Measured delivery rate, refreshed about once a second. Expect roughly 60.
    public private(set) var measuredHz: Double = 0

    /// Smoothed gaze for display only. The dot is jittery without this; the recorded
    /// `latest.gazeX/gazeY` stay raw so analysis is not silently filtered.
    public private(set) var smoothedGaze: CGPoint?

    /// Share of frames since start where the face was tracked, 0...1.
    public var trackedShare: Double {
        frameCount == 0 ? 0 : Double(trackedFrameCount) / Double(frameCount)
    }

    // MARK: Tuning

    /// The front camera image is mirrored relative to what the user sees. Whether the
    /// projection needs flipping is easiest to confirm by looking at the debug dot on a
    /// real device, so this is exposed as a toggle rather than hard-coded.
    public var mirrorHorizontally: Bool = false

    /// Display smoothing strength, 0 = no smoothing, approaching 1 = very heavy.
    public var smoothingFactor: Double = 0.75

    // MARK: Private

    private let session = ARSession()
    private let proxy = ARSessionProxy()
    private var viewportSize: CGSize = .zero
    private var hzWindowStart: TimeInterval = 0
    private var hzWindowFrames: Int = 0

    public init() {
        proxy.onFrame = { [weak self] frame in self?.handle(frame) }
        proxy.onFailure = { [weak self] error in
            self?.state = .failed(error.localizedDescription)
        }
        session.delegateQueue = .main
        session.delegate = proxy
    }

    // MARK: Control

    /// Viewport in points, supplied by the view. Projection needs it, and reading it
    /// from the view avoids the deprecated `UIScreen.main`.
    public func updateViewport(_ size: CGSize) {
        viewportSize = size
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
        smoothedGaze = nil
        latest = nil

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

        guard let anchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first else {
            latest = FaceSample(
                timestamp: frame.timestamp,
                isTracked: false,
                gazeX: nil,
                gazeY: nil,
                signals: [:],
                head: nil
            )
            return
        }

        guard anchor.isTracked else {
            latest = FaceSample(
                timestamp: frame.timestamp,
                isTracked: false,
                gazeX: nil,
                gazeY: nil,
                signals: Self.signals(from: anchor),
                head: nil
            )
            return
        }

        trackedFrameCount += 1

        let gaze = projectGaze(anchor: anchor, camera: frame.camera)

        latest = FaceSample(
            timestamp: frame.timestamp,
            isTracked: true,
            gazeX: gaze.map { Double($0.x) },
            gazeY: gaze.map { Double($0.y) },
            signals: Self.signals(from: anchor),
            head: Self.headPose(from: anchor.transform)
        )

        if let gaze {
            smoothedGaze = smooth(gaze)
        }
    }

    /// Projects the eye convergence point onto the viewport and normalises it to 0...1.
    private func projectGaze(anchor: ARFaceAnchor, camera: ARCamera) -> CGPoint? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }

        // lookAtPoint is in face-anchor space; lift it into world space.
        let world = anchor.transform * SIMD4<Float>(anchor.lookAtPoint, 1)

        let projected = camera.projectPoint(
            SIMD3<Float>(world.x, world.y, world.z),
            orientation: .portrait,
            viewportSize: viewportSize
        )

        guard projected.x.isFinite, projected.y.isFinite else { return nil }

        var normalisedX = projected.x / viewportSize.width
        let normalisedY = projected.y / viewportSize.height
        if mirrorHorizontally { normalisedX = 1 - normalisedX }

        return CGPoint(x: normalisedX, y: normalisedY)
    }

    private func smooth(_ point: CGPoint) -> CGPoint {
        guard let previous = smoothedGaze else { return point }
        let a = smoothingFactor
        return CGPoint(
            x: previous.x * a + point.x * (1 - a),
            y: previous.y * a + point.y * (1 - a)
        )
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
        let quaternion = simd_quatf(transform)
        let angles = eulerAngles(from: quaternion)
        return HeadPose(
            x: Double(translation.x),
            y: Double(translation.y),
            z: Double(translation.z),
            pitch: Double(angles.pitch),
            yaw: Double(angles.yaw),
            roll: Double(angles.roll)
        )
    }

    /// Standard quaternion to intrinsic Euler conversion. `pitch`, `yaw` and `roll`
    /// are rotations about the anchor's x, y and z axes.
    private static func eulerAngles(from q: simd_quatf) -> (pitch: Float, yaw: Float, roll: Float) {
        let w = q.real, x = q.imag.x, y = q.imag.y, z = q.imag.z

        let sinPitch = 2 * (w * x + y * z)
        let cosPitch = 1 - 2 * (x * x + y * y)
        let pitch = atan2(sinPitch, cosPitch)

        let sinYaw = 2 * (w * y - z * x)
        let yaw = abs(sinYaw) >= 1
            ? Float(copysign(Double.pi / 2, Double(sinYaw)))
            : asin(sinYaw)

        let sinRoll = 2 * (w * z + x * y)
        let cosRoll = 1 - 2 * (y * y + z * z)
        let roll = atan2(sinRoll, cosRoll)

        return (pitch, yaw, roll)
    }
}

/// Keeps `ARSessionDelegate` conformance off the observable class.
///
/// `@preconcurrency` is required because `ARSessionDelegate` carries no isolation,
/// while this proxy is main-actor isolated. That pairing is sound only because
/// `delegateQueue` is pinned to the main queue in `FaceTrackingSession.init`.
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
