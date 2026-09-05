import CoreGraphics
import Foundation

/// Which of the two gaze estimates a model was fitted to.
public enum GazeSource: String, Codable, Sendable, CaseIterable {
    /// ARKit's convergence point, taken from the midpoint of the eyes.
    case convergence
    /// Each eye's own orientation, averaged.
    case perEye

    public var label: String {
        switch self {
        case .convergence: "convergence"
        case .perEye: "per-eye"
        }
    }
}

/// Shape of the angular correction.
public enum GazeBasis: String, Codable, Sendable, CaseIterable {
    /// 1, u, v. Corrects a constant angular offset plus scale, skew and mirroring.
    case affine
    /// 1, u, v, u², v², uv. Also corrects the mild curvature that shows up towards the
    /// edges of the display.
    case quadratic

    public var parameterCount: Int {
        switch self {
        case .affine: 3
        case .quadratic: 6
        }
    }

    public var label: String {
        switch self {
        case .affine: "linear"
        case .quadratic: "quadratic"
        }
    }

    func expand(u: Double, v: Double) -> [Double] {
        switch self {
        case .affine: [1, u, v]
        case .quadratic: [1, u, v, u * u, v * v, u * v]
        }
    }
}

/// One measured gaze direction, with the eye position it was measured from.
public struct GazeMeasurement: Sendable, Equatable {
    public let u: Double
    public let v: Double
    public let eyeX: Double
    public let eyeY: Double
    public let distance: Double

    public init(u: Double, v: Double, eyeX: Double, eyeY: Double, distance: Double) {
        self.u = u
        self.v = v
        self.eyeX = eyeX
        self.eyeY = eyeY
        self.distance = distance
    }

    public init?(_ estimate: GazeRay.Estimate) {
        let distance = estimate.viewingDistance
        guard distance > 0.05, distance < 2.0 else { return nil }
        self.init(
            u: estimate.u,
            v: estimate.v,
            eyeX: Double(estimate.eye.x),
            eyeY: Double(estimate.eye.y),
            distance: distance
        )
    }
}

/// What was captured while one calibration target was on screen.
public struct GazeCalibrationPoint: Sendable, Equatable {
    public let target: CGPoint
    public let convergence: GazeMeasurement?
    public let perEye: GazeMeasurement?
    public let headYaw: Double
    public let headPitch: Double

    public init(
        target: CGPoint,
        convergence: GazeMeasurement?,
        perEye: GazeMeasurement?,
        headYaw: Double,
        headPitch: Double
    ) {
        self.target = target
        self.convergence = convergence
        self.perEye = perEye
        self.headYaw = headYaw
        self.headPitch = headPitch
    }

    func measurement(for source: GazeSource) -> GazeMeasurement? {
        switch source {
        case .convergence: convergence
        case .perEye: perEye
        }
    }
}

/// A fitted correction from measured gaze angles to true gaze angles.
///
/// The correction is applied to the *angles*, never to the landing position. A person's
/// dominant gaze error is the offset between the eye's optical and visual axis, which is
/// an angle of roughly five degrees and is a fixed property of that person. An angle
/// lands on the screen scaled by viewing distance, so a correction learned as a distance
/// on the screen is only valid at the distance it was learned at. Correcting the angle
/// and then projecting with the eye position measured on the current frame is what lets
/// the phone be picked up, moved and held differently without the mapping falling apart.
public struct GazeModel: Codable, Sendable, Equatable {
    public let source: GazeSource
    public let basis: GazeBasis
    public let uCoefficients: [Double]
    public let vCoefficients: [Double]
    /// Tikhonov strength chosen by cross-validation. Zero means no shrinkage was needed.
    public let ridge: Double

    /// Mean error on targets held out of the fit, in screen points. This is the honest
    /// accuracy figure. Error measured on the same targets a model was fitted to always
    /// flatters it.
    public let heldOutErrorPoints: Double
    public let worstHeldOutErrorPoints: Double
    public let targetCount: Int

    /// Range of viewing distances seen during calibration, in metres. Used at runtime to
    /// tell the user when they have drifted outside what was actually measured.
    public let calibratedDistanceRange: ClosedRange<Double>

