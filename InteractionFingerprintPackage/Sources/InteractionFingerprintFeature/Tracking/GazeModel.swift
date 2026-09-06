import CoreGraphics
import Foundation

/// Which of the two gaze estimates a model was fitted to.
public enum GazeSource: String, Codable, Sendable, CaseIterable {
    /// ARKit's convergence point, taken from the midpoint of the eyes.
    case convergence
    /// Each eye's own orientation, averaged.
    case perEye
    /// The pupil's position inside the eye opening, from Vision's landmarks, added to the
    /// head direction. See `PupilDetector`.
    case pupil
    /// The learned eye-in-head model's estimate, added to the head direction. See
    /// `LearnedEyeModel` and `docs/product/11-LEARNED-EYE-MODEL.md`.
    case learned

    public var label: String {
        switch self {
        case .convergence: "convergence"
        case .perEye: "per-eye"
        case .pupil: "pupil"
        case .learned: "learned"
        }
    }

    /// Every source must show a positive gain along each axis: an eye that turns right must
    /// map right. The pupil source's sign convention was established from the first
    /// calibration that used it, 6 September 2026. The learned model's was established the
    /// same day: the front camera image is mirrored relative to its training images, and the
    /// crops are mirrored back before it sees them (`EyeCropGeometry.mirrored`).
    var requiresPositiveGain: Bool { true }
}

/// Shape of the correction.
///
/// The model is physical before it is statistical. ARKit reports the direction of the
/// **head** at full strength and the rotation of the **eyes within the head** at roughly a
/// fifth of its true size, which was established from exported calibration frames and
/// confirmed against taps in free viewing (`docs/product/10-MOTION-FUSION.md` §11). So the
/// corrected gaze is
///
///     gaze = head direction + f(measured gaze − head direction)
///
/// where `f` is the fitted correction of the eye-in-head angle, and the head passes through
/// with a gain of exactly one because that is what a direction does. Only `f` has free
/// parameters. Two of its shapes are decided by cross-validation:
///
/// - `order` 1 or 2. A quadratic can follow the mild curvature that appears towards the
///   edges of the display, at the cost of twice the parameters.
/// - `solvesCameraOffset`. Also solves where the camera really sits relative to the
///   display. That is a fixed distance while the eye's own error is a fixed angle, and the
///   two only separate when the data spans more than one viewing distance.
/// - `usesHeadPose` is always true and names the head-plus-eye structure above. It is kept
///   as a field so stored models decode. `usesEyeLook` is always false: the eye-direction
///   blend shapes are a second readout of the same eye rotation and were collinear with it.
public struct GazeBasis: Codable, Sendable, Equatable, Hashable {
    public let order: Int
    public let solvesCameraOffset: Bool
    public let usesHeadPose: Bool
    public let usesEyeLook: Bool

    public init(order: Int, solvesCameraOffset: Bool, usesHeadPose: Bool = true, usesEyeLook: Bool = false) {
        self.order = order
        self.solvesCameraOffset = solvesCameraOffset
        self.usesHeadPose = usesHeadPose
        self.usesEyeLook = usesEyeLook
    }

    private enum CodingKeys: String, CodingKey {
        case order, solvesCameraOffset, usesHeadPose, usesEyeLook
    }

