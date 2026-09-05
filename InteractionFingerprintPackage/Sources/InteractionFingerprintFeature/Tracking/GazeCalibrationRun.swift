import CoreGraphics
import Foundation
import Observation

/// Drives calibration: check the setup, walk a grid of targets, ask the person to change
/// viewing distance, then walk the same grid again.
///
/// Visiting the same grid twice at two distances is not redundancy. It is the only way to
/// tell a fixed angular error, which belongs to the person, apart from a fixed positional
/// error, which is where the camera actually sits relative to the display. At a single
/// distance the two look identical, and the fit silently blends them into something that
/// only works at that distance.
///
/// Driven by frame timestamps rather than wall-clock timers, so it stays in step with the
/// tracking rate and is deterministic under test.
@MainActor
@Observable
public final class GazeCalibrationRun {

    public enum Phase: Equatable {
        case readiness
        case near(index: Int)
        case changeDistance
        case far(index: Int)
        case finished(Result)
    }

    public struct Result: Equatable, Sendable {
        public let model: GazeModel?
        public let points: [GazeCalibrationPoint]
        public let failedTargets: Int
    }

    nonisolated public static let settleDuration: TimeInterval = 0.65
    nonisolated public static let collectDuration: TimeInterval = 0.55
    nonisolated public static let readinessHoldDuration: TimeInterval = 0.7
    nonisolated public static let minimumSamplesPerTarget = 8
    /// How much the viewing distance must change between passes, in metres.
    nonisolated public static let requiredDistanceChange = 0.09
    /// Largest median absolute deviation in gaze angle that still counts as a fixation.
    /// Beyond this the person was not actually holding still and the target is discarded
    /// rather than allowed to poison the fit.
    nonisolated public static let maximumAngularSpread = 0.030

    /// Three columns by four rows, inset from the edges.
    ///
    /// Taller than it is wide because the display is, and because the areas of interest in
    /// the study stack vertically. Coverage is what lets a quadratic correction follow the
    /// curvature near the edges instead of extrapolating into it. The insets keep targets
    /// clear of the sensor housing and the home indicator.
    nonisolated public static let targets: [CGPoint] = {
        let columns: [Double] = [0.15, 0.5, 0.85]
        let rows: [Double] = [0.15, 0.38, 0.62, 0.85]
        return rows.flatMap { y in columns.map { x in CGPoint(x: x, y: y) } }
    }()

    public private(set) var phase: Phase = .readiness
    public private(set) var quality: GazeQuality = .noFace
    public private(set) var currentSampleCount: Int = 0
    public private(set) var liveDistance: Double?

    private let geometry: ScreenGeometry
    private var phaseStartedAt: TimeInterval?
    private var readinessSince: TimeInterval?
    private var currentSamples: [Sample] = []
    private var points: [GazeCalibrationPoint] = []
    private var failedTargets = 0
    private var nearPassMeanDistance: Double?
    private var lastTimestamp: TimeInterval?

    public init(geometry: ScreenGeometry) {
        self.geometry = geometry
    }

    // MARK: Derived

    public var currentTarget: CGPoint? {
        currentIndex.map { Self.targets[$0] }
    }

    public var currentIndex: Int? {
        switch phase {
        case .near(let index), .far(let index):
            Self.targets.indices.contains(index) ? index : nil
        default:
            nil
        }
    }

    public var isCollecting: Bool {
        guard let start = phaseStartedAt, let now = lastTimestamp, currentIndex != nil else {
            return false
        }
        return now - start >= Self.settleDuration
    }

    public var stepLabel: String? {
        switch phase {
        case .near(let index): "\(index + 1) of \(Self.targets.count) · first distance"
        case .far(let index): "\(index + 1) of \(Self.targets.count) · second distance"
        default: nil
        }
    }

    public var progress: Double {
        let total = Double(Self.targets.count * 2)
        switch phase {
        case .readiness: return 0
        case .near(let index): return Double(index) / total
        case .changeDistance: return Double(Self.targets.count) / total
        case .far(let index): return Double(Self.targets.count + index) / total
        case .finished: return 1
        }
    }

    /// How far the current distance is from the first pass, in metres.
    public var distanceChange: Double? {
        guard let base = nearPassMeanDistance, let live = liveDistance else { return nil }
        return abs(live - base)
    }

    // MARK: Input

