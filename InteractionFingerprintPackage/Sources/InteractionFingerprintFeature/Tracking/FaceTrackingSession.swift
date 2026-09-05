import ARKit
import CoreGraphics
import Foundation
import Observation
import simd

/// Runs `ARFaceTrackingConfiguration` and turns each frame into a `FaceSample`.
///
/// Gaze is measured as an **angle** and only becomes a screen position at the last step,
/// by projecting from the eye position measured on that same frame. That ordering is what
/// keeps the mapping valid when the phone moves: a person's dominant gaze error is a fixed
/// angular offset, and an angle reaches the screen scaled by however far away the phone
/// happens to be.
///
/// Threading: `ARSession` delivers frames on `delegateQueue`, pinned here to the main
/// queue, so all published state is main-actor isolated and safe to read from SwiftUI.
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
    public private(set) var latest: FaceSample?
    public private(set) var quality: GazeQuality = .noFace

    /// Smoothed gaze for drawing only, normalised 0...1. Nil when the frame is not usable.
    public private(set) var displayGaze: CGPoint?

    public private(set) var frameCount: Int = 0
    public private(set) var trackedFrameCount: Int = 0
    public private(set) var measuredHz: Double = 0

    /// Device rotation rate in radians per second, from the gyroscope. A covariate.
    public var deviceRotationRate: Double { motion.rotationRate }
    /// False while the screen has recently moved further under the eyes than the tracker
    /// can absorb. See `MotionGate`.
    public var deviceIsSteady: Bool { gate.isSteady }
    /// How far the screen moved under the eyes over the last reaction window, in metres.
    public var motionDisturbance: Double { gate.disturbance }
    /// How the phone is being held right now.
    public var deviceAttitude: DeviceAttitude {
        DeviceAttitude(
            tilt: motion.tilt, roll: motion.roll,
            rotationRate: motion.rotationRate, disturbance: gate.disturbance
        )
    }

    /// Ambient light, in lumens, and its colour temperature in kelvin. Recorded as a
    /// covariate rather than a signal.
    public private(set) var ambientIntensity: Double = 0
    public private(set) var ambientColourTemperature: Double = 0

    /// Latest raw measurements, for the calibration run to bank.
    public private(set) var latestCalibrationSample: GazeCalibrationRun.Sample?

    public var trackedShare: Double {
        frameCount == 0 ? 0 : Double(trackedFrameCount) / Double(frameCount)
    }

    // MARK: Configuration

    public var model: GazeModel?
    public private(set) var screenGeometry: ScreenGeometry?

    // MARK: Private

    private let session = ARSession()
    private let proxy = ARSessionProxy()
    private let motion = DeviceMotionMonitor()
    private var gate = MotionGate()
    private var horizontalFilter = OneEuroFilter()
    private var verticalFilter = OneEuroFilter()
    private var hzWindowStart: TimeInterval = 0
    private var hzWindowFrames: Int = 0

    public init(model: GazeModel? = GazeModelStore.load()) {
        self.model = model
        proxy.onFrame = { [weak self] frame in self?.handle(frame) }
        proxy.onFailure = { [weak self] error in
            self?.state = .failed(error.localizedDescription)
        }
        session.delegateQueue = .main
        session.delegate = proxy
    }

    // MARK: Control

    /// Supplied by the view. Reading size and scale from the view avoids the deprecated
    /// `UIScreen.main` and keeps the geometry right on any device.
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
        latestCalibrationSample = nil
        horizontalFilter.reset()
        verticalFilter.reset()
        gate.reset()

        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1
        // Gravity alignment switches ARKit's own device motion tracking on. Under `.camera`
        // alignment Apple documents that "ARKit performs no device motion tracking" at all,
        // so the face tracker would run with no knowledge of the phone turning. The gaze
        // geometry below is computed relative to the camera on every frame and is unaffected
        // by the choice; what changes is that ARKit now works in a frame where the head is
        // still and the phone is the thing moving, which is the truth.
        // See docs/product/10-MOTION-FUSION.md section 3.
        configuration.worldAlignment = .gravity
        // Ambient light is cheap to collect and explains variance that would otherwise
        // look like a difference between participants: pupil size and tracking reliability
        // both depend on how bright the room is.
        configuration.isLightEstimationEnabled = true

        motion.start()
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        state = .running
    }

    public func stop() {
        guard state == .running else { return }
        session.pause()
        motion.stop()
        state = .idle
        displayGaze = nil
    }

    // MARK: Frame handling

    private func handle(_ frame: ARFrame) {
        frameCount += 1
        updateRate(with: frame.timestamp)

        if let light = frame.lightEstimate {
            ambientIntensity = light.ambientIntensity
            ambientColourTemperature = light.ambientColorTemperature
        }

        guard
            let anchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first,
            anchor.isTracked
        else {
            gate.update(netRotation: motion.netRotation, acceleration: motion.acceleration, distance: nil)
            quality = .noFace
            latestCalibrationSample = nil
            latest = untrackedSample(at: frame.timestamp)
            displayGaze = nil
            return
        }

        trackedFrameCount += 1

        let signals = Self.signals(from: anchor)
        let eyesOpen = TrackedBlendShapes.eyesOpen(in: signals)
        let look = TrackedBlendShapes.eyeLookTerms(in: signals)
        let faceInCamera = simd_mul(simd_inverse(frame.camera.transform), anchor.transform)
        let head = Self.headPose(from: faceInCamera)

        let convergence = GazeRay.convergenceEstimate(
            faceInCamera: faceInCamera,
            leftEye: anchor.leftEyeTransform,
            rightEye: anchor.rightEyeTransform,
            lookAtPoint: anchor.lookAtPoint
        )
        let perEye = GazeRay.perEyeEstimate(
            faceInCamera: faceInCamera,
            leftEye: anchor.leftEyeTransform,
            rightEye: anchor.rightEyeTransform,
            lookAtPoint: anchor.lookAtPoint
        )

        let convergenceMeasurement = convergence.flatMap {
            GazeMeasurement($0, headYaw: head.yaw, headPitch: head.pitch, lookU: look.u, lookV: look.v)
        }
        let perEyeMeasurement = perEye.flatMap {
            GazeMeasurement($0, headYaw: head.yaw, headPitch: head.pitch, lookU: look.u, lookV: look.v)
        }
        let reference = convergenceMeasurement ?? perEyeMeasurement

        // The motion verdict is made in millimetres on the screen, which needs the viewing
        // distance measured on this very frame.
        gate.update(
            netRotation: motion.netRotation,
            acceleration: motion.acceleration,
            distance: reference?.distance
        )

        quality = GazeQuality.evaluate(
            isTracked: true,
            eyesOpen: eyesOpen,
            distance: reference?.distance,
            headRotation: head.offAxisRotation,
            deviceIsSteady: gate.isSteady,
            model: model
        )

        latestCalibrationSample = GazeCalibrationRun.Sample(
            convergence: convergenceMeasurement,
            perEye: perEyeMeasurement,
            headYaw: head.yaw,
            headPitch: head.pitch
        )

        let normalised = mapToScreen(
            convergence: convergenceMeasurement,
            perEye: perEyeMeasurement
        )

        latest = FaceSample(
            timestamp: frame.timestamp,
            isTracked: true,
            eyesOpen: eyesOpen,
            quality: Self.qualityCode(quality),
            eyeX: reference.map(\.eyeX),
            eyeY: reference.map(\.eyeY),
            eyeZ: reference.map { -$0.distance },
            convergenceU: convergenceMeasurement?.u,
            convergenceV: convergenceMeasurement?.v,
            perEyeU: perEyeMeasurement?.u,
            perEyeV: perEyeMeasurement?.v,
            gazeX: normalised.map { Double($0.x) },
            gazeY: normalised.map { Double($0.y) },
            isCalibrated: model != nil,
            signals: signals,
            head: head,
            device: motion.isAvailable ? deviceAttitude : nil
        )

        // What counts as data and what should be drawn are different questions.
        //
        // During a blink the estimate is meaningless and would fling the dot across the
        // screen, so drawing stops. Every other verdict, including the phone being moved,
        // is a fact about the data and not about the drawing: the dot keeps the same filter
        // and the same appearance throughout, because a dot that changes character every
        // time a threshold is crossed reads as instability even when the estimate is fine.
        guard shouldDraw(quality), let normalised else { return }

        displayGaze = CGPoint(
            x: horizontalFilter.filter(Double(normalised.x), timestamp: frame.timestamp),
            y: verticalFilter.filter(Double(normalised.y), timestamp: frame.timestamp)
        )
    }

    private func shouldDraw(_ quality: GazeQuality) -> Bool {
        switch quality {
        case .noFace, .blinking: false
        default: true
        }
    }

    private func untrackedSample(at timestamp: TimeInterval) -> FaceSample {
        FaceSample(
            timestamp: timestamp,
            isTracked: false,
            eyesOpen: false,
            quality: Self.qualityCode(.noFace),
            eyeX: nil, eyeY: nil, eyeZ: nil,
            convergenceU: nil, convergenceV: nil,
            perEyeU: nil, perEyeV: nil,
            gazeX: nil, gazeY: nil,
            isCalibrated: model != nil,
            signals: [:],
            head: nil,
            device: motion.isAvailable ? deviceAttitude : nil
        )
    }

    /// Applies the fitted angular correction, then projects using this frame's eye
    /// position. Falls back to the uncorrected geometry when nothing has been fitted.
    private func mapToScreen(
        convergence: GazeMeasurement?,
        perEye: GazeMeasurement?
    ) -> CGPoint? {
        guard let geometry = screenGeometry else { return nil }

        if let model {
            let measurement = model.source == .perEye ? perEye : convergence
            guard let measurement else { return nil }
            return geometry.normalised(fromCameraMetres: model.screenPlaneHit(for: measurement))
        }

        guard let measurement = convergence ?? perEye else { return nil }
        let hit = CGPoint(
            x: measurement.eyeX + measurement.distance * measurement.u,
            y: measurement.eyeY + measurement.distance * measurement.v
        )
        return geometry.normalised(fromCameraMetres: hit)
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

    static func qualityCode(_ quality: GazeQuality) -> String {
        switch quality {
        case .good: "good"
        case .noFace: "no_face"
        case .blinking: "blink"
        case .tooClose: "too_close"
        case .tooFar: "too_far"
        case .headTurned: "head_turned"
        case .deviceMoving: "device_moving"
        case .notCalibrated: "not_calibrated"
        case .outsideCalibratedRange: "outside_calibrated_range"
        }
    }

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

    /// Standard quaternion to intrinsic Euler conversion, about the x, y and z axes.
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
