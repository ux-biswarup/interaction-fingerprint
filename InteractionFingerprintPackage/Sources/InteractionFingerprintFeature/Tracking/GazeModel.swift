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

/// Shape of the correction.
///
/// The `Offset` variants also solve for the camera's true position relative to the
/// display. That position is a fixed distance, while the eye's own error is a fixed
/// angle, and the two are only separable when the calibration data spans more than one
/// viewing distance. Solving for it beats hardcoding a table of camera placements that
/// would be wrong for every phone not in the table.
public enum GazeBasis: String, Codable, Sendable, CaseIterable {
    /// 1, u, v.
    case affine
    /// 1, u, v, and the camera position.
    case affineOffset
    /// 1, u, v, u², v², uv.
    case quadratic
    /// 1, u, v, u², v², uv, and the camera position.
    case quadraticOffset

    public var solvesCameraOffset: Bool {
        self == .affineOffset || self == .quadraticOffset
    }

    var angularTermCount: Int {
        switch self {
        case .affine, .affineOffset: 3
        case .quadratic, .quadraticOffset: 6
        }
    }

    public var parameterCount: Int {
        angularTermCount + (solvesCameraOffset ? 1 : 0)
    }

    public var label: String {
        switch self {
        case .affine: "linear"
        case .affineOffset: "linear + camera"
        case .quadratic: "quadratic"
        case .quadraticOffset: "quadratic + camera"
        }
    }

    /// The terms that make up the corrected gaze angle.
    func angularTerms(u: Double, v: Double) -> [Double] {
        switch angularTermCount {
        case 6: [1, u, v, u * u, v * v, u * v]
        default: [1, u, v]
        }
    }

