import CoreGraphics

/// Physical geometry of the display, in metres, expressed in ARKit camera space.
///
/// Camera space has its origin at the front camera, +x to the right of the captured
/// image, +y up, and the camera looking along -z. The captured front-camera image is not
/// mirrored, so a point on the user's right appears at negative x. The screen therefore
/// runs in the opposite direction to the way the user reads it, which is why the
/// conversions below flip x.
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

    /// Vertical distance in metres from the camera centre down to the top edge of the
    /// display. On Face ID iPhones the camera sits in the sensor housing just above the
    /// usable display area.
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

    /// Screen position, normalised with the origin at the top left, to camera-space metres.
    public func cameraMetres(fromNormalised point: CGPoint) -> CGPoint {
        CGPoint(
            x: (0.5 - Double(point.x)) * Double(physicalSize.width),
            y: -(cameraAboveScreenTop + Double(point.y) * Double(physicalSize.height))
        )
    }

    /// Camera-space metres back to normalised screen position.
    public func normalised(fromCameraMetres point: CGPoint) -> CGPoint {
        let width = Double(physicalSize.width)
        let height = Double(physicalSize.height)
        guard width > 0, height > 0 else { return .zero }
        return CGPoint(
            x: 0.5 - Double(point.x) / width,
            y: (-Double(point.y) - cameraAboveScreenTop) / height
        )
    }
}
