import CoreGraphics
import Foundation
import Observation

/// Drives calibration: check the setup, walk a grid of targets, then walk a smaller grid
/// at a deliberately different distance to prove the result survives the phone moving.
///
/// The second pass is never fitted. It is held back so the reported figure is a genuine
/// test of the failure mode that matters here, rather than a number the model was tuned
/// against.
///
/// Driven by frame timestamps rather than wall-clock timers, so it stays in step with the
/// tracking rate and is deterministic under test.
@MainActor
@Observable
public final class GazeCalibrationRun {

    public enum Phase: Equatable {
        /// Waiting for the person to be in a good position before starting.
        case readiness
        /// Fitting pass. Nine targets at whatever distance is comfortable.
        case fitting(index: Int)
        /// Prompt to change viewing distance before the check pass.
        case changeDistance
        /// Held-out pass at the new distance.
        case checking(index: Int)
        case finished(GazeCalibrationResult)
    }

    public struct GazeCalibrationResult: Equatable, Sendable {
        public let model: GazeModel?
        public let fitPoints: [GazeCalibrationPoint]
        public let checkPoints: [GazeCalibrationPoint]
        public let failedTargets: Int
    }

    nonisolated public static let settleDuration: TimeInterval = 0.9
    nonisolated public static let collectDuration: TimeInterval = 0.7
    nonisolated public static let readinessHoldDuration: TimeInterval = 0.8
    nonisolated public static let minimumSamplesPerTarget = 10
    /// How much the viewing distance must change before the check pass counts, in metres.
    nonisolated public static let requiredDistanceChange = 0.08

    /// Nine targets for the fit, inset from the edges. Accuracy is worst at the extremes,
    /// and the corners of an iPhone display are partly obscured by the sensor housing and
    /// the home indicator.
    nonisolated public static let fitTargets: [CGPoint] = {
        let positions: [Double] = [0.15, 0.5, 0.85]
        return positions.flatMap { y in positions.map { x in CGPoint(x: x, y: y) } }
    }()

    /// Four off-grid targets for the check, deliberately not reusing fit positions.
    nonisolated public static let checkTargets: [CGPoint] = [
        CGPoint(x: 0.30, y: 0.28),
        CGPoint(x: 0.72, y: 0.30),
        CGPoint(x: 0.28, y: 0.70),
        CGPoint(x: 0.70, y: 0.74),
    ]

    public private(set) var phase: Phase = .readiness
    public private(set) var quality: GazeQuality = .noFace
    public private(set) var currentSampleCount: Int = 0
    public private(set) var liveDistance: Double?

    private let geometry: ScreenGeometry
    private var phaseStartedAt: TimeInterval?
    private var readinessSince: TimeInterval?
    private var currentSamples: [GazeSampleForCalibration] = []
    private var fitPoints: [GazeCalibrationPoint] = []
    private var checkPoints: [GazeCalibrationPoint] = []
    private var failedTargets = 0
    private var fitPassMeanDistance: Double?

    public init(geometry: ScreenGeometry) {
        self.geometry = geometry
    }

    // MARK: Derived

    public var currentTarget: CGPoint? {
        switch phase {
        case .fitting(let index):
            Self.fitTargets.indices.contains(index) ? Self.fitTargets[index] : nil
        case .checking(let index):
            Self.checkTargets.indices.contains(index) ? Self.checkTargets[index] : nil
        default:
            nil
        }
    }

    public var isCollecting: Bool {
        guard let start = phaseStartedAt, let now = lastTimestamp else { return false }
        switch phase {
        case .fitting, .checking: return now - start >= Self.settleDuration
        default: return false
        }
    }

    public var stepLabel: String? {
        switch phase {
        case .fitting(let index): "\(index + 1) of \(Self.fitTargets.count)"
        case .checking(let index): "\(index + 1) of \(Self.checkTargets.count)"
        default: nil
        }
    }

