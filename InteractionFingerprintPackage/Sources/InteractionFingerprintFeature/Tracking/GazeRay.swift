import CoreGraphics
import simd

/// Pure geometry turning a tracked face into a gaze ray, expressed so that the
/// person-specific part of the error can be corrected independently of where the phone
/// happens to be.
///
/// The ray is reported as an eye position plus a pair of **direction ratios**
/// `u = dx/dz` and `v = dy/dz`. Those ratios are the tangents of the horizontal and
/// vertical gaze angles. Working in angles rather than in landing positions is what makes
/// the system survive the phone moving: the dominant per-person error is angular, and an
/// angular error lands on the screen scaled by viewing distance.
public enum GazeRay {

    /// A gaze estimate in camera space.
    public struct Estimate: Equatable, Sendable {
        /// Eye position in metres. z is negative, in front of the camera.
        public let eye: SIMD3<Float>
        /// Horizontal direction ratio, dx/dz.
        public let u: Double
        /// Vertical direction ratio, dy/dz.
        public let v: Double

        public init(eye: SIMD3<Float>, u: Double, v: Double) {
            self.eye = eye
            self.u = u
            self.v = v
        }

        /// Distance from the camera to the eyes, in metres. Always positive.
        public var viewingDistance: Double { Double(-eye.z) }

        /// Where this estimate lands on the plane of the display, in camera-space metres.
        ///
        /// Applying the angles to the *current* eye position is the step that makes the
        /// result independent of how far away the phone is being held.
        public func screenPlaneHit(uOverride: Double? = nil, vOverride: Double? = nil) -> CGPoint? {
            let distance = viewingDistance
            guard distance > 0.05, distance < 2.0 else { return nil }
            let x = Double(eye.x) + distance * (uOverride ?? u)
            let y = Double(eye.y) + distance * (vOverride ?? v)
            guard x.isFinite, y.isFinite else { return nil }
            return CGPoint(x: x, y: y)
        }
    }

    /// Gaze from ARKit's convergence point, taken from the midpoint of the eyes.
    public static func convergenceEstimate(
        faceInCamera: simd_float4x4,
        leftEye: simd_float4x4,
        rightEye: simd_float4x4,
        lookAtPoint: SIMD3<Float>
    ) -> Estimate? {
        let midpointInFace = (leftEye.columns.3 + rightEye.columns.3) / 2
        let origin = point(faceInCamera * midpointInFace)
        let target = point(faceInCamera * SIMD4<Float>(lookAtPoint, 1))
        return estimate(from: origin, towards: target - origin)
    }

    /// Gaze from each eye's own orientation, averaged.
    ///
    /// Whether this beats the convergence estimate is an empirical question, so both are
    /// computed every frame and calibration picks the better one on held-out error.
    ///
    /// The forward axis of an eye transform is disambiguated at runtime rather than
    /// assumed: the sign is chosen so that it agrees with the direction of ARKit's own
    /// convergence point. That is a binary decision on a dot product that sits close to
    /// plus or minus one, so it is robust, and it removes a convention that is easy to
    /// get backwards.
    public static func perEyeEstimate(
        faceInCamera: simd_float4x4,
        leftEye: simd_float4x4,
        rightEye: simd_float4x4,
        lookAtPoint: SIMD3<Float>
    ) -> Estimate? {
        guard
            let left = singleEye(faceInCamera: faceInCamera, eye: leftEye, lookAtPoint: lookAtPoint),
            let right = singleEye(faceInCamera: faceInCamera, eye: rightEye, lookAtPoint: lookAtPoint)
        else { return nil }

        return Estimate(
            eye: (left.eye + right.eye) / 2,
            u: (left.u + right.u) / 2,
            v: (left.v + right.v) / 2
        )
    }

    private static func singleEye(
        faceInCamera: simd_float4x4,
        eye: simd_float4x4,
        lookAtPoint: SIMD3<Float>
    ) -> Estimate? {
        let positionInFace = point(eye.columns.3)
        let towardsTarget = lookAtPoint - positionInFace
        guard simd_length(towardsTarget) > 1e-6 else { return nil }

        let forwardAxis = simd_make_float3(eye.columns.2)
        guard simd_length(forwardAxis) > 1e-6 else { return nil }
        let signedAxis = simd_dot(simd_normalize(towardsTarget), simd_normalize(forwardAxis)) >= 0
            ? forwardAxis
            : -forwardAxis

        let rotation = simd_float3x3(
            simd_make_float3(faceInCamera.columns.0),
            simd_make_float3(faceInCamera.columns.1),
            simd_make_float3(faceInCamera.columns.2)
        )

        let origin = point(faceInCamera * SIMD4<Float>(positionInFace, 1))
        return estimate(from: origin, towards: rotation * signedAxis)
    }

    private static func estimate(from origin: SIMD3<Float>, towards direction: SIMD3<Float>) -> Estimate? {
        let length = simd_length(direction)
        guard length.isFinite, length > 1e-6 else { return nil }
        let unit = direction / length

        // The gaze has to travel back towards the device to land on the screen at all.
        guard Double(unit.z) > 1e-3 else { return nil }

        let u = Double(unit.x) / Double(unit.z)
        let v = Double(unit.y) / Double(unit.z)
        guard u.isFinite, v.isFinite, abs(u) < 10, abs(v) < 10 else { return nil }

        return Estimate(eye: origin, u: u, v: v)
    }

    private static func point(_ vector: SIMD4<Float>) -> SIMD3<Float> {
        SIMD3(vector.x, vector.y, vector.z)
    }
}
