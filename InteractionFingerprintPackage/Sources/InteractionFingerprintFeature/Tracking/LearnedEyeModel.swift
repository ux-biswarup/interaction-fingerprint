import CoreImage
import CoreML
import CoreVideo
import Foundation

/// Geometry of the eye crops the learned model was trained on, reproduced exactly.
///
/// `Analysis/eyemodel/gazecapture.py` `crop()`: a square around the eye box's centre, side
/// the larger of width and height widened by a quarter on each side, resized to 64 pixels.
/// Any difference here would feed the network something it has never seen.
public enum EyeCropGeometry {
    public static let size = 64
    public static let padding = 0.25

    nonisolated public static func squareCrop(around box: CGRect) -> CGRect {
        let side = max(box.width, box.height) * (1 + 2 * padding)
        return CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
    }

    nonisolated public static func bounds(of points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Cuts 64-pixel greyscale eye crops out of a camera image.
///
/// Core Image does the orientation, the crop and the resampling, and renders straight into
/// a one-component pixel buffer the model takes as an image input. Coordinates are Core
/// Image's, origin bottom left, which is also what Vision's `pointsInImage` returns, so an
/// eye contour from the landmark detector can be used as it is.
final class EyeCropper {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func crop(_ image: CIImage, eye box: CGRect) -> CVPixelBuffer? {
        let square = EyeCropGeometry.squareCrop(around: box)
        let size = EyeCropGeometry.size
        guard square.width > 1 else { return nil }
        let scale = CGFloat(size) / square.width
        let transformed = image
            .cropped(to: square)
            .transformed(by: CGAffineTransform(translationX: -square.minX, y: -square.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_OneComponent8, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        context.render(
            transformed, to: buffer,
            bounds: CGRect(x: 0, y: 0, width: size, height: size),
            colorSpace: CGColorSpaceCreateDeviceGray()
        )
        return buffer
    }
}

/// The learned eye-in-head estimator, a Core ML model bundled with the package.
///
/// Two eye crops and the head's forward direction in, the eyes' rotation within the head
/// out, as ratios in the same units as every other gaze quantity here. The crop named
/// `leftEye` is the eye on the left of the camera image, as in training.
final class LearnedEyeModel {
    private let model: MLModel

    init?() {
        guard let url = Bundle.module.url(forResource: "EyeInHead", withExtension: "mlmodelc") else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let model = try? MLModel(contentsOf: url, configuration: configuration) else { return nil }
        self.model = model
    }

    /// Eye-in-head ratios, or nil if the model could not run on these inputs.
    func predict(leftEye: CVPixelBuffer, rightEye: CVPixelBuffer, headU: Double, headV: Double) -> (u: Double, v: Double)? {
        guard let head = try? MLMultiArray(shape: [1, 2], dataType: .float32) else { return nil }
        head[0] = NSNumber(value: Float(headU))
        head[1] = NSNumber(value: Float(headV))
        guard let input = try? MLDictionaryFeatureProvider(dictionary: [
            "leftEye": MLFeatureValue(pixelBuffer: leftEye),
            "rightEye": MLFeatureValue(pixelBuffer: rightEye),
            "head": MLFeatureValue(multiArray: head),
        ]) else { return nil }
        guard let output = try? model.prediction(from: input),
              let array = output.featureValue(for: "eyeInHead")?.multiArrayValue,
              array.count >= 2 else { return nil }
        let u = array[0].doubleValue, v = array[1].doubleValue
        guard u.isFinite, v.isFinite else { return nil }
        return (u, v)
    }
}
