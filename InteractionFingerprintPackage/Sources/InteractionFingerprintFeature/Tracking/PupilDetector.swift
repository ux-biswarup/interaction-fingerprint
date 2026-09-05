import ARKit
import CoreGraphics
import Foundation
import Vision

/// Where the pupil sits inside the eye opening, from Apple's Vision face landmarks.
///
/// This is the eye's rotation within the head observed directly: the pupil slides across
/// the opening as the eye turns, and the opening moves with the head, so the offset between
/// them is head-independent by construction. It is an alternative to ARKit's eye transforms,
/// which report that rotation at a fifth to a third of its true size
/// (`docs/product/10-MOTION-FUSION.md` §14). Whether this readout has a higher gain is the
/// experiment; it is recorded on every frame and offered to the calibration as its own
/// gaze source so the data can answer.
public struct PupilOffsets: Sendable, Equatable {
    /// Offset of the pupil from the centre of the eye opening, as a fraction of the
    /// opening's width, along the display's horizontal axis. Sign is a property of the
    /// camera image and is left for the calibration to fit.
    public let u: Double
    /// The same along the display's vertical axis.
    public let v: Double
    public let confidence: Double
    /// Time of the camera frame the landmarks were found in.
    public let timestamp: TimeInterval

    public init(u: Double, v: Double, confidence: Double, timestamp: TimeInterval) {
        self.u = u
        self.v = v
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

public enum PupilGeometry {

    /// Pupil position relative to the eye opening, normalised by the opening's width on
    /// both axes. Width rather than height for the vertical too, because the height of the
    /// opening changes with the eyelids and would put blink and squint into the gaze.
    nonisolated public static func offset(pupil: CGPoint, contour: [CGPoint]) -> (x: Double, y: Double)? {
        guard contour.count >= 4 else { return nil }
        let xs = contour.map(\.x), ys = contour.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let width = Double(maxX - minX)
        guard width > 1e-6 else { return nil }
        let centre = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        return (Double(pupil.x - centre.x) / width, Double(pupil.y - centre.y) / width)
    }

    /// Pairs the axes of the upright landmark image with the display frame.
    ///
    /// When the buffer had to be rotated a quarter turn to stand the face upright, the
    /// upright image's x runs across the screen. When it did not, the buffer's long axis,
    /// which is the phone's long axis, is the image's x and runs up the screen. Signs are
    /// not resolved here; the calibration fits them.
    nonisolated public static func displayPaired(
        x: Double, y: Double, quarterTurned: Bool
    ) -> (u: Double, v: Double) {
        quarterTurned ? (u: x, v: y) : (u: y, v: -x)
    }

    nonisolated static func isQuarterTurn(_ orientation: CGImagePropertyOrientation) -> Bool {
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored: true
        default: false
        }
    }
}

/// A camera buffer handed to the detector. `CVPixelBuffer` carries no Sendable annotation;
/// the buffer is never mutated and ARKit keeps it alive for the frame.
struct PixelBufferBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

/// Runs Vision's landmark detector off the main actor, one frame at a time.
actor PupilDetector {

    /// ARKit hands over the sensor's native landscape image and the front camera may be
    /// mirrored, and Vision needs the face roughly upright to find it. Rather than assume,
    /// the orientations are tried until one yields a face, and that one is kept.
    private static let candidates: [CGImagePropertyOrientation] = [
        .right, .leftMirrored, .left, .rightMirrored, .up, .upMirrored, .down, .downMirrored,
    ]

    private let request: VNDetectFaceLandmarksRequest
    private var orientation: CGImagePropertyOrientation?
    private var failuresSinceLock = 0

    init() {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        self.request = request
    }

    func detect(_ box: PixelBufferBox, timestamp: TimeInterval) -> PupilOffsets? {
        let orientations = orientation.map { [$0] } ?? Self.candidates
        for candidate in orientations {
            guard let face = detectFace(in: box.buffer, orientation: candidate) else { continue }
            if orientation == nil { orientation = candidate }
            failuresSinceLock = 0
            return offsets(from: face, buffer: box.buffer, orientation: candidate, timestamp: timestamp)
        }
        // The locked orientation may be wrong if the first face was a fluke; after a run of
        // misses, start searching again.
        failuresSinceLock += 1
        if failuresSinceLock > 30 { orientation = nil }
        return nil
    }

    private func detectFace(in buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> VNFaceObservation? {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first { $0.landmarks?.leftPupil != nil && $0.landmarks?.rightPupil != nil }
    }

    private func offsets(
        from face: VNFaceObservation,
        buffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        timestamp: TimeInterval
    ) -> PupilOffsets? {
        guard let landmarks = face.landmarks,
              let leftPupil = landmarks.leftPupil, let rightPupil = landmarks.rightPupil,
              let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye
        else { return nil }

        // Points come back in the upright image's pixel space; a quarter turn swaps the
        // buffer's width and height.
        let quarterTurned = PupilGeometry.isQuarterTurn(orientation)
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let size = quarterTurned ? CGSize(width: h, height: w) : CGSize(width: w, height: h)

        guard
            let lp = leftPupil.pointsInImage(imageSize: size).first,
            let rp = rightPupil.pointsInImage(imageSize: size).first,
            let left = PupilGeometry.offset(pupil: lp, contour: leftEye.pointsInImage(imageSize: size)),
            let right = PupilGeometry.offset(pupil: rp, contour: rightEye.pointsInImage(imageSize: size))
        else { return nil }

        let paired = PupilGeometry.displayPaired(
            x: (left.x + right.x) / 2, y: (left.y + right.y) / 2, quarterTurned: quarterTurned
        )
        return PupilOffsets(u: paired.u, v: paired.v, confidence: Double(landmarks.confidence), timestamp: timestamp)
    }
}