    /// Error measured in a separate pass at a deliberately different distance, in points.
    /// This is the direct test of whether the mapping survives the phone moving.
    public let distanceCheckErrorPoints: Double?
    public let distanceCheckDistance: Double?

    public let createdAt: Date

    public func correct(u: Double, v: Double) -> (u: Double, v: Double) {
        let terms = basis.expand(u: u, v: v)
        return (
            u: zip(terms, uCoefficients).reduce(0) { $0 + $1.0 * $1.1 },
            v: zip(terms, vCoefficients).reduce(0) { $0 + $1.0 * $1.1 }
        )
    }

    /// Where the corrected gaze lands, in camera-space metres.
    public func screenPlaneHit(for measurement: GazeMeasurement) -> CGPoint {
        let corrected = correct(u: measurement.u, v: measurement.v)
        return CGPoint(
            x: measurement.eyeX + measurement.distance * corrected.u,
            y: measurement.eyeY + measurement.distance * corrected.v
        )
    }

    public var accuracyDescription: String {
        switch heldOutErrorPoints {
        case ..<45: "good"
        case ..<90: "usable"
        default: "poor"
        }
    }

    public var summary: String {
        String(
            format: "%@ · %@%@ · ±%.0f pt",
            source.label,
            basis.label,
            ridge > 0 ? " · shrunk" : "",
            heldOutErrorPoints
        )
    }
}

/// Fits the angular correction and chooses between candidate models on held-out error.
public enum GazeModelFitter {

    public struct Candidate: Sendable {
        public let model: GazeModel
        public let source: GazeSource
        public let basis: GazeBasis
    }

    /// Fits every combination of gaze source and basis, scores each by leave-one-out
    /// cross-validation, and returns them best first.
    ///
    /// Cross-validation rather than a plain residual, because a quadratic fitted to nine
    /// points can trace them almost exactly while being worse everywhere else. Leaving
    /// each target out in turn measures generalisation without asking the participant to
    /// sit through a second set of targets.
    /// Shrinkage strengths tried for every model shape. Zero is included so that an
    /// unregularised fit can win when the data genuinely supports it.
    static let ridgeGrid: [Double] = [0, 1e-5, 1e-4, 1e-3, 1e-2, 1e-1]

    public static func rank(
        points: [GazeCalibrationPoint],
        geometry: ScreenGeometry
    ) -> [Candidate] {
        var candidates: [Candidate] = []

        for source in GazeSource.allCases {
            let usable = points.filter { $0.measurement(for: source) != nil }
            guard usable.count >= 4 else { continue }

            let distances = usable.compactMap { $0.measurement(for: source)?.distance }
            guard let low = distances.min(), let high = distances.max() else { continue }

            for basis in GazeBasis.allCases {
                // Leave-one-out removes a point, so the remainder must still over-determine
                // the fit rather than merely satisfy it.
                guard usable.count - 1 >= basis.parameterCount + 1 else { continue }

                for ridge in ridgeGrid {
                    guard
                        let coefficients = solve(
                            points: usable, source: source, basis: basis,
                            geometry: geometry, ridge: ridge
                        ),
                        let score = leaveOneOutError(
                            points: usable, source: source, basis: basis,
                            geometry: geometry, ridge: ridge
                        )
                    else { continue }

                    candidates.append(
                        Candidate(
                            model: GazeModel(
                                source: source,
                                basis: basis,
                                uCoefficients: coefficients.u,
                                vCoefficients: coefficients.v,
                                ridge: ridge,
                                heldOutErrorPoints: score.mean,
                                worstHeldOutErrorPoints: score.worst,
                                targetCount: usable.count,
                                calibratedDistanceRange: low...high,
                                distanceCheckErrorPoints: nil,
                                distanceCheckDistance: nil,
                                createdAt: Date()
                            ),
                            source: source,
                            basis: basis
                        )
                    )
                }
            }
        }

        return candidates.sorted { $0.model.heldOutErrorPoints < $1.model.heldOutErrorPoints }
    }

