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

    /// A three by three grid, inset from the edges. Accuracy is worst at the extremes, and
    /// the corners of an iPhone display are partly obscured by the sensor housing and the
    /// home indicator.
    nonisolated public static let targets: [CGPoint] = {
        let positions: [Double] = [0.15, 0.5, 0.85]
        return positions.flatMap { y in positions.map { x in CGPoint(x: x, y: y) } }
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
        if let point = Self.reduce(
            samples: currentSamples,
            target: Self.targets[index],
            targetIndex: index
        ) {
            points.append(point)
        } else {
            failedTargets += 1
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

    /// Turns a burst of frames into one calibration point, or rejects it.
    ///
    /// Rejection matters more than it looks. A target where the person glanced away leaves
    /// a plausible looking median that is simply wrong, and one bad target out of nine can
    /// drag the whole fit. Requiring the burst to actually be a fixation catches that.
    nonisolated static func reduce(
        samples: [Sample],
        target: CGPoint,
        targetIndex: Int
    ) -> GazeCalibrationPoint? {
        guard samples.count >= minimumSamplesPerTarget else { return nil }

        let convergence = stableMeasurement(samples.compactMap(\.convergence))
        let perEye = stableMeasurement(samples.compactMap(\.perEye))
        guard convergence != nil || perEye != nil else { return nil }

        return GazeCalibrationPoint(
            target: target,
            targetIndex: targetIndex,
            convergence: convergence,
            perEye: perEye,
            headYaw: median(samples.map(\.headYaw)),
            headPitch: median(samples.map(\.headPitch))
        )
    }

    /// Median across the burst, but only if the burst was steady enough to be a fixation.
    nonisolated static func stableMeasurement(_ values: [GazeMeasurement]) -> GazeMeasurement? {
        guard values.count >= minimumSamplesPerTarget else { return nil }

        let us = values.map(\.u)
        let vs = values.map(\.v)
        guard medianAbsoluteDeviation(us) <= maximumAngularSpread,
              medianAbsoluteDeviation(vs) <= maximumAngularSpread
        else { return nil }

        return GazeMeasurement(
            u: median(us),
            v: median(vs),
            eyeX: median(values.map(\.eyeX)),
            eyeY: median(values.map(\.eyeY)),
            distance: median(values.map(\.distance))
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
