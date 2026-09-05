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
/// Three independent choices, all decided by cross-validation rather than by assumption:
///
/// - `order` 1 or 2. A quadratic can follow the mild curvature that appears towards the
///   edges of the display, at the cost of twice the parameters.
/// - `solvesCameraOffset`. Also solves where the camera really sits relative to the
///   display. That is a fixed distance while the eye's own error is a fixed angle, and the
///   two only separate when the data spans more than one viewing distance.
/// - `usesHeadPose`. Adds head yaw and pitch as terms. ARKit's eye estimate degrades as the
///   head turns away from the camera, and if that degradation is systematic it can be
///   corrected. Only offered when the head pose actually varied during calibration.
/// - `usesEyeLook`. Adds ARKit's eye-direction blend shapes, folded into a horizontal and a
///   vertical term, as a second readout of gaze from the same model. Offered only when they
///   varied during calibration, and kept only if they lower held-out error.
public struct GazeBasis: Codable, Sendable, Equatable, Hashable {
    public let order: Int
    public let solvesCameraOffset: Bool
    public let usesHeadPose: Bool
    public let usesEyeLook: Bool

    public init(order: Int, solvesCameraOffset: Bool, usesHeadPose: Bool, usesEyeLook: Bool = false) {
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

    public static let allCases: [GazeBasis] = [1, 2].flatMap { order in
        [false, true].flatMap { offset in
            [false, true].flatMap { pose in
                [false, true].map { look in
                    GazeBasis(order: order, solvesCameraOffset: offset, usesHeadPose: pose, usesEyeLook: look)
                }
            }
        }
    }

    var angularTermCount: Int {
        (order == 2 ? 6 : 3) + (usesHeadPose ? 2 : 0) + (usesEyeLook ? 2 : 0)
    }

    public var parameterCount: Int {
        angularTermCount + (solvesCameraOffset ? 1 : 0)
    }

    public var label: String {
        var parts = [order == 2 ? "quadratic" : "linear"]
        if solvesCameraOffset { parts.append("camera") }
        if usesHeadPose { parts.append("pose") }
        if usesEyeLook { parts.append("look") }
        return parts.joined(separator: "+")
    }

    /// The terms that make up the corrected gaze angle.
    ///
    /// `boundedU` and `boundedV` feed the quadratic terms and default to the raw inputs.
    /// At prediction time the model passes versions clamped to the calibrated range, so
    /// the linear part may extrapolate off the edge of the display while the curvature,
    /// which is only known inside the grid, saturates. See `GazeModel.correct`.
    func angularTerms(
        u: Double, v: Double, yaw: Double, pitch: Double,
        lookU: Double = 0, lookV: Double = 0,
        boundedU: Double? = nil, boundedV: Double? = nil
    ) -> [Double] {
        let qu = boundedU ?? u
        let qv = boundedV ?? v
        var terms: [Double] = order == 2 ? [1, u, v, qu * qu, qv * qv, qu * qv] : [1, u, v]
        if usesHeadPose {
            terms.append(yaw)
            terms.append(pitch)
        }
        if usesEyeLook {
            terms.append(lookU)
            terms.append(lookV)
        }
        return terms
    }

    /// One row of the fitting matrix. The camera position enters as a term in one over the
    /// distance, which keeps it linear in the unknowns.
    func designRow(for m: GazeMeasurement) -> [Double] {
        var row = angularTerms(
            u: m.u, v: m.v, yaw: m.headYaw, pitch: m.headPitch, lookU: m.lookU, lookV: m.lookV
        )
        if solvesCameraOffset { row.append(-1 / m.distance) }
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
    /// Head orientation when this was measured. Carried on the measurement because the
    /// correction may depend on it, so prediction needs it as well as fitting.
    public let headYaw: Double
    public let headPitch: Double
    /// ARKit's eye-direction blend shapes folded to one horizontal and one vertical term.
    /// Zero when they were not captured.
    public let lookU: Double
    public let lookV: Double

    public init(
        u: Double, v: Double, eyeX: Double, eyeY: Double, distance: Double,
        headYaw: Double = 0, headPitch: Double = 0,
        lookU: Double = 0, lookV: Double = 0
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
    }

    public init?(
        _ estimate: GazeRay.Estimate,
        headYaw: Double = 0, headPitch: Double = 0,
        lookU: Double = 0, lookV: Double = 0
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
            lookV: lookV
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

    public init?(measurements: [GazeMeasurement]) {
        guard !measurements.isEmpty else { return nil }
        func span(_ values: [Double]) -> ClosedRange<Double> {
            (values.min() ?? 0)...(values.max() ?? 0)
        }
        self.init(
            u: span(measurements.map(\.u)), v: span(measurements.map(\.v)),
            yaw: span(measurements.map(\.headYaw)), pitch: span(measurements.map(\.headPitch)),
            lookU: span(measurements.map(\.lookU)), lookV: span(measurements.map(\.lookV))
        )
    }

    /// Holds a value inside the calibrated span plus margin.
    public static func bound(_ value: Double, to range: ClosedRange<Double>) -> Double {
        let slack = (range.upperBound - range.lowerBound) * margin
        return min(max(value, range.lowerBound - slack), range.upperBound + slack)
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

    /// The linear terms are free to extrapolate: an angular model is exactly the kind of
    /// thing that should still be right a little beyond the grid. Everything else, the
    /// curvature, the head-pose and the eye-shape terms, is held at the edge of what was
    /// seen during calibration, because outside that range it is unknown, and an unknown
    /// multiplied by a large coefficient is how a dot ends up three screens to the right.
    public func correct(
        u: Double, v: Double, yaw: Double = 0, pitch: Double = 0,
        lookU: Double = 0, lookV: Double = 0
    ) -> (u: Double, v: Double) {
        let terms: [Double]
        if let r = inputRange {
            terms = basis.angularTerms(
                u: u, v: v,
                yaw: GazeInputRange.bound(yaw, to: r.yaw),
                pitch: GazeInputRange.bound(pitch, to: r.pitch),
                lookU: GazeInputRange.bound(lookU, to: r.lookU),
                lookV: GazeInputRange.bound(lookV, to: r.lookV),
                boundedU: GazeInputRange.bound(u, to: r.u),
                boundedV: GazeInputRange.bound(v, to: r.v)
            )
        } else {
            terms = basis.angularTerms(u: u, v: v, yaw: yaw, pitch: pitch, lookU: lookU, lookV: lookV)
        }
        return (
            u: zip(terms, uCoefficients).reduce(0) { $0 + $1.0 * $1.1 },
            v: zip(terms, vCoefficients).reduce(0) { $0 + $1.0 * $1.1 }
        )
    }

    /// Where the corrected gaze lands, in nominal camera-space metres, with the solved
    /// camera position already taken out so the result can go straight into `ScreenGeometry`.
    public func screenPlaneHit(for measurement: GazeMeasurement) -> CGPoint {
        let corrected = correct(
            u: measurement.u, v: measurement.v,
            yaw: measurement.headYaw, pitch: measurement.headPitch,
            lookU: measurement.lookU, lookV: measurement.lookV
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

    /// Shrinkage strengths tried for every model shape. Zero is included so an
    /// unregularised fit can win when the data genuinely supports it.
    static let ridgeGrid: [Double] = [0, 1e-5, 1e-4, 1e-3, 1e-2, 1e-1]

    /// Minimum spread in one over the distance before the camera position can be solved.
    /// Roughly six centimetres of movement at normal holding distances.
    static let minimumInverseDistanceSpread = 0.25

    /// Minimum head rotation range, in radians, before pose terms are offered. About 6°.
    ///
    /// Was 1.7°, and that was the cause of the first recording's wild dot: pose
    /// coefficients fitted on two degrees of variation, then evaluated on the ten degrees a
    /// head and a hand produce in use. Head pose changes relative to the camera whenever
    /// the phone turns, so an unbounded pose term is also a phone-motion amplifier.
    static let minimumHeadPoseSpread = 0.10

    /// Minimum range of the folded eye-direction blend shapes, on their 0...1 scale, before
    /// they are offered as inputs. Below this they were not captured or did not move.
    static let minimumEyeLookSpread = 0.15

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

            let yaws = usable.compactMap { $0.measurement(for: source)?.headYaw }
            let pitches = usable.compactMap { $0.measurement(for: source)?.headPitch }
            let poseSpread = max(
                (yaws.max() ?? 0) - (yaws.min() ?? 0),
                (pitches.max() ?? 0) - (pitches.min() ?? 0)
            )

            let looksU = usable.compactMap { $0.measurement(for: source)?.lookU }
            let looksV = usable.compactMap { $0.measurement(for: source)?.lookV }
            let lookSpread = max(
                (looksU.max() ?? 0) - (looksU.min() ?? 0),
                (looksV.max() ?? 0) - (looksV.min() ?? 0)
            )

            let inputRange = GazeInputRange(measurements: usable.compactMap { $0.measurement(for: source) })

            for basis in GazeBasis.allCases {
                // Solving for the camera position needs real distance variation, otherwise
                // it is indistinguishable from a constant angular offset.
                if basis.solvesCameraOffset, inverseSpread < minimumInverseDistanceSpread { continue }
                // Head pose terms are only identifiable if the head actually moved. Fitting
                // them to a constant would just add noise dressed up as signal.
                if basis.usesHeadPose, poseSpread < minimumHeadPoseSpread { continue }
                // Likewise the eye-direction shapes: a column that never moved is noise.
                if basis.usesEyeLook, lookSpread < minimumEyeLookSpread { continue }
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
        guard let winner = rank(points: points, geometry: geometry).first?.model else { return nil }
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
            design.append(basis.designRow(for: measurement))
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