    public var progress: Double {
        let total = Double(Self.fitTargets.count + Self.checkTargets.count)
        switch phase {
        case .readiness: return 0
        case .fitting(let index): return Double(index) / total
        case .changeDistance: return Double(Self.fitTargets.count) / total
        case .checking(let index): return Double(Self.fitTargets.count + index) / total
        case .finished: return 1
        }
    }

    /// How far the current distance is from the fitting pass, in metres. Drives the
    /// prompt on the change-distance step.
    public var distanceChange: Double? {
        guard let base = fitPassMeanDistance, let live = liveDistance else { return nil }
        return abs(live - base)
    }

    private var lastTimestamp: TimeInterval?

    // MARK: Input

    public struct GazeSampleForCalibration: Sendable, Equatable {
        public let convergence: GazeMeasurement?
        public let perEye: GazeMeasurement?
        public let headYaw: Double
        public let headPitch: Double

        public init(
            convergence: GazeMeasurement?,
            perEye: GazeMeasurement?,
            headYaw: Double,
            headPitch: Double
        ) {
            self.convergence = convergence
            self.perEye = perEye
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
        fitPoints = []
        checkPoints = []
        failedTargets = 0
        fitPassMeanDistance = nil
    }

    /// Feed one tracking frame.
    public func receive(
        sample: GazeSampleForCalibration?,
        quality: GazeQuality,
        timestamp: TimeInterval
    ) {
        lastTimestamp = timestamp
        self.quality = quality
        liveDistance = sample?.convergence?.distance ?? sample?.perEye?.distance

        switch phase {
        case .readiness:
            advanceReadiness(quality: quality, timestamp: timestamp)
        case .changeDistance:
            advanceChangeDistance(quality: quality, timestamp: timestamp)
        case .fitting(let index):
            collect(sample: sample, quality: quality, timestamp: timestamp, index: index, isCheck: false)
        case .checking(let index):
            collect(sample: sample, quality: quality, timestamp: timestamp, index: index, isCheck: true)
        case .finished:
            break
        }
    }

    // MARK: Phases

    private func advanceReadiness(quality: GazeQuality, timestamp: TimeInterval) {
        // Anything other than an uncalibrated-but-otherwise-fine frame resets the hold,
        // so the person has actually settled before the first target appears.
        let acceptable = quality == .good || quality == .notCalibrated
            || isOutsideRange(quality)
        guard acceptable else {
            readinessSince = nil
            return
        }
        let since = readinessSince ?? timestamp
        readinessSince = since
        if timestamp - since >= Self.readinessHoldDuration {
            readinessSince = nil
            phaseStartedAt = timestamp
            phase = .fitting(index: 0)
        }
    }

    private func advanceChangeDistance(quality: GazeQuality, timestamp: TimeInterval) {
        guard let change = distanceChange, change >= Self.requiredDistanceChange else {
            readinessSince = nil
            return
        }
        let acceptable = quality == .good || quality == .notCalibrated || isOutsideRange(quality)
        guard acceptable else {
            readinessSince = nil
            return
        }
        let since = readinessSince ?? timestamp
        readinessSince = since
        if timestamp - since >= Self.readinessHoldDuration {
            readinessSince = nil
            phaseStartedAt = timestamp
            phase = .checking(index: 0)
        }
    }

    private func isOutsideRange(_ quality: GazeQuality) -> Bool {
        if case .outsideCalibratedRange = quality { return true }
        return false
    }

    private func collect(
        sample: GazeSampleForCalibration?,
        quality: GazeQuality,
        timestamp: TimeInterval,
        index: Int,
        isCheck: Bool
    ) {
        let start = phaseStartedAt ?? timestamp
        if phaseStartedAt == nil { phaseStartedAt = timestamp }
        let elapsed = timestamp - start

        guard elapsed >= Self.settleDuration else { return }

        // Blinks and dropouts are simply not banked. The burst is long enough to survive
        // a blink without failing the target.
        if let sample, quality.isUsable {
            currentSamples.append(sample)
            currentSampleCount = currentSamples.count
        }

        guard elapsed >= Self.settleDuration + Self.collectDuration else { return }
        finishTarget(index, isCheck: isCheck, timestamp: timestamp)
    }