    /// Models saved before the eye-look terms existed decode with them switched off, so a
    /// participant's stored calibration survives the upgrade.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decode(Int.self, forKey: .order)
        solvesCameraOffset = try c.decode(Bool.self, forKey: .solvesCameraOffset)
        usesHeadPose = try c.decode(Bool.self, forKey: .usesHeadPose)
        usesEyeLook = try c.decodeIfPresent(Bool.self, forKey: .usesEyeLook) ?? false
    }

    /// The shapes the fitter may choose between. The head is not optional and the
    /// eye-direction shapes are not offered; see the type documentation.
    public static let allCases: [GazeBasis] = [1, 2].flatMap { order in
        [false, true].map { offset in
            GazeBasis(order: order, solvesCameraOffset: offset, usesHeadPose: true, usesEyeLook: false)
        }
    }

    var angularTermCount: Int {
        order == 2 ? 6 : 3
    }

    public var parameterCount: Int {
        angularTermCount + (solvesCameraOffset ? 1 : 0)
    }

    public var label: String {
        var parts = ["head", order == 2 ? "quadratic" : "linear"]
        if solvesCameraOffset { parts.append("camera") }
        return parts.joined(separator: "+")
    }

    /// The terms that make up the corrected gaze angle, from **standardised** inputs.
    ///
    /// `z` is `[u, v, yaw, pitch, lookU, lookV]` after `GazeInputScaling` has centred and
    /// scaled each one to roughly unit spread. Fitting on raw inputs was the root of an
    /// ill-conditioned model: the vertical gaze ratio spans about 0.05 across the whole
    /// display, so its square is all but collinear with it, the two took coefficients in
    /// the hundreds that cancelled inside the grid, and the shrinkage penalty could not see
    /// any of it because it was measured in the wrong units.
    func angularTerms(_ z: [Double]) -> [Double] {
        let u = z[0], v = z[1]
        return order == 2 ? [1, u, v, u * u, v * v, u * v] : [1, u, v]
    }

    /// Derivative of every term with respect to standardised `u` (axis 0) or `v` (axis 1).
    /// Used to continue the correction linearly beyond the calibrated range.
    func angularTermGradient(_ z: [Double], axis: Int) -> [Double] {
        let u = z[0], v = z[1]
        if axis == 0 {
            return order == 2 ? [0, 1, 0, 2 * u, 0, v] : [0, 1, 0]
        }
        return order == 2 ? [0, 0, 1, 0, 2 * v, u] : [0, 0, 1]
    }

    /// One row of the fitting matrix. The camera position enters as a term in one over the
    /// distance, in raw units because its coefficient is a distance that is read back out.
    func designRow(for m: GazeMeasurement, scaling: GazeInputScaling) -> [Double] {
        var row = angularTerms(scaling.standardise(m.inputs))
        if solvesCameraOffset { row.append(-1 / m.distance) }
        return row
    }
}

/// Centre and scale for each model input, learned from the calibration frames.
///
/// The inputs are `GazeMeasurement.inputs`: the eye-in-head angle first, which is what the
/// correction is fitted on, then the remaining measured quantities for the record.
///
/// Every input is mapped to `(x - centre) / scale` before any term is formed, so that the
/// columns of the fit have comparable size, the shrinkage penalty means the same thing for
/// each of them, and a coefficient's magnitude says something about its importance.
public struct GazeInputScaling: Codable, Sendable, Equatable {
    /// Same order as `GazeMeasurement.inputs`.
    public let centre: [Double]
    public let scale: [Double]

    public static let identity = GazeInputScaling(centre: [0, 0, 0, 0, 0, 0], scale: [1, 1, 1, 1, 1, 1])

    public init(centre: [Double], scale: [Double]) {
        self.centre = centre
        self.scale = scale
    }

    /// Mean and standard deviation of each input. An input that never varied gets a scale
    /// of one, so it passes through unchanged rather than dividing by zero.
    public init(measurements: [GazeMeasurement]) {
        let n = Double(max(measurements.count, 1))
        var centre = [Double](repeating: 0, count: 6)
        var scale = [Double](repeating: 0, count: 6)
        for m in measurements {
            for (i, x) in m.inputs.enumerated() { centre[i] += x / n }
        }
        for m in measurements {
            for (i, x) in m.inputs.enumerated() { scale[i] += (x - centre[i]) * (x - centre[i]) / n }
        }
        self.centre = centre
        self.scale = scale.map { $0 > 1e-12 ? $0.squareRoot() : 1 }
    }

    public func standardise(_ raw: [Double]) -> [Double] {
        zip(zip(raw, centre), scale).map { ($0.0 - $0.1) / $1 }
    }
}

