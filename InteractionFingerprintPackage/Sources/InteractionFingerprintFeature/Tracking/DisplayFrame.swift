import simd

/// The rotation from ARKit's camera frame into the display frame.
///
/// Apple documents that ARKit's camera coordinate system follows the sensor's native
/// landscape orientation: "the x-axis always points along the long axis of the device,
/// even if that direction is 'down' relative to the user." Every earlier version of this
/// tracker treated that frame as if x ran across the screen. The linear calibration
/// absorbed the rotation of the gaze *angles*, which is why anything worked at all, but
/// the eye *position* entered unrotated, and that is what broke the two-distance geometry
/// and sent a whole recording off the screen when the phone was held a few centimetres to
/// one side.
///
/// The convention here was not taken from documentation. It was chosen from data: all
/// eight signed axis mappings were fitted to an exported calibration, and this one won on
/// held-out error, 49 points against 105 to 133 for the others, with the eye gains landing
/// on the matched axes. See `docs/product/10-MOTION-FUSION.md` section 11.
///
///     display X (participant's right) =  camera y
///     display Y (up the screen)       = -camera x
///     display Z (towards the phone)   =  camera z
public enum DisplayFrame {

    /// Rotation by -90° about z. A proper rotation, determinant +1; no mirror is involved.
    public static let fromCamera = simd_float4x4(
        SIMD4<Float>(0, -1, 0, 0),
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(0, 0, 0, 1)
    )

    /// A pose in the camera frame re-expressed in the display frame.
    public static func transform(_ poseInCamera: simd_float4x4) -> simd_float4x4 {
        simd_mul(fromCamera, poseInCamera)
    }

    /// A vector or point in the camera frame re-expressed in the display frame.
    public static func vector(_ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(v.y, -v.x, v.z)
    }
}