    public struct Sample: Sendable, Equatable {
        public let convergence: GazeMeasurement?
        public let perEye: GazeMeasurement?
        /// Pupil-landmark gaze, when Vision found the face on this frame.
        public let pupil: GazeMeasurement?
        public let headYaw: Double
        public let headPitch: Double

        public init(
            convergence: GazeMeasurement?,
            perEye: GazeMeasurement?,
            headYaw: Double,
            headPitch: Double,
            pupil: GazeMeasurement? = nil
        ) {
            self.convergence = convergence
            self.perEye = perEye
            self.pupil = pupil
            self.headYaw = headYaw
            self.headPitch = headPitch
        }
    }

    public func cancel() {
        phase = .readiness
        phaseStartedAt = nil
        readinessSince = nil
        currentSamples = []
        currentSampleCount = 0
        points = []
        failedTargets = 0
        nearPassMeanDistance = nil
    }

    /// Feed one tracking frame.
    public func receive(sample: Sample?, quality: GazeQuality, timestamp: TimeInterval) {
        lastTimestamp = timestamp
        self.quality = quality
        liveDistance = sample?.convergence?.distance ?? sample?.perEye?.distance

        switch phase {
        case .readiness:
            advanceReadiness(quality: quality, timestamp: timestamp, requireDistanceChange: false)
        case .changeDistance:
            advanceReadiness(quality: quality, timestamp: timestamp, requireDistanceChange: true)
        case .near(let index):
            collect(sample: sample, quality: quality, timestamp: timestamp, index: index, isFar: false)
        case .far(let index):
            collect(sample: sample, quality: quality, timestamp: timestamp, index: index, isFar: true)
        case .finished:
            break
        }
    }

    // MARK: Phases

    private func advanceReadiness(
        quality: GazeQuality,
        timestamp: TimeInterval,
        requireDistanceChange: Bool
    ) {
        if requireDistanceChange {
            guard let change = distanceChange, change >= Self.requiredDistanceChange else {
                readinessSince = nil
                return
            }
        }
        // An uncalibrated frame is expected here, and a frame outside a previous
        // calibration's range is irrelevant while building a new one.
        guard quality.isUsable else {
            readinessSince = nil
            return
        }
        let since = readinessSince ?? timestamp
        readinessSince = since
        guard timestamp - since >= Self.readinessHoldDuration else { return }

        readinessSince = nil
        phaseStartedAt = timestamp
        phase = requireDistanceChange ? .far(index: 0) : .near(index: 0)
    }

    private func collect(
        sample: Sample?,
        quality: GazeQuality,
        timestamp: TimeInterval,
        index: Int,
        isFar: Bool
    ) {
        let start = phaseStartedAt ?? timestamp
        if phaseStartedAt == nil { phaseStartedAt = timestamp }
        let elapsed = timestamp - start

        guard elapsed >= Self.settleDuration else { return }

        // Blinks and dropouts are simply not banked. The burst is long enough to survive a
        // blink without failing the target.
        if let sample, quality.isUsable {
            currentSamples.append(sample)
            currentSampleCount = currentSamples.count
        }

        guard elapsed >= Self.settleDuration + Self.collectDuration else { return }
        finishTarget(index, isFar: isFar, timestamp: timestamp)
    }

    private func finishTarget(_ index: Int, isFar: Bool, timestamp: TimeInterval) {
        let produced = Self.reduce(
            samples: currentSamples,
            target: Self.targets[index],
            targetIndex: index
        )
        if produced.isEmpty {
            failedTargets += 1
        } else {
            points.append(contentsOf: produced)
        }

        currentSamples = []
        currentSampleCount = 0

        let next = index + 1
        if next < Self.targets.count {
            phase = isFar ? .far(index: next) : .near(index: next)
            phaseStartedAt = timestamp
            return
        }

        if isFar {
            finish()
        } else {
            let distances = points.compactMap { $0.convergence?.distance ?? $0.perEye?.distance }
            nearPassMeanDistance = distances.isEmpty
                ? nil
                : distances.reduce(0, +) / Double(distances.count)
            phase = .changeDistance
            phaseStartedAt = nil
            readinessSince = nil
        }
    }

    private func finish() {
        phase = .finished(
            Result(
                model: GazeModelFitter.best(points: points, geometry: geometry),
                points: points,
                failedTargets: failedTargets
            )
        )
        phaseStartedAt = nil
    }

    // MARK: Robust reduction