/// One measured gaze direction, with the eye position it was measured from.
public struct GazeMeasurement: Codable, Sendable, Equatable {
    public let u: Double
    public let v: Double
    public let eyeX: Double
    public let eyeY: Double
    public let distance: Double
    /// Head orientation when this was measured. Carried on the measurement because the
    /// correction may depend on it, so prediction needs it as well as fitting.
    public let headYaw: Double
    public let headPitch: Double
    /// ARKit's eye-direction blend shapes folded to one horizontal and one vertical term.
    /// Recorded, not fitted. Zero when they were not captured.
    public let lookU: Double
    public let lookV: Double
    /// The head's forward direction as ratios in the same frame and units as `u` and `v`.
    /// The model's fixed-gain term; see `GazeBasis`.
    public let headU: Double
    public let headV: Double

    public init(
        u: Double, v: Double, eyeX: Double, eyeY: Double, distance: Double,
        headYaw: Double = 0, headPitch: Double = 0,
        lookU: Double = 0, lookV: Double = 0,
        headU: Double = 0, headV: Double = 0
    ) {
        self.u = u
        self.v = v
        self.eyeX = eyeX
        self.eyeY = eyeY
        self.distance = distance
        self.headYaw = headYaw
        self.headPitch = headPitch
        self.lookU = lookU
        self.lookV = lookV
        self.headU = headU
        self.headV = headV
    }

    /// The eye's rotation within the head, as direction ratios: what the correction is
    /// actually fitted on.
    public var eyeInHeadU: Double { u - headU }
    public var eyeInHeadV: Double { v - headV }

    /// The model inputs in the order `GazeInputScaling` and `GazeInputRange` use: the
    /// eye-in-head angle first, then the rest for the record.
    var inputs: [Double] { [eyeInHeadU, eyeInHeadV, headU, headV, lookU, lookV] }

    public init?(
        _ estimate: GazeRay.Estimate,
        headYaw: Double = 0, headPitch: Double = 0,
        lookU: Double = 0, lookV: Double = 0,
        headU: Double = 0, headV: Double = 0
    ) {
        let distance = estimate.viewingDistance
        guard distance > 0.05, distance < 2.0 else { return nil }
        self.init(
            u: estimate.u,
            v: estimate.v,
            eyeX: Double(estimate.eye.x),
            eyeY: Double(estimate.eye.y),
            distance: distance,
            headYaw: headYaw,
            headPitch: headPitch,
            lookU: lookU,
            lookV: lookV,
            headU: headU,
            headV: headV
        )
    }
}

/// What was captured while one calibration target was on screen.
public struct GazeCalibrationPoint: Codable, Sendable, Equatable {
    public let target: CGPoint
    /// Which position in the target grid this is. Both viewing distances visit the same
    /// grid, so this groups the two visits together for cross-validation.
    public let targetIndex: Int
    public let convergence: GazeMeasurement?
    public let perEye: GazeMeasurement?
    public let pupil: GazeMeasurement?
    public let learned: GazeMeasurement?
    public let headYaw: Double
    public let headPitch: Double

    public init(
        target: CGPoint,
        targetIndex: Int,
        convergence: GazeMeasurement?,
        perEye: GazeMeasurement?,
        headYaw: Double,
        headPitch: Double,
        pupil: GazeMeasurement? = nil,
        learned: GazeMeasurement? = nil
    ) {
        self.target = target
        self.targetIndex = targetIndex
        self.convergence = convergence
        self.perEye = perEye
        self.pupil = pupil
        self.learned = learned
        self.headYaw = headYaw
        self.headPitch = headPitch
    }

    private enum CodingKeys: String, CodingKey { case target, targetIndex, convergence, perEye, pupil, learned, headYaw, headPitch }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(CGPoint.self, forKey: .target)
        targetIndex = try c.decode(Int.self, forKey: .targetIndex)
        convergence = try c.decodeIfPresent(GazeMeasurement.self, forKey: .convergence)
        perEye = try c.decodeIfPresent(GazeMeasurement.self, forKey: .perEye)
        pupil = try c.decodeIfPresent(GazeMeasurement.self, forKey: .pupil)
        learned = try c.decodeIfPresent(GazeMeasurement.self, forKey: .learned)
        headYaw = try c.decode(Double.self, forKey: .headYaw)
        headPitch = try c.decode(Double.self, forKey: .headPitch)
    }

    func measurement(for source: GazeSource) -> GazeMeasurement? {
        switch source {
        case .convergence: convergence
        case .perEye: perEye
        case .pupil: pupil
        case .learned: learned
        }
    }
}

