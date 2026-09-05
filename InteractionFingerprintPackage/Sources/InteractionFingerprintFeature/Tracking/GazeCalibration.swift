import CoreGraphics
import Foundation
import simd

/// Maps raw screen-plane intersections, in metres, to normalised screen coordinates.
///
/// Every real eye tracker calibrates, and for good reason. The uncalibrated mapping
/// depends on estimated pixel density, on exactly where the camera sits relative to
/// the display, and on the person's eye geometry and holding distance. A per-person
/// affine fit absorbs all of that in one step, including the horizontal mirroring,
/// which appears naturally as a negative x coefficient rather than a manual toggle.
///
/// The fit is a full 2D affine rather than a per-axis scale so that it can also
/// correct the slight rotation and shear caused by holding the phone tilted.
public struct GazeCalibration: Codable, Sendable, Equatable {
    // normalisedX = ax * rawX + bx * rawY + cx
    public let ax: Double
    public let bx: Double
    public let cx: Double
    // normalisedY = ay * rawX + by * rawY + cy
    public let ay: Double
    public let by: Double
    public let cy: Double

    /// Fit quality, in screen points, measured on the calibration targets themselves.
    public let meanResidualPoints: Double
    public let maxResidualPoints: Double
    public let targetCount: Int
    public let createdAt: Date

    public func apply(to raw: CGPoint) -> CGPoint {
        CGPoint(
            x: ax * Double(raw.x) + bx * Double(raw.y) + cx,
            y: ay * Double(raw.x) + by * Double(raw.y) + cy
        )
    }

    /// A rough quality verdict for the debug UI. The thresholds are deliberately
    /// generous: TrueDepth gaze is a coarse signal and areas of interest are sized
    /// to match.
    public var qualityDescription: String {
        switch meanResidualPoints {
        case ..<40: "good"
        case ..<80: "usable"
        default: "poor, recalibrate"
        }
    }
}

/// Least-squares fit of the calibration transform.
public enum GazeCalibrationFitter {

    public struct Observation: Sendable, Equatable {
        /// Screen-plane intersection in camera-space metres.
        public let raw: CGPoint
        /// Where the target actually was, normalised 0...1.
        public let target: CGPoint

        public init(raw: CGPoint, target: CGPoint) {
            self.raw = raw
            self.target = target
        }
    }

    /// Needs at least three non-collinear observations; nine is what the calibration
    /// screen collects.
    public static func fit(_ observations: [Observation], screenPointSize: CGSize) -> GazeCalibration? {
        guard observations.count >= 3 else { return nil }

        guard
            let xCoefficients = solve(observations, value: { Double($0.target.x) }),
            let yCoefficients = solve(observations, value: { Double($0.target.y) })
        else { return nil }

        var total = 0.0
        var worst = 0.0
        for observation in observations {
            let predictedX = xCoefficients.0 * Double(observation.raw.x)
                + xCoefficients.1 * Double(observation.raw.y) + xCoefficients.2
            let predictedY = yCoefficients.0 * Double(observation.raw.x)
                + yCoefficients.1 * Double(observation.raw.y) + yCoefficients.2

            let dx = (predictedX - Double(observation.target.x)) * Double(screenPointSize.width)
            let dy = (predictedY - Double(observation.target.y)) * Double(screenPointSize.height)
            let error = (dx * dx + dy * dy).squareRoot()

            total += error
            worst = max(worst, error)
        }

        return GazeCalibration(
            ax: xCoefficients.0, bx: xCoefficients.1, cx: xCoefficients.2,
            ay: yCoefficients.0, by: yCoefficients.1, cy: yCoefficients.2,
            meanResidualPoints: total / Double(observations.count),
            maxResidualPoints: worst,
            targetCount: observations.count,
            createdAt: Date()
        )
    }

    /// Solves the 3x3 normal equations for one output axis.
    private static func solve(
        _ observations: [Observation],
        value: (Observation) -> Double
    ) -> (Double, Double, Double)? {
        var sumXX = 0.0, sumXY = 0.0, sumX = 0.0
        var sumYY = 0.0, sumY = 0.0
        var sumXU = 0.0, sumYU = 0.0, sumU = 0.0
        let count = Double(observations.count)

        for observation in observations {
            let x = Double(observation.raw.x)
            let y = Double(observation.raw.y)
            let u = value(observation)
            sumXX += x * x
            sumXY += x * y
            sumX += x
            sumYY += y * y
            sumY += y
            sumXU += x * u
            sumYU += y * u
            sumU += u
        }

        // Symmetric, so columns and rows are interchangeable here.
        let matrix = simd_double3x3(
            SIMD3(sumXX, sumXY, sumX),
            SIMD3(sumXY, sumYY, sumY),
            SIMD3(sumX, sumY, count)
        )

        // A near-singular matrix means the targets were effectively collinear,
        // usually because tracking failed on most of them.
        guard abs(matrix.determinant) > 1e-12 else { return nil }

        let solution = matrix.inverse * SIMD3(sumXU, sumYU, sumU)
        guard solution.x.isFinite, solution.y.isFinite, solution.z.isFinite else { return nil }

        return (solution.x, solution.y, solution.z)
    }
}

/// Persists the calibration between launches so a participant is not recalibrated
/// for every build. Storage moves into the session database with the storage milestone.
public enum GazeCalibrationStore {
    private static let key = "interactionFingerprint.gazeCalibration.v1"

    public static func load(from defaults: UserDefaults = .standard) -> GazeCalibration? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(GazeCalibration.self, from: data)
    }

    public static func save(_ calibration: GazeCalibration, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(calibration) else { return }
        defaults.set(data, forKey: key)
    }

    public static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
