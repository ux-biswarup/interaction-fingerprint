import SwiftUI

/// The calibration result, drawn as a measurement rather than a verdict.
///
/// Each target is shown where it appeared, with a line to where the fitted model actually
/// predicts the gaze landed. The shape of the errors is the useful part: error
/// concentrated along one edge means something quite different from error scattered
/// evenly, and a single number cannot tell them apart.
///
/// Near and far passes are coloured differently. If one colour is consistently longer, the
/// mapping still depends on viewing distance and the calibration should be run again.
struct ResidualMapView: View {
    let model: GazeModel
    let points: [GazeCalibrationPoint]
    let geometry: ScreenGeometry

    private var splitDistance: Double {
        let distances = points.compactMap { $0.measurement(for: model.source)?.distance }.sorted()
        guard !distances.isEmpty else { return 0 }
        return distances[distances.count / 2]
    }

    var body: some View {
        GeometryReader { proxy in
            let frame = phoneSize(in: proxy.size)
            let origin = CGPoint(
                x: (proxy.size.width - frame.width) / 2,
                y: (proxy.size.height - frame.height) / 2
            )
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: frame.width * 0.12)
                    .stroke(Instrument.paper.opacity(0.18), lineWidth: 1)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: origin.x, y: origin.y)

                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    residual(for: point, frame: frame, origin: origin)
                }
            }
        }
    }

    @ViewBuilder
    private func residual(for point: GazeCalibrationPoint, frame: CGSize, origin: CGPoint) -> some View {
        if let measurement = point.measurement(for: model.source) {
            let predicted = geometry.normalised(fromCameraMetres: model.screenPlaneHit(for: measurement))
            let targetPoint = CGPoint(
                x: origin.x + Double(point.target.x) * frame.width,
                y: origin.y + Double(point.target.y) * frame.height
            )
            let predictedPoint = CGPoint(
                x: origin.x + min(max(Double(predicted.x), -0.25), 1.25) * frame.width,
                y: origin.y + min(max(Double(predicted.y), -0.25), 1.25) * frame.height
            )
            let isFar = measurement.distance > splitDistance
            let tint = isFar ? Instrument.reticle : Instrument.residual

            Path { path in
                path.move(to: targetPoint)
                path.addLine(to: predictedPoint)
            }
            .stroke(tint.opacity(0.85), lineWidth: 1.5)

            Circle()
                .stroke(Instrument.paper.opacity(0.65), lineWidth: 1)
                .frame(width: 9, height: 9)
                .position(targetPoint)

            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
                .position(predictedPoint)
        }
    }

    /// Keeps the drawing in the display's real proportions, so a residual that looks long
    /// on the diagram is long on the phone.
    private func phoneSize(in size: CGSize) -> CGSize {
        let aspect = Double(geometry.pointSize.height) / Double(geometry.pointSize.width)
        var width = size.width
        var height = width * aspect
        if height > size.height {
            height = size.height
            width = height / aspect
        }
        return CGSize(width: width, height: height)
    }
}
