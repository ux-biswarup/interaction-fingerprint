import SwiftUI

/// The calibration result, drawn as a measurement rather than a verdict.
///
/// Each target is shown where it appeared on screen, with a line to where the fitted
/// model actually predicts the gaze landed. The shape of the errors is the useful part:
/// error concentrated along one edge means something quite different from error scattered
/// evenly, and a single number cannot tell them apart.
struct ResidualMapView: View {
    let model: GazeModel
    let fitPoints: [GazeCalibrationPoint]
    let checkPoints: [GazeCalibrationPoint]
    let geometry: ScreenGeometry

    var body: some View {
        GeometryReader { proxy in
            let frame = phoneRect(in: proxy.size)
            ZStack {
                RoundedRectangle(cornerRadius: frame.width * 0.12)
                    .stroke(Instrument.paper.opacity(0.18), lineWidth: 1)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                ForEach(Array(fitPoints.enumerated()), id: \.offset) { index, point in
                    residual(for: point, index: index + 1, in: frame, centre: proxy.size, isCheck: false)
                }
                ForEach(Array(checkPoints.enumerated()), id: \.offset) { index, point in
                    residual(for: point, index: index + 1, in: frame, centre: proxy.size, isCheck: true)
                }
            }
        }
    }

    @ViewBuilder
    private func residual(
        for point: GazeCalibrationPoint,
        index: Int,
        in frame: CGSize,
        centre: CGSize,
        isCheck: Bool
    ) -> some View {
        if let measurement = point.measurement(for: model.source) {
            let predicted = geometry.normalised(fromCameraMetres: model.screenPlaneHit(for: measurement))
            let origin = CGPoint(
                x: (centre.width - frame.width) / 2,
                y: (centre.height - frame.height) / 2
            )
            let targetPoint = CGPoint(
                x: origin.x + Double(point.target.x) * frame.width,
                y: origin.y + Double(point.target.y) * frame.height
            )
            let predictedPoint = CGPoint(
                x: origin.x + min(max(Double(predicted.x), -0.2), 1.2) * frame.width,
                y: origin.y + min(max(Double(predicted.y), -0.2), 1.2) * frame.height
            )
            let tint = isCheck ? Instrument.reticle : Instrument.residual

            Path { path in
                path.move(to: targetPoint)
                path.addLine(to: predictedPoint)
            }
            .stroke(tint.opacity(0.85), lineWidth: 1.5)

            Circle()
                .stroke(Instrument.paper.opacity(0.7), lineWidth: 1)
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
    private func phoneRect(in size: CGSize) -> CGSize {
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