/// The span of every model input seen during calibration.
///
/// Recorded so that prediction can refuse to extrapolate. The first real recording made
/// the need plain: a model that scored 69 points on held-out targets sent half of all
/// samples off the screen in use, because the head-pose and quadratic terms were being
/// evaluated far outside the range they had been fitted on. A coefficient learned over
/// two degrees of head movement says nothing about ten.
public struct GazeInputRange: Codable, Sendable, Equatable {
    public let u: ClosedRange<Double>
    public let v: ClosedRange<Double>
    public let yaw: ClosedRange<Double>
    public let pitch: ClosedRange<Double>
    public let lookU: ClosedRange<Double>
    public let lookV: ClosedRange<Double>

    /// How far beyond the calibrated span an input may go before it is held, as a fraction
    /// of that span. A little slack so the edge of the grid is not a hard wall.
    public static let margin = 0.15

    public init(
        u: ClosedRange<Double>, v: ClosedRange<Double>,
        yaw: ClosedRange<Double>, pitch: ClosedRange<Double>,
        lookU: ClosedRange<Double>, lookV: ClosedRange<Double>
    ) {
        self.u = u
        self.v = v
        self.yaw = yaw
        self.pitch = pitch
        self.lookU = lookU
        self.lookV = lookV
    }

    /// Spans of `GazeMeasurement.inputs`. `u` and `v` here are the eye-in-head angle, the
    /// two the correction is fitted on; `yaw` and `pitch` hold the head direction ratios.
    public init?(measurements: [GazeMeasurement]) {
        guard !measurements.isEmpty else { return nil }
        let inputs = measurements.map(\.inputs)
        func span(_ i: Int) -> ClosedRange<Double> {
            let values = inputs.map { $0[i] }
            return (values.min() ?? 0)...(values.max() ?? 0)
        }
        self.init(u: span(0), v: span(1), yaw: span(2), pitch: span(3), lookU: span(4), lookV: span(5))
    }

    /// Holds a value inside the calibrated span plus margin.
    public static func bound(_ value: Double, to range: ClosedRange<Double>) -> Double {
        let slack = (range.upperBound - range.lowerBound) * margin
        return min(max(value, range.lowerBound - slack), range.upperBound + slack)
    }

