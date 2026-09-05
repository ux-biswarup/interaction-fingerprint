import CoreGraphics
import simd

/// Pure geometry that turns a tracked face into a point on the plane of the screen.
///
/// Kept free of ARKit types and of any state so it can be tested on its own. The
/// previous implementation projected the convergence point into the camera *image*
/// plane, which is a different plane from the display and compresses the vertical
/// axis badly. Intersecting an actual ray with the screen plane fixes that.
public enum GazeRay {

    /// A ray expressed in ARKit camera space: origin at the camera, +x right,
    /// +y up, and the camera looking along -z.
    public struct Ray: Equatable, Sendable {
        public let origin: SIMD3<Float>
        /// Unit length.
        public let direction: SIMD3<Float>

        public init(origin: SIMD3<Float>, direction: SIMD3<Float>) {
            self.origin = origin
            self.direction = direction
        }
    }

    /// Builds the gaze ray in camera space.
    ///
    /// The origin is the midpoint between the two eyes and the direction points at
    /// ARKit's convergence estimate. Defining the direction by two points sidesteps
    /// the question of which axis of an eye transform ARKit treats as forward, a
    /// convention that is easy to get backwards. It also makes the result robust:
    /// because the ray is re-intersected with the screen plane, error in the
    /// convergence *distance* barely matters, and only the direction counts.
    ///
    /// - Parameters:
    ///   - faceInCamera: the face anchor transform expressed relative to the current camera.
    ///   - leftEye: left eye transform, relative to the face anchor.
    ///   - rightEye: right eye transform, relative to the face anchor.
    ///   - lookAtPoint: ARKit's convergence point, in face anchor space.
    public static func ray(
        faceInCamera: simd_float4x4,
        leftEye: simd_float4x4,
        rightEye: simd_float4x4,
        lookAtPoint: SIMD3<Float>
    ) -> Ray? {
        let midpointInFace = (leftEye.columns.3 + rightEye.columns.3) / 2

        let originHomogeneous = faceInCamera * midpointInFace
        let targetHomogeneous = faceInCamera * SIMD4<Float>(lookAtPoint, 1)

        let origin = SIMD3<Float>(originHomogeneous.x, originHomogeneous.y, originHomogeneous.z)
        let target = SIMD3<Float>(targetHomogeneous.x, targetHomogeneous.y, targetHomogeneous.z)

        let delta = target - origin
        let length = simd_length(delta)
        guard length.isFinite, length > 1e-6 else { return nil }

        return Ray(origin: origin, direction: delta / length)
    }

    /// Intersects the ray with the plane z = 0, which is the plane of the device
    /// screen in camera space.
    ///
    /// Returns the hit position in metres, or nil when the ray is parallel to the
    /// screen or travels away from it, which happens when the user looks past the
    /// edge of the device.
    public static func intersectScreenPlane(_ ray: Ray) -> CGPoint? {
        let dz = Double(ray.direction.z)
        guard abs(dz) > 1e-6 else { return nil }

        let t = -Double(ray.origin.z) / dz
        guard t.isFinite, t > 0 else { return nil }

        let x = Double(ray.origin.x) + Double(ray.direction.x) * t
        let y = Double(ray.origin.y) + Double(ray.direction.y) * t
        guard x.isFinite, y.isFinite else { return nil }

        return CGPoint(x: x, y: y)
    }
}