    /// How far from the burst median a frame may sit before it is discarded, as a multiple
    /// of the median absolute deviation.
    nonisolated static let outlierCutoff = 3.0
    /// Floor under the measured spread, in gaze angle ratio units, roughly a tenth of a
    /// degree. Without it a very steady burst has a spread of zero and outlier rejection
    /// silently switches itself off, letting a single wild frame through untouched.
    nonisolated static let minimumSpread = 0.002

    /// Turns a burst of frames into calibration points, or rejects the target entirely.
    ///
    /// Every surviving frame becomes its own point rather than being collapsed to a single
    /// median. Reducing a burst of roughly thirty frames to one number throws away almost
    /// all of the calibration data, and the published smartphone gaze work is explicit that
    /// personalisation needs on the order of a hundred frames before it starts to help.
    /// Nine targets gave nine numbers. Nine targets now give several hundred.
    ///
    /// Rejection still happens at the level of the whole target. A target where the person
    /// glanced away leaves a plausible looking cluster that is simply wrong, and no amount
    /// of extra frames fixes that.
    nonisolated static func reduce(
        samples: [Sample],
        target: CGPoint,
        targetIndex: Int
    ) -> [GazeCalibrationPoint] {
        guard samples.count >= minimumSamplesPerTarget else { return [] }

        let convergence = samples.compactMap(\.convergence)
        let perEye = samples.compactMap(\.perEye)
        guard isFixation(convergence) || isFixation(perEye) else { return [] }

        let keepConvergence = isFixation(convergence)
        let keepPerEye = isFixation(perEye)

        var result: [GazeCalibrationPoint] = []
        result.reserveCapacity(samples.count)

        let convergenceCentre = keepConvergence ? centre(convergence) : nil
        let perEyeCentre = keepPerEye ? centre(perEye) : nil
        let convergenceSpread = keepConvergence ? spread(convergence) : 0
        let perEyeSpread = keepPerEye ? spread(perEye) : 0

        for sample in samples {
            let c = keepConvergence
                ? accept(sample.convergence, centre: convergenceCentre, spread: convergenceSpread)
                : nil
            let p = keepPerEye
                ? accept(sample.perEye, centre: perEyeCentre, spread: perEyeSpread)
                : nil
            guard c != nil || p != nil else { continue }
            result.append(
                GazeCalibrationPoint(
                    target: target,
                    targetIndex: targetIndex,
                    convergence: c,
                    perEye: p,
                    headYaw: sample.headYaw,
                    headPitch: sample.headPitch,
                    // The pupil reading rides on the frames the ARKit fixation gate kept.
                    pupil: sample.pupil
                )
            )
        }

        return result.count >= minimumSamplesPerTarget ? result : []
    }

    /// Drops a frame that sits far from the rest of its burst.
    nonisolated private static func accept(
        _ measurement: GazeMeasurement?,
        centre: (u: Double, v: Double)?,
        spread: Double
    ) -> GazeMeasurement? {
        guard let measurement, let centre else { return nil }
        let distance = ((measurement.u - centre.u) * (measurement.u - centre.u)
            + (measurement.v - centre.v) * (measurement.v - centre.v)).squareRoot()
        return distance <= outlierCutoff * max(spread, minimumSpread) ? measurement : nil
    }

    /// Was this burst actually a fixation, or did the eyes wander during it?
    nonisolated static func isFixation(_ values: [GazeMeasurement]) -> Bool {
        guard values.count >= minimumSamplesPerTarget else { return false }
        return medianAbsoluteDeviation(values.map(\.u)) <= maximumAngularSpread
            && medianAbsoluteDeviation(values.map(\.v)) <= maximumAngularSpread
    }

    nonisolated static func centre(_ values: [GazeMeasurement]) -> (u: Double, v: Double) {
        (median(values.map(\.u)), median(values.map(\.v)))
    }

    nonisolated static func spread(_ values: [GazeMeasurement]) -> Double {
        max(
            medianAbsoluteDeviation(values.map(\.u)),
            medianAbsoluteDeviation(values.map(\.v))
        )
    }

    /// Median absolute deviation: a spread measure that a single stray frame cannot inflate,
    /// unlike a standard deviation.
    nonisolated static func medianAbsoluteDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .infinity }
        let centre = median(values)
        return median(values.map { abs($0 - centre) })
    }

    nonisolated static func median(_ values: [Double]) -> Double {
        precondition(!values.isEmpty)
        let sorted = values.sorted()
        let count = sorted.count
        if count % 2 == 1 { return sorted[count / 2] }
        return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
    }
}