    public static func best(points: [GazeCalibrationPoint], geometry: ScreenGeometry) -> GazeModel? {
        rank(points: points, geometry: geometry).first?.model
    }

    /// Mean and worst error, in screen points, of a model applied to given points.
    public static func error(
        of model: GazeModel,
        on points: [GazeCalibrationPoint],
        geometry: ScreenGeometry
    ) -> (mean: Double, worst: Double)? {
        var total = 0.0
        var worst = 0.0
        var count = 0

        for point in points {
            guard let measurement = point.measurement(for: model.source) else { continue }
            let hit = model.screenPlaneHit(for: measurement)
            let predicted = geometry.normalised(fromCameraMetres: hit)
            let error = distanceInPoints(predicted, point.target, geometry: geometry)
            total += error
            worst = max(worst, error)
            count += 1
        }

        guard count > 0 else { return nil }
        return (total / Double(count), worst)
    }

    // MARK: Internals

    private static func solve(
        points: [GazeCalibrationPoint],
        source: GazeSource,
        basis: GazeBasis,
        geometry: ScreenGeometry,
        ridge: Double
    ) -> (u: [Double], v: [Double])? {
        var design: [[Double]] = []
        var requiredU: [Double] = []
        var requiredV: [Double] = []

        for point in points {
            guard let measurement = point.measurement(for: source) else { continue }
            let targetMetres = geometry.cameraMetres(fromNormalised: point.target)
            design.append(basis.expand(u: measurement.u, v: measurement.v))
            requiredU.append((Double(targetMetres.x) - measurement.eyeX) / measurement.distance)
            requiredV.append((Double(targetMetres.y) - measurement.eyeY) / measurement.distance)
        }

        guard
            design.count >= basis.parameterCount,
            let u = LeastSquares.solve(design: design, observations: requiredU, ridge: ridge),
            let v = LeastSquares.solve(design: design, observations: requiredV, ridge: ridge)
        else { return nil }

        return (u, v)
    }

    private static func leaveOneOutError(
        points: [GazeCalibrationPoint],
        source: GazeSource,
        basis: GazeBasis,
        geometry: ScreenGeometry,
        ridge: Double
    ) -> (mean: Double, worst: Double)? {
        var total = 0.0
        var worst = 0.0
        var count = 0

        for index in points.indices {
            var training = points
            let heldOut = training.remove(at: index)
            guard
                let measurement = heldOut.measurement(for: source),
                let coefficients = solve(
                    points: training, source: source, basis: basis,
                    geometry: geometry, ridge: ridge
                )
            else { return nil }

            let terms = basis.expand(u: measurement.u, v: measurement.v)
            let correctedU = zip(terms, coefficients.u).reduce(0) { $0 + $1.0 * $1.1 }
            let correctedV = zip(terms, coefficients.v).reduce(0) { $0 + $1.0 * $1.1 }

            let hit = CGPoint(
                x: measurement.eyeX + measurement.distance * correctedU,
                y: measurement.eyeY + measurement.distance * correctedV
            )
            let predicted = geometry.normalised(fromCameraMetres: hit)
            let error = distanceInPoints(predicted, heldOut.target, geometry: geometry)
            guard error.isFinite else { return nil }

            total += error
            worst = max(worst, error)
            count += 1
        }

        guard count > 0 else { return nil }
        return (total / Double(count), worst)
    }

    static func distanceInPoints(_ a: CGPoint, _ b: CGPoint, geometry: ScreenGeometry) -> Double {
        let dx = (Double(a.x) - Double(b.x)) * Double(geometry.pointSize.width)
        let dy = (Double(a.y) - Double(b.y)) * Double(geometry.pointSize.height)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Persists the model between launches so a participant is not recalibrated for every
/// build. Storage moves into the session database with the storage milestone.
public enum GazeModelStore {
    private static let key = "interactionFingerprint.gazeModel.v2"

    public static func load(from defaults: UserDefaults = .standard) -> GazeModel? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(GazeModel.self, from: data)
    }

    public static func save(_ model: GazeModel, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(model) else { return }
        defaults.set(data, forKey: key)
    }

    public static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