    private func finishTarget(_ index: Int, isCheck: Bool, timestamp: TimeInterval) {
        let targets = isCheck ? Self.checkTargets : Self.fitTargets

        if currentSamples.count >= Self.minimumSamplesPerTarget {
            let point = GazeCalibrationPoint(
                target: targets[index],
                convergence: Self.medianMeasurement(currentSamples.compactMap(\.convergence)),
                perEye: Self.medianMeasurement(currentSamples.compactMap(\.perEye)),
                headYaw: Self.median(currentSamples.map(\.headYaw)),
                headPitch: Self.median(currentSamples.map(\.headPitch))
            )
            if isCheck { checkPoints.append(point) } else { fitPoints.append(point) }
        } else {
            failedTargets += 1
        }

        currentSamples = []
        currentSampleCount = 0

        let next = index + 1
        if next < targets.count {
            phase = isCheck ? .checking(index: next) : .fitting(index: next)
            phaseStartedAt = timestamp
            return
        }

        if isCheck {
            finish()
        } else {
            let distances = fitPoints.compactMap { $0.convergence?.distance ?? $0.perEye?.distance }
            fitPassMeanDistance = distances.isEmpty ? nil : distances.reduce(0, +) / Double(distances.count)
            phase = .changeDistance
            phaseStartedAt = nil
            readinessSince = nil
        }
    }

    private func finish() {
        var model = GazeModelFitter.best(points: fitPoints, geometry: geometry)

        // The check pass never influences the fit. It only reports how the fit holds up
        // once the phone has moved.
        if let fitted = model,
           let check = GazeModelFitter.error(of: fitted, on: checkPoints, geometry: geometry) {
            let distances = checkPoints.compactMap {
                $0.measurement(for: fitted.source)?.distance
            }
            let meanDistance = distances.isEmpty
                ? nil
                : distances.reduce(0, +) / Double(distances.count)

            model = GazeModel(
                source: fitted.source,
                basis: fitted.basis,
                uCoefficients: fitted.uCoefficients,
                vCoefficients: fitted.vCoefficients,
                ridge: fitted.ridge,
                heldOutErrorPoints: fitted.heldOutErrorPoints,
                worstHeldOutErrorPoints: fitted.worstHeldOutErrorPoints,
                targetCount: fitted.targetCount,
                calibratedDistanceRange: fitted.calibratedDistanceRange,
                distanceCheckErrorPoints: check.mean,
                distanceCheckDistance: meanDistance,
                createdAt: fitted.createdAt
            )
        }

        phase = .finished(
            GazeCalibrationResult(
                model: model,
                fitPoints: fitPoints,
                checkPoints: checkPoints,
                failedTargets: failedTargets
            )
        )
        phaseStartedAt = nil
    }

    // MARK: Robust averaging

    /// Median rather than mean: one stray frame from a blink or a head turn would drag a
    /// mean noticeably, and a median ignores it.
    nonisolated static func medianMeasurement(_ values: [GazeMeasurement]) -> GazeMeasurement? {
        guard !values.isEmpty else { return nil }
        return GazeMeasurement(
            u: median(values.map(\.u)),
            v: median(values.map(\.v)),
            eyeX: median(values.map(\.eyeX)),
            eyeY: median(values.map(\.eyeY)),
            distance: median(values.map(\.distance))
        )
    }

    nonisolated static func median(_ values: [Double]) -> Double {
        precondition(!values.isEmpty)
        let sorted = values.sorted()
        let count = sorted.count
        if count % 2 == 1 { return sorted[count / 2] }
        return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
    }
}
