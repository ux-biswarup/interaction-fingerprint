import Foundation

/// One Euro filter, the standard low-latency filter for noisy interactive signals.
///
/// A fixed exponential average forces a bad trade: smooth enough to stop the jitter
/// means visible lag when the eyes move. This filter varies its cutoff with speed, so
/// it smooths hard while the gaze is still and gets out of the way during a saccade.
///
/// Casiez, Roussel and Vogel, "1 Euro Filter", CHI 2012.
///
/// Display only. Recorded samples stay unfiltered so that analysis can detect
/// fixations and saccades from the true signal.
struct OneEuroFilter {
    /// Minimum cutoff frequency in Hz. Lower means steadier when still.
    var minCutoff: Double
    /// Speed coefficient. Higher means more responsive during fast movement.
    var beta: Double
    /// Cutoff for the derivative estimate.
    var derivativeCutoff: Double

    private var previousValue: Double?
    private var previousDerivative: Double = 0
    private var previousTimestamp: TimeInterval?

    init(minCutoff: Double = 1.0, beta: Double = 0.7, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    mutating func reset() {
        previousValue = nil
        previousDerivative = 0
        previousTimestamp = nil
    }

    mutating func filter(_ value: Double, timestamp: TimeInterval) -> Double {
        guard let last = previousValue, let lastTime = previousTimestamp else {
            previousValue = value
            previousTimestamp = timestamp
            return value
        }

        let elapsed = timestamp - lastTime
        guard elapsed > 0 else { return last }
        let rate = 1 / elapsed

        let derivative = (value - last) * rate
        let smoothedDerivative = Self.exponential(
            derivative,
            previous: previousDerivative,
            alpha: Self.alpha(cutoff: derivativeCutoff, rate: rate)
        )

        let cutoff = minCutoff + beta * abs(smoothedDerivative)
        let result = Self.exponential(
            value,
            previous: last,
            alpha: Self.alpha(cutoff: cutoff, rate: rate)
        )

        previousValue = result
        previousDerivative = smoothedDerivative
        previousTimestamp = timestamp
        return result
    }

    private static func alpha(cutoff: Double, rate: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        let period = 1 / rate
        return 1 / (1 + tau / period)
    }

    private static func exponential(_ value: Double, previous: Double, alpha: Double) -> Double {
        alpha * value + (1 - alpha) * previous
    }
}
