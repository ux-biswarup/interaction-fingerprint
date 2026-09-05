import Foundation

/// Small dense linear-algebra helpers for fitting the gaze mapping.
///
/// Written out rather than pulled from a library because the systems are tiny, at most
/// six unknowns, and because the singularity checks need to be explicit: a degenerate
/// calibration must be reported as a failure, never silently returned as a wild fit.
enum LeastSquares {

    /// Least-squares solution of an over-determined system via the normal equations.
    ///
    /// - Parameters:
    ///   - design: one row of basis values per observation.
    ///   - observations: the target value for each row.
    /// - Returns: the coefficient vector, or nil when the system is rank deficient.
    /// - Parameter ridge: Tikhonov regularisation strength, relative to the scale of the
    ///   data. Nine calibration targets against six quadratic terms leaves very little
    ///   slack, and an unregularised fit will happily contort itself through the training
    ///   points while behaving badly between them. Shrinking the coefficients trades a
    ///   little bias for a large reduction in variance. The intercept is left alone, since
    ///   penalising it would bias the whole mapping towards the origin.
    static func solve(design: [[Double]], observations: [Double], ridge: Double = 0) -> [Double]? {
        guard let width = design.first?.count, width > 0 else { return nil }
        guard design.count == observations.count, design.count >= width else { return nil }

        var normal = [[Double]](repeating: [Double](repeating: 0, count: width), count: width)
        var righthand = [Double](repeating: 0, count: width)

        for (row, value) in zip(design, observations) {
            guard row.count == width else { return nil }
            for i in 0..<width {
                righthand[i] += row[i] * value
                for j in 0..<width {
                    normal[i][j] += row[i] * row[j]
                }
            }
        }

        if ridge > 0, width > 1 {
            // Scale the penalty to the data so that one value of `ridge` means the same
            // thing whether angles are being fitted in radians or something larger.
            let trace = (0..<width).reduce(0.0) { $0 + normal[$1][$1] }
            let penalty = ridge * trace / Double(width)
            for i in 1..<width {
                normal[i][i] += penalty
            }
        }

        return gaussianSolve(normal, righthand)
    }

    /// Gaussian elimination with partial pivoting and a relative pivot tolerance.
    static func gaussianSolve(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        let n = vector.count
        guard matrix.count == n else { return nil }

        var a = matrix
        var b = vector

        // Scale reference for the tolerance, so the check is relative to the data.
        let magnitude = a.flatMap { $0 }.map(abs).max() ?? 0
        guard magnitude > 0 else { return nil }
        let tolerance = magnitude * 1e-12

        for column in 0..<n {
            var pivotRow = column
            var pivotValue = abs(a[column][column])
            for row in (column + 1)..<n where abs(a[row][column]) > pivotValue {
                pivotValue = abs(a[row][column])
                pivotRow = row
            }
            guard pivotValue > tolerance else { return nil }

            if pivotRow != column {
                a.swapAt(pivotRow, column)
                b.swapAt(pivotRow, column)
            }

            let pivot = a[column][column]
            for row in (column + 1)..<n {
                let factor = a[row][column] / pivot
                guard factor.isFinite else { return nil }
                if factor == 0 { continue }
                for col in column..<n {
                    a[row][col] -= factor * a[column][col]
                }
                b[row] -= factor * b[column]
            }
        }

        var solution = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for col in (row + 1)..<n {
                sum -= a[row][col] * solution[col]
            }
            solution[row] = sum / a[row][row]
            guard solution[row].isFinite else { return nil }
        }

        return solution
    }
}