    /// One row of the fitting matrix.
    ///
    /// The camera position enters as a term in one over the distance, which is what makes
    /// it linear in the unknowns and separable from the angular terms once the data spans
    /// two distances.
    func designRow(u: Double, v: Double, distance: Double) -> [Double] {
        var row = angularTerms(u: u, v: v)
        if solvesCameraOffset { row.append(-1 / distance) }
        return row
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
    /// Which position in the target grid this is. Both viewing distances visit the same
    /// grid, so this groups the two visits together for cross-validation.
    public let targetIndex: Int
    public let convergence: GazeMeasurement?
    public let perEye: GazeMeasurement?
    public let headYaw: Double
    public let headPitch: Double

    public init(
        target: CGPoint,
        targetIndex: Int,
        convergence: GazeMeasurement?,
        perEye: GazeMeasurement?,
        headYaw: Double,
        headPitch: Double
    ) {
        self.target = target
        self.targetIndex = targetIndex
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

/// A fitted correction from measured gaze angles to a position on the display.
///
/// The correction is applied to the *angles*, never to the landing position. A person's
/// dominant gaze error is the offset between the eye's optical and visual axis, an angle
/// of roughly five degrees that is a fixed property of that person. An angle lands on the
/// screen scaled by viewing distance, so a correction stored as a distance on the screen
/// is only valid at the distance it was learned at.
///
/// Separately, `cameraOffset` carries the camera's true position relative to the display,
/// which is a fixed distance rather than an angle. Keeping the two apart is what lets the
/// phone be picked up and held differently without the mapping falling apart.
public struct GazeModel: Codable, Sendable, Equatable {
    public let source: GazeSource
    public let basis: GazeBasis
    /// Coefficients of the angular correction only.
    public let uCoefficients: [Double]
    public let vCoefficients: [Double]
    /// Solved camera position relative to the nominal origin, in metres. Zero when the
    /// basis does not solve for it.
    public let cameraOffsetX: Double
    public let cameraOffsetY: Double
    /// Tikhonov strength chosen by cross-validation. Zero means no shrinkage was needed.
    public let ridge: Double

    /// Mean error on targets held out of the fit, in screen points, where holding out a
    /// target removes it at *every* viewing distance. This is the honest accuracy figure:
    /// error measured on the same targets a model was fitted to always flatters it.
    public let heldOutErrorPoints: Double
    public let worstHeldOutErrorPoints: Double
    public let targetCount: Int

    /// Range of viewing distances the fit actually saw, in metres.
    public let calibratedDistanceRange: ClosedRange<Double>
    public let createdAt: Date

    public func correct(u: Double, v: Double) -> (u: Double, v: Double) {
        let terms = basis.angularTerms(u: u, v: v)
        return (
            u: zip(terms, uCoefficients).reduce(0) { $0 + $1.0 * $1.1 },
            v: zip(terms, vCoefficients).reduce(0) { $0 + $1.0 * $1.1 }
        )
    }

    /// Where the corrected gaze lands, in nominal camera-space metres, with the solved
    /// camera position already taken out so the result can go straight into `ScreenGeometry`.
    public func screenPlaneHit(for measurement: GazeMeasurement) -> CGPoint {
        let corrected = correct(u: measurement.u, v: measurement.v)
        return CGPoint(
            x: measurement.eyeX + measurement.distance * corrected.u - cameraOffsetX,
            y: measurement.eyeY + measurement.distance * corrected.v - cameraOffsetY
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
            source.label, basis.label, ridge > 0 ? " · shrunk" : "", heldOutErrorPoints
        )
    }

    /// Solved camera position in millimetres, for the diagnostics readout.
    public var cameraOffsetMillimetres: (x: Double, y: Double) {
        (cameraOffsetX * 1000, cameraOffsetY * 1000)
    }
}

/// Fits the correction and chooses between candidate models on held-out error.
public enum GazeModelFitter {

    public struct Candidate: Sendable {
        public let model: GazeModel
        public let source: GazeSource
        public let basis: GazeBasis
    }

    /// Shrinkage strengths tried for every model shape. Zero is included so an
    /// unregularised fit can win when the data genuinely supports it.
    static let ridgeGrid: [Double] = [0, 1e-5, 1e-4, 1e-3, 1e-2, 1e-1]

    /// Minimum spread in one over the distance before the camera position can be solved.
    /// Roughly six centimetres of movement at normal holding distances.
    static let minimumInverseDistanceSpread = 0.25

    /// Fits every combination of gaze source, basis shape and shrinkage, scores each by
    /// cross-validation, and returns them best first.
    ///
    /// Validation groups by target position, so holding out a target removes it at every
    /// distance it was visited. Holding out only one visit would let the model see the
    /// same screen position at the other distance and score far better than it deserves.
    public static func rank(
        points: [GazeCalibrationPoint],
        geometry: ScreenGeometry
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        let groups = Set(points.map(\.targetIndex)).sorted()
        guard groups.count >= 4 else { return [] }

        for source in GazeSource.allCases {
            let usable = points.filter { $0.measurement(for: source) != nil }
            let distances = usable.compactMap { $0.measurement(for: source)?.distance }
            guard let low = distances.min(), let high = distances.max() else { continue }
            let inverseSpread = (1 / low) - (1 / high)

            for basis in GazeBasis.allCases {
                // Solving for the camera position needs real distance variation, otherwise
                // it is indistinguishable from a constant angular offset.
                if basis.solvesCameraOffset, inverseSpread < minimumInverseDistanceSpread { continue }
                // Leaving a group out must still leave the fit over-determined.
                let smallest = groups.count - 1
                guard usable.count - (usable.count / max(groups.count, 1)) >= basis.parameterCount + 1,
                      smallest >= 3 else { continue }

                for ridge in ridgeGrid {
                    guard
                        let solution = solve(points: usable, source: source, basis: basis, geometry: geometry, ridge: ridge),
                        let score = groupedCrossValidation(
                            points: usable, groups: groups, source: source,
                            basis: basis, geometry: geometry, ridge: ridge
                        )
                    else { continue }

                    candidates.append(
                        Candidate(
                            model: GazeModel(
                                source: source,
                                basis: basis,
                                uCoefficients: solution.u,
                                vCoefficients: solution.v,
                                cameraOffsetX: solution.offsetX,
                                cameraOffsetY: solution.offsetY,
                                ridge: ridge,
                                heldOutErrorPoints: score.mean,
                                worstHeldOutErrorPoints: score.worst,
                                targetCount: usable.count,
                                calibratedDistanceRange: low...high,
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
            let predicted = geometry.normalised(fromCameraMetres: model.screenPlaneHit(for: measurement))
            let error = distanceInPoints(predicted, point.target, geometry: geometry)
            guard error.isFinite else { continue }
            total += error
            worst = max(worst, error)
            count += 1
        }

        guard count > 0 else { return nil }
        return (total / Double(count), worst)
    }

    // MARK: Internals

    struct Solution {
        let u: [Double]
        let v: [Double]
        let offsetX: Double
        let offsetY: Double
    }

    static func solve(
        points: [GazeCalibrationPoint],
        source: GazeSource,
        basis: GazeBasis,
        geometry: ScreenGeometry,
        ridge: Double
    ) -> Solution? {
        var design: [[Double]] = []
        var requiredU: [Double] = []
        var requiredV: [Double] = []

        for point in points {
            guard let measurement = point.measurement(for: source) else { continue }
            let targetMetres = geometry.cameraMetres(fromNormalised: point.target)
            design.append(basis.designRow(u: measurement.u, v: measurement.v, distance: measurement.distance))
            requiredU.append((Double(targetMetres.x) - measurement.eyeX) / measurement.distance)
            requiredV.append((Double(targetMetres.y) - measurement.eyeY) / measurement.distance)
        }

        guard
            design.count >= basis.parameterCount + 1,
            var u = LeastSquares.solve(design: design, observations: requiredU, ridge: ridge),
            var v = LeastSquares.solve(design: design, observations: requiredV, ridge: ridge)
        else { return nil }

        var offsetX = 0.0
        var offsetY = 0.0
        if basis.solvesCameraOffset {
            offsetX = u.removeLast()
            offsetY = v.removeLast()
            // A solved camera position more than two centimetres from nominal is not a
            // camera position, it is the fit absorbing something else.
            guard abs(offsetX) < 0.02, abs(offsetY) < 0.02 else { return nil }
        }

        return Solution(u: u, v: v, offsetX: offsetX, offsetY: offsetY)
    }

    private static func groupedCrossValidation(
        points: [GazeCalibrationPoint],
        groups: [Int],
        source: GazeSource,
        basis: GazeBasis,
        geometry: ScreenGeometry,
        ridge: Double
    ) -> (mean: Double, worst: Double)? {
        var total = 0.0
        var worst = 0.0
        var count = 0

        for group in groups {
            let training = points.filter { $0.targetIndex != group }
            let heldOut = points.filter { $0.targetIndex == group }
            guard !heldOut.isEmpty,
                  let solution = solve(
                      points: training, source: source, basis: basis,
                      geometry: geometry, ridge: ridge
                  )
            else { return nil }

            let fold = GazeModel(
                source: source,
                basis: basis,
                uCoefficients: solution.u,
                vCoefficients: solution.v,
                cameraOffsetX: solution.offsetX,
                cameraOffsetY: solution.offsetY,
                ridge: ridge,
                heldOutErrorPoints: 0,
                worstHeldOutErrorPoints: 0,
                targetCount: training.count,
                calibratedDistanceRange: 0.1...1.0,
                createdAt: Date()
            )

            guard let score = error(of: fold, on: heldOut, geometry: geometry) else { return nil }
            total += score.mean * Double(heldOut.count)
            worst = max(worst, score.worst)
            count += heldOut.count
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
    private static let key = "interactionFingerprint.gazeModel.v3"

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