    /// Every input held inside its span, in the order `GazeMeasurement.inputs` uses.
    func bound(_ raw: [Double]) -> [Double] {
        [
            Self.bound(raw[0], to: u), Self.bound(raw[1], to: v),
            Self.bound(raw[2], to: yaw), Self.bound(raw[3], to: pitch),
            Self.bound(raw[4], to: lookU), Self.bound(raw[5], to: lookV),
        ]
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
    /// What the inputs spanned during calibration. Nil on models saved before this existed,
    /// which then predict without bounds as they always did.
    public let inputRange: GazeInputRange?
    /// How the inputs were centred and scaled before fitting. Nil means the model was fitted
    /// on raw inputs, which older saved models were.
    public let scaling: GazeInputScaling?

    /// **Accuracy.** Offset between a target and the *mean* estimate while the eyes were on
    /// it, in screen points, measured on targets held out of the fit.
    ///
    /// This is what the eye-tracking field means by accuracy, and what the published ARKit
    /// figure of 3.18° refers to. Averaging within a target before measuring is the
    /// definition, not a flattering choice: no analysis ever consumes a single 60 Hz frame.
    public let accuracyPoints: Double
    /// The same figure as a visual angle, for direct comparison with the literature.
    public let accuracyDegrees: Double
    /// Worst single held-out target, in points. Reveals error concentrated in one corner
    /// that a mean would hide.
    public let worstTargetPoints: Double
    /// Error of each individual frame against its target, held out. Always larger than
    /// accuracy, because it also carries the frame-to-frame jitter.
    public let perSampleErrorPoints: Double
    /// Accuracy on the targets the model was *fitted* to. The gap against `accuracyPoints`
    /// says whether the correction generalises across the screen or is merely tracing the
    /// calibration points, which decides whether more targets would help.
    public let inSampleAccuracyPoints: Double
    /// Sample-to-sample scatter while the eyes are fixed on one point, in screen points.
    ///
    /// The eye-tracking field separates accuracy, how far the average estimate sits from
    /// the truth, from precision, how much consecutive estimates jitter around that
    /// average. The distinction decides whether the research is workable: scatter averages
    /// away over a fixation, bias does not.
    public let precisionPoints: Double
    /// Number of individual frames the fit used, not the number of targets.
    public let sampleCount: Int
    public let targetCount: Int
    public let meanCalibrationDistance: Double

    /// Range of viewing distances the fit actually saw, in metres.
    public let calibratedDistanceRange: ClosedRange<Double>
    public let createdAt: Date

    /// Inside the calibrated range the correction is evaluated as fitted. Beyond it, the
    /// gaze inputs are held at the edge and the correction **continues along its slope
    /// there**, so a quadratic becomes a straight line once it leaves the data and an
    /// angular model still extrapolates off the display the way it should. The head-pose
    /// and eye-shape covariates are simply held, because outside what was seen they are
    /// unknown.
    ///
    /// All terms are evaluated at the same point. An earlier version held only the
    /// quadratic inputs while letting the linear ones run, and that broke the cancellation
    /// an ill-conditioned fit depends on: a whole recording landed five screens away. The
    /// terms of a fitted polynomial are not separately meaningful and must not be treated
    /// as if they were.
    public func correct(u: Double, v: Double, headU: Double, headV: Double) -> (u: Double, v: Double) {
        let scaling = scaling ?? .identity
        let raw = [u - headU, v - headV, headU, headV, 0, 0]
        let z = scaling.standardise(raw)

        guard let range = inputRange else {
            let terms = basis.angularTerms(z)
            return (headU + dot(terms, uCoefficients), headV + dot(terms, vCoefficients))
        }

        let zb = scaling.standardise(range.bound(raw))
        let terms = basis.angularTerms(zb)
        var cu = dot(terms, uCoefficients)
        var cv = dot(terms, vCoefficients)
        for axis in 0..<2 where z[axis] != zb[axis] {
            let gradient = basis.angularTermGradient(zb, axis: axis)
            let step = z[axis] - zb[axis]
            cu += step * dot(gradient, uCoefficients)
            cv += step * dot(gradient, vCoefficients)
        }
        // The head passes through with a gain of one. It is a direction, not a parameter.
        return (headU + cu, headV + cv)
    }

    private func dot(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// Where the corrected gaze lands, in nominal camera-space metres, with the solved
    /// camera position already taken out so the result can go straight into `ScreenGeometry`.
    public func screenPlaneHit(for measurement: GazeMeasurement) -> CGPoint {
        let corrected = correct(
            u: measurement.u, v: measurement.v,
            headU: measurement.headU, headV: measurement.headV
        )
        return CGPoint(
            x: measurement.eyeX + measurement.distance * corrected.u - cameraOffsetX,
            y: measurement.eyeY + measurement.distance * corrected.v - cameraOffsetY
        )
    }

    /// How much of the accuracy figure is the model failing to generalise, rather than a
    /// limit of the signal. A large gap argues for more calibration targets; a small gap
    /// means the signal itself is this noisy and more targets will not help.
    public var generalisationGapPoints: Double {
        max(accuracyPoints - inSampleAccuracyPoints, 0)
    }

    public var accuracyDescription: String {
        switch accuracyPoints {
        case ..<45: "good"
        case ..<90: "usable"
        default: "poor"
        }
    }

    public var summary: String {
        String(
            format: "%@ · %@%@ · ±%.0f pt · %.2f°",
            source.label, basis.label, ridge > 0 ? " · shrunk" : "",
            accuracyPoints, accuracyDegrees
        )
    }

    /// The part of the error that does not average away, in screen points.
    ///
    /// Total error and scatter add in quadrature, so the systematic remainder is what is
    /// left after removing the scatter. This is the floor on how well any amount of
    /// averaging can do.
    public var biasPoints: Double {
        let total = perSampleErrorPoints * perSampleErrorPoints
        let scatter = precisionPoints * precisionPoints
        return (total > scatter ? (total - scatter).squareRoot() : 0)
    }

    /// Expected accuracy once samples are aggregated into a fixation.
    ///
    /// Analysis works on fixations, not raw samples. The scatter shrinks with the square
    /// root of the sample count while the bias stays put, and the two combine in
    /// quadrature. This is the number that governs whether two areas of interest can
    /// actually be told apart.
    public func fixationErrorPoints(samples: Int) -> Double {
        guard samples > 1 else { return perSampleErrorPoints }
        let scatter = precisionPoints / Double(samples).squareRoot()
        return (biasPoints * biasPoints + scatter * scatter).squareRoot()
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

    /// Shrinkage strengths tried for every model shape. `LeastSquares.solve` scales the
    /// penalty to the mean diagonal of the normal matrix, so these are fractions of the
    /// data's own scale. With standardised inputs every column now has the same scale, so
    /// one value shrinks every term equally, which the raw-input fit never managed. Zero is
    /// included so an unregularised fit can win when the data genuinely supports it.
    static let ridgeGrid: [Double] = [0, 1e-5, 1e-4, 1e-3, 1e-2, 1e-1]

    /// How much better a model with more parameters must be to displace a simpler one,
    /// as a fraction of the simpler one's held-out error, with a floor in points.
    ///
    /// Cross-validation on a grid only tests the model inside the grid. In use the eyes go
    /// beyond it, and there a simpler model is safer. So the simplest model within this
    /// margin of the best wins, not the best.
    static let parsimonyMargin = 0.08
    static let parsimonyFloorPoints = 3.0

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

            let inputRange = GazeInputRange(measurements: usable.compactMap { $0.measurement(for: source) })

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
                        // An eye that turns right must map right. A fit whose gain along
                        // either axis comes out zero or negative has found a coincidence
                        // in the data, not the eye, and is refused whatever its score.
                        !source.requiresPositiveGain || (solution.diagonalGain.u > 0 && solution.diagonalGain.v > 0),
                        let score = groupedCrossValidation(
                            points: usable, groups: groups, source: source,
                            basis: basis, geometry: geometry, ridge: ridge
                        )
                    else { continue }

                    let meanDistance = distances.reduce(0, +) / Double(distances.count)
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
                                inputRange: inputRange,
                                scaling: solution.scaling,
                                accuracyPoints: score.accuracy,
                                accuracyDegrees: degrees(
                                    points: score.accuracy, distance: meanDistance, geometry: geometry
                                ),
                                worstTargetPoints: score.worst,
                                perSampleErrorPoints: score.perSample,
                                inSampleAccuracyPoints: 0,
                                precisionPoints: 0,
                                sampleCount: usable.count,
                                targetCount: groups.count,
                                meanCalibrationDistance: meanDistance,
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

        return candidates.sorted { $0.model.accuracyPoints < $1.model.accuracyPoints }
    }

    public static func best(points: [GazeCalibrationPoint], geometry: ScreenGeometry) -> GazeModel? {
        let ranked = rank(points: points, geometry: geometry)
        guard let winner = choose(from: ranked)?.model else { return nil }
        let inSample = accuracy(of: winner, on: points, geometry: geometry)?.mean ?? 0
        return GazeModel(
            source: winner.source,
            basis: winner.basis,
            uCoefficients: winner.uCoefficients,
            vCoefficients: winner.vCoefficients,
            cameraOffsetX: winner.cameraOffsetX,
            cameraOffsetY: winner.cameraOffsetY,
            ridge: winner.ridge,
            inputRange: winner.inputRange,
            scaling: winner.scaling,
            accuracyPoints: winner.accuracyPoints,
            accuracyDegrees: winner.accuracyDegrees,
            worstTargetPoints: winner.worstTargetPoints,
            perSampleErrorPoints: winner.perSampleErrorPoints,
            inSampleAccuracyPoints: inSample,
            precisionPoints: precision(of: winner, on: points, geometry: geometry),
            sampleCount: winner.sampleCount,
            targetCount: winner.targetCount,
            meanCalibrationDistance: winner.meanCalibrationDistance,
            calibratedDistanceRange: winner.calibratedDistanceRange,
            createdAt: winner.createdAt
        )
    }

    /// The simplest candidate whose held-out error is within the parsimony margin of the
    /// best. Ties on parameter count go to the lower error, then to the stronger shrinkage.
    static func choose(from ranked: [Candidate]) -> Candidate? {
        guard let top = ranked.first else { return nil }
        let limit = top.model.accuracyPoints + max(top.model.accuracyPoints * parsimonyMargin, parsimonyFloorPoints)
        return ranked
            .filter { $0.model.accuracyPoints <= limit }
            .min { a, b in
                if a.basis.parameterCount != b.basis.parameterCount {
                    return a.basis.parameterCount < b.basis.parameterCount
                }
                if a.model.accuracyPoints != b.model.accuracyPoints {
                    return a.model.accuracyPoints < b.model.accuracyPoints
                }
                return a.model.ridge > b.model.ridge
            }
    }

    /// Sample-to-sample scatter while the eyes were fixed on one target, in screen points.
    ///
    /// Measured as the spread of estimates around each target's own centroid, so it is
    /// independent of how well the model is aimed. The median across targets is taken
    /// rather than the mean, so one unsettled target cannot dominate.
    static func precision(
        of model: GazeModel,
        on points: [GazeCalibrationPoint],
        geometry: ScreenGeometry
    ) -> Double {
        var perTarget: [Double] = []

        for group in Set(points.map(\.targetIndex)).sorted() {
            let predictions = points
                .filter { $0.targetIndex == group }
                .compactMap { $0.measurement(for: model.source) }
                .map { geometry.normalised(fromCameraMetres: model.screenPlaneHit(for: $0)) }
            guard predictions.count >= 4 else { continue }

            let centroid = CGPoint(
                x: predictions.map { Double($0.x) }.reduce(0, +) / Double(predictions.count),
                y: predictions.map { Double($0.y) }.reduce(0, +) / Double(predictions.count)
            )
            let squared = predictions.reduce(0.0) { total, point in
                let d = distanceInPoints(point, centroid, geometry: geometry)
                return total + d * d
            }
            perTarget.append((squared / Double(predictions.count)).squareRoot())
        }

        guard !perTarget.isEmpty else { return 0 }
        let sorted = perTarget.sorted()
        return sorted[sorted.count / 2]
    }

    /// **Accuracy** of a model on given points: for each target, the offset between the
    /// target and the mean estimate while the eyes were on it.
    ///
    /// This is the eye-tracking field's definition, and the reason it averages first is
    /// that a single 60 Hz sample is not what any analysis ever uses.
    public static func accuracy(
        of model: GazeModel,
        on points: [GazeCalibrationPoint],
        geometry: ScreenGeometry
    ) -> (mean: Double, worst: Double)? {
        var perTarget: [Double] = []

        for group in Set(points.map(\.targetIndex)).sorted() {
            let group = points.filter { $0.targetIndex == group }
            let predictions = group
                .compactMap { $0.measurement(for: model.source) }
                .map { geometry.normalised(fromCameraMetres: model.screenPlaneHit(for: $0)) }
            guard !predictions.isEmpty, let target = group.first?.target else { continue }

            let centroid = CGPoint(
                x: predictions.map { Double($0.x) }.reduce(0, +) / Double(predictions.count),
                y: predictions.map { Double($0.y) }.reduce(0, +) / Double(predictions.count)
            )
            let error = distanceInPoints(centroid, target, geometry: geometry)
            if error.isFinite { perTarget.append(error) }
        }

        guard !perTarget.isEmpty else { return nil }
        return (perTarget.reduce(0, +) / Double(perTarget.count), perTarget.max() ?? 0)
    }

    /// Mean and worst error, in screen points, of a model applied to given points, judged
    /// one frame at a time.
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
        let scaling: GazeInputScaling
        /// Mean slope of corrected horizontal against measured horizontal, and the same
        /// for vertical, in raw units. Physics requires both to be positive.
        let diagonalGain: (u: Double, v: Double)
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
        let measurements = points.compactMap { $0.measurement(for: source) }
        let scaling = GazeInputScaling(measurements: measurements)

        for point in points {
            guard let measurement = point.measurement(for: source) else { continue }
            let targetMetres = geometry.cameraMetres(fromNormalised: point.target)
            design.append(basis.designRow(for: measurement, scaling: scaling))
            // The correction is fitted on the eye-in-head angle, against the eye-in-head
            // angle the target demands: the head direction is taken off both sides.
            requiredU.append((Double(targetMetres.x) - measurement.eyeX) / measurement.distance - measurement.headU)
            requiredV.append((Double(targetMetres.y) - measurement.eyeY) / measurement.distance - measurement.headV)
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

        var gainU = 0.0
        var gainV = 0.0
        for measurement in measurements {
            let z = scaling.standardise(measurement.inputs)
            gainU += zipDot(basis.angularTermGradient(z, axis: 0), u) / scaling.scale[0]
            gainV += zipDot(basis.angularTermGradient(z, axis: 1), v) / scaling.scale[1]
        }
        let n = Double(max(measurements.count, 1))

        return Solution(
            u: u, v: v, offsetX: offsetX, offsetY: offsetY, scaling: scaling,
            diagonalGain: (gainU / n, gainV / n)
        )
    }

    private static func zipDot(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private static func groupedCrossValidation(
        points: [GazeCalibrationPoint],
        groups: [Int],
        source: GazeSource,
        basis: GazeBasis,
        geometry: ScreenGeometry,
        ridge: Double
    ) -> (accuracy: Double, worst: Double, perSample: Double)? {
        var total = 0.0
        var worst = 0.0
        var count = 0
        var accuracyTotal = 0.0
        var accuracyCount = 0

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
                inputRange: nil,
                scaling: solution.scaling,
                accuracyPoints: 0,
                accuracyDegrees: 0,
                worstTargetPoints: 0,
                perSampleErrorPoints: 0,
                inSampleAccuracyPoints: 0,
                precisionPoints: 0,
                sampleCount: training.count,
                targetCount: 0,
                meanCalibrationDistance: 0,
                calibratedDistanceRange: 0.1...1.0,
                createdAt: Date()
            )

            guard let score = error(of: fold, on: heldOut, geometry: geometry) else { return nil }
            total += score.mean * Double(heldOut.count)
            count += heldOut.count

            guard let centroid = accuracy(of: fold, on: heldOut, geometry: geometry) else { return nil }
            accuracyTotal += centroid.mean
            accuracyCount += 1
            worst = max(worst, centroid.worst)
        }

        guard count > 0, accuracyCount > 0 else { return nil }
        return (accuracyTotal / Double(accuracyCount), worst, total / Double(count))
    }

    /// Converts a screen error in points into the visual angle it subtends at the eye.
    static func degrees(points: Double, distance: Double, geometry: ScreenGeometry) -> Double {
        guard distance > 0, geometry.pointSize.width > 0 else { return 0 }
        let metresPerPoint = Double(geometry.physicalSize.width) / Double(geometry.pointSize.width)
        return atan(points * metresPerPoint / distance) * 180 / .pi
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
    /// v4: the model structure changed to head plus eye-in-head, and the axes were
    /// corrected. Older models would decode but predict nonsense, so they are not loaded.
    private static let key = "interactionFingerprint.gazeModel.v4"

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
