import CoreGraphics
import Foundation
import Observation

/// Drives a nine point calibration: show a target, let the eyes settle, collect a burst
/// of samples, move on, then fit.
///
/// The state machine is driven by frame timestamps rather than wall-clock timers so that
/// it stays in step with the tracking rate and is deterministic in tests.
@MainActor
@Observable
public final class GazeCalibrationRun {

    public enum Phase: Equatable {
        case idle
        /// Target shown, waiting for the eyes to land on it.
        case settling(index: Int)
        /// Recording samples for the current target.
        case collecting(index: Int)
        case finished(GazeCalibration?)
    }

    /// Seconds to let the gaze settle before recording.
    public static let settleDuration: TimeInterval = 1.1
    /// Seconds of samples per target.
    public static let collectDuration: TimeInterval = 0.6
    /// Below this many usable samples the target is treated as failed.
    public static let minimumSamplesPerTarget = 8

    /// A three by three grid, inset from the edges. Accuracy is worst at the extremes,
    /// and the corners of an iPhone display are partly obscured by the sensor housing
    /// and the home indicator.
    public static let defaultTargets: [CGPoint] = {
        let positions: [Double] = [0.15, 0.5, 0.85]
        return positions.flatMap { y in positions.map { x in CGPoint(x: x, y: y) } }
    }()

    public private(set) var phase: Phase = .idle
    public let targets: [CGPoint]

    /// Samples banked for the current target, for the progress ring.
    public private(set) var currentSampleCount: Int = 0
    /// Targets that yielded too few usable samples. Surfaced so the user is told which
    /// part of the screen failed rather than just being handed a bad fit.
    public private(set) var failedTargetIndices: [Int] = []

    private var phaseStartedAt: TimeInterval?
    private var currentSamples: [CGPoint] = []
    private var observations: [GazeCalibrationFitter.Observation] = []
    private let screenPointSize: CGSize

    public init(targets: [CGPoint] = GazeCalibrationRun.defaultTargets, screenPointSize: CGSize) {
        self.targets = targets
        self.screenPointSize = screenPointSize
    }

    public var currentTarget: CGPoint? {
        switch phase {
        case .settling(let index), .collecting(let index):
            targets.indices.contains(index) ? targets[index] : nil
        default:
            nil
        }
    }

    public var currentIndex: Int? {
        switch phase {
        case .settling(let index), .collecting(let index): index
        default: nil
        }
    }

    /// 0...1 across the whole run, for a progress bar.
    public var progress: Double {
        guard let index = currentIndex, !targets.isEmpty else {
            if case .finished = phase { return 1 }
            return 0
        }
        return Double(index) / Double(targets.count)
    }

    public func begin() {
        observations = []
        currentSamples = []
        failedTargetIndices = []
        currentSampleCount = 0
        phaseStartedAt = nil
        phase = targets.isEmpty ? .finished(nil) : .settling(index: 0)
    }

    public func cancel() {
        phase = .idle
        phaseStartedAt = nil
        currentSamples = []
        currentSampleCount = 0
    }

    /// Feed one tracking frame. `raw` is the screen-plane intersection in metres, or nil
    /// when the face is not tracked.
    public func receive(raw: CGPoint?, eyesOpen: Bool, timestamp: TimeInterval) {
        guard let index = currentIndex else { return }

        let start = phaseStartedAt ?? timestamp
        if phaseStartedAt == nil { phaseStartedAt = timestamp }
        let elapsed = timestamp - start

        switch phase {
        case .settling:
            if elapsed >= Self.settleDuration {
                phase = .collecting(index: index)
                phaseStartedAt = timestamp
                currentSamples = []
                currentSampleCount = 0
            }

        case .collecting:
            // Blinks and dropouts are simply not banked. The burst is long enough to
            // survive a blink without failing the target.
            if let raw, eyesOpen {
                currentSamples.append(raw)
                currentSampleCount = currentSamples.count
            }
            if elapsed >= Self.collectDuration {
                finishTarget(index)
            }

        case .idle, .finished:
            break
        }
    }

    private func finishTarget(_ index: Int) {
        if currentSamples.count >= Self.minimumSamplesPerTarget {
            // Median rather than mean: one stray frame from a blink or a head turn
            // would drag a mean noticeably, and a median ignores it.
            observations.append(
                GazeCalibrationFitter.Observation(
                    raw: Self.median(of: currentSamples),
                    target: targets[index]
                )
            )
        } else {
            failedTargetIndices.append(index)
        }

        currentSamples = []
        currentSampleCount = 0

        let next = index + 1
        if next < targets.count {
            phase = .settling(index: next)
            phaseStartedAt = nil
        } else {
            let fit = GazeCalibrationFitter.fit(observations, screenPointSize: screenPointSize)
            phase = .finished(fit)
            phaseStartedAt = nil
        }
    }

    nonisolated static func median(of points: [CGPoint]) -> CGPoint {
        precondition(!points.isEmpty)
        let xs = points.map(\.x).sorted()
        let ys = points.map(\.y).sorted()
        return CGPoint(x: median(of: xs), y: median(of: ys))
    }

    nonisolated private static func median(of sorted: [CGFloat]) -> CGFloat {
        let count = sorted.count
        if count % 2 == 1 { return sorted[count / 2] }
        return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
    }
}
