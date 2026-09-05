import CoreGraphics

/// Physical geometry of the display, in metres, expressed in ARKit camera space.
///
/// Gaze is computed by intersecting a ray with the plane of the screen, so the screen's
/// real size and its position relative to the front camera are needed. iOS does not
/// expose pixel density, so it is derived from the display scale. Every Face ID iPhone
/// is 460 ppi at 3x and 326 ppi at 2x, which makes the rule reliable for the devices
/// this study runs on.
///
/// These are estimates. They give a usable uncalibrated dot; `GazeCalibration` is what
/// makes the mapping actually accurate for a given person and holding position.
public struct ScreenGeometry: Sendable, Equatable {

    /// Display size in points.
    public let pointSize: CGSize

    /// Display size in metres.
    public let physicalSize: CGSize

    /// Vertical distance in metres from the camera centre down to the top edge of the
    /// display. Positive. On Face ID iPhones the camera sits within the sensor housing
    /// just above the usable display area.
    public let cameraAboveScreenTop: Double

    public init(pointSize: CGSize, displayScale: Double, cameraAboveScreenTop: Double = 0.006) {
        self.pointSize = pointSize
        self.cameraAboveScreenTop = cameraAboveScreenTop

        let pixelsPerInch: Double = displayScale >= 2.5 ? 460 : 326
        let metresPerPixel = 0.0254 / pixelsPerInch
        self.physicalSize = CGSize(
            width: Double(pointSize.width) * displayScale * metresPerPixel,
            height: Double(pointSize.height) * displayScale * metresPerPixel
        )
    }

    /// Converts a point on the screen plane, in camera-space metres, to normalised
    /// screen coordinates with the origin at the top left and a range of 0...1.
    ///
    /// This is the uncalibrated fallback. The camera is assumed to sit centred above
    /// the display. `mirrorX` is true because the front camera's x axis runs opposite
    /// to the direction the user perceives.
    public func normalise(metres point: CGPoint, mirrorX: Bool = true) -> CGPoint {
        let width = Double(physicalSize.width)
        let height = Double(physicalSize.height)
        guard width > 0, height > 0 else { return .zero }

        var x = (Double(point.x) + width / 2) / width
        if mirrorX { x = 1 - x }

        // Camera space has +y up. The screen extends downwards from just below the camera.
        let y = (-Double(point.y) - cameraAboveScreenTop) / height

        return CGPoint(x: x, y: y)
    }
}
