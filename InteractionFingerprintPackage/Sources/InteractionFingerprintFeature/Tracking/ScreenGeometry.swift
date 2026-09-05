import CoreGraphics

/// Physical geometry of the display, in metres, in the **display frame**.
///
/// The display frame has its origin at the front camera, +X to the participant's right
/// along the screen, +Y up the screen, and the participant in front at negative Z. It is
/// *not* ARKit's camera frame. ARKit's frame follows the sensor's landscape orientation,
/// with x along the long axis of the phone, and every measurement is rotated into the
/// display frame by `DisplayFrame` before it reaches this type. See that file for how the
/// convention was established from data rather than assumed.
///
/// iOS does not expose pixel density, so it is derived from the display scale. Every
/// Face ID iPhone is 460 ppi at 3x and 326 ppi at 2x, which makes the rule reliable for
/// the devices this study runs on.
///
/// These are fixed properties of the hardware. They are deliberately *not* fitted during
/// calibration: mixing device geometry into a per-person fit is what made the previous
/// version fall apart as soon as the phone moved.
public struct ScreenGeometry: Sendable, Equatable {

    public let pointSize: CGSize
    public let physicalSize: CGSize

    /// Nominal vertical distance in metres from the camera centre down to the top edge of
    /// the display.
    ///
    /// This is only a starting guess and is deliberately not trusted. On a Dynamic Island
    /// iPhone the camera sits *inside* the display area, a few millimetres below the top
    /// edge and offset horizontally, and the exact figure differs by model. Rather than
    /// carry a hardware table that will be wrong for the next phone, calibration solves
    /// for the true camera position as part of the fit. See `GazeBasis`.
    public let cameraAboveScreenTop: Double

    public init(pointSize: CGSize, displayScale: Double, cameraAboveScreenTop: Double = 0) {
        self.pointSize = pointSize
        self.cameraAboveScreenTop = cameraAboveScreenTop

        let pixelsPerInch: Double = displayScale >= 2.5 ? 460 : 326
        let metresPerPixel = 0.0254 / pixelsPerInch
        self.physicalSize = CGSize(
            width: Double(pointSize.width) * displayScale * metresPerPixel,
            height: Double(pointSize.height) * displayScale * metresPerPixel
        )
    }

    /// Screen position, normalised with the origin at the top left, to display-frame metres.
    public func cameraMetres(fromNormalised point: CGPoint) -> CGPoint {
        CGPoint(
            x: (Double(point.x) - 0.5) * Double(physicalSize.width),
            y: -(cameraAboveScreenTop + Double(point.y) * Double(physicalSize.height))
        )
    }

    /// Display-frame metres back to normalised screen position.
    public func normalised(fromCameraMetres point: CGPoint) -> CGPoint {
        let width = Double(physicalSize.width)
        let height = Double(physicalSize.height)
        guard width > 0, height > 0 else { return .zero }
        return CGPoint(
            x: 0.5 + Double(point.x) / width,
            y: (-Double(point.y) - cameraAboveScreenTop) / height
        )
    }
}
