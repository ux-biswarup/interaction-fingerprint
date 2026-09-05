import SwiftUI

/// The calibration sequence: check the setup, walk the fitting targets, change viewing
/// distance, walk the held-out check targets, then report what was actually achieved.
struct CalibrationView: View {
    let run: GazeCalibrationRun
    let geometry: ScreenGeometry
    let viewport: CGSize
    let onCancel: () -> Void
    let onAccept: (GazeModel) -> Void
    let onRetry: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Instrument.ink.ignoresSafeArea()

            switch run.phase {
            case .readiness:
                setupStep
            case .fitting, .checking:
                targetStep
            case .changeDistance:
                changeDistanceStep
            case .finished(let result):
                ResultsStep(
                    result: result,
                    geometry: geometry,
                    onAccept: onAccept,
                    onRetry: onRetry,
                    onCancel: onCancel
                )
            }
        }
    }

    // MARK: Setup

    private var setupStep: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Instrument.label("Before you start")
                Text("Hold the phone steady\nat a comfortable reading distance")
                    .font(.system(size: 22, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Instrument.paper)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Face the screen straight on. Nine circles will appear one at a time. Look at each one and hold still.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Instrument.paperDim)
                    .padding(.horizontal, 36)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            statusPanel
            Button("Cancel", action: onCancel)
                .font(.footnote)
                .foregroundStyle(Instrument.paperDim)
                .padding(.bottom, 28)
        }
    }

    private var statusPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(run.quality.isUsable ? Instrument.reticle : Instrument.warn)
                    .frame(width: 7, height: 7)
                Text(run.quality.isUsable ? "Ready" : run.quality.guidance)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(run.quality.isUsable ? Instrument.paper : Instrument.warn)
            }
            if let distance = run.liveDistance {
                Instrument.reading(String(format: "%.0f cm", distance * 100), size: 12)
                    .foregroundStyle(Instrument.paperDim)
            }
        }
        .padding(.bottom, 26)
    }

    // MARK: Targets

    private var targetStep: some View {
        ZStack {
            if let target = run.currentTarget {
                TargetMarker(isLocked: run.isCollecting, reduceMotion: reduceMotion)
                    .position(
                        x: Double(target.x) * viewport.width,
                        y: Double(target.y) * viewport.height
                    )
            }

            VStack {
                Spacer()
                VStack(spacing: 5) {
                    Text(run.isCollecting ? "Hold still" : "Look at the circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Instrument.paperDim)
                    if let step = run.stepLabel {
                        Instrument.reading(step, size: 11)
                            .foregroundStyle(Instrument.paperDim.opacity(0.7))
                    }
                    Button("Cancel", action: onCancel)
                        .font(.caption2)
                        .foregroundStyle(Instrument.paperDim.opacity(0.7))
                        .padding(.top, 6)
                }
                .padding(.bottom, 30)
            }
        }
    }

    // MARK: Change distance

    private var changeDistanceStep: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Instrument.label("Check pass")
                Text("Now move the phone\ncloser or further away")
                    .font(.system(size: 22, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Instrument.paper)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Four more circles will follow. These are not used to build the calibration. They measure whether it still holds once the phone has moved.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Instrument.paperDim)
                    .padding(.horizontal, 36)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()

            VStack(spacing: 8) {
                let change = run.distanceChange ?? 0
                let needed = GazeCalibrationRun.requiredDistanceChange
                ProgressView(value: min(change / needed, 1))
                    .tint(change >= needed ? Instrument.reticle : Instrument.paperDim)
                    .frame(width: 160)
                Text(
                    change >= needed
                        ? "Hold there"
                        : String(format: "Moved %.0f cm of %.0f cm", change * 100, needed * 100)
                )
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(change >= needed ? Instrument.reticle : Instrument.paperDim)
            }
            .padding(.bottom, 26)

            Button("Cancel", action: onCancel)
                .font(.footnote)
                .foregroundStyle(Instrument.paperDim)
                .padding(.bottom, 28)
        }
    }
}

/// The classic concentric fixation target. A ring with a small central dot produces a
/// tighter, more repeatable fixation than a plain disc, which is why eye-tracking research
/// has converged on this shape.
private struct TargetMarker: View {
    let isLocked: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Instrument.paper.opacity(0.30), lineWidth: 1)
                .frame(width: 46, height: 46)
            Circle()
                .fill(Instrument.paper)
                .frame(width: isLocked ? 20 : 26, height: isLocked ? 20 : 26)
            Circle()
                .fill(isLocked ? Instrument.reticle : Instrument.ink)
                .frame(width: 6, height: 6)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isLocked)
        .accessibilityLabel(isLocked ? "Recording, hold still" : "Look at this circle")
    }
}

/// The measurement, not a verdict.
private struct ResultsStep: View {
    let result: GazeCalibrationRun.GazeCalibrationResult
    let geometry: ScreenGeometry
    let onAccept: (GazeModel) -> Void
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let model = result.model {
                succeeded(model)
            } else {
                failed
            }
        }
        .padding(24)
    }

    private func succeeded(_ model: GazeModel) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Instrument.label("Mean error, held out")
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.0f", model.heldOutErrorPoints))
                        .font(.system(size: 64, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Instrument.paper)
                    Text("pt")
                        .font(.system(size: 18, weight: .medium, design: .monospaced))
                        .foregroundStyle(Instrument.paperDim)
                }
                Text(verdict(model))
                    .font(.system(size: 13))
                    .foregroundStyle(tint(model))
            }
            .padding(.top, 20)

            ResidualMapView(
                model: model,
                fitPoints: result.fitPoints,
                checkPoints: result.checkPoints,
                geometry: geometry
            )
            .frame(maxHeight: 260)
            .padding(.vertical, 18)

            VStack(spacing: 7) {
                row("Worst target", String(format: "%.0f pt", model.worstHeldOutErrorPoints))
                if let check = model.distanceCheckErrorPoints {
                    row(
                        "After moving the phone",
                        String(format: "%.0f pt", check),
                        tint: check <= model.heldOutErrorPoints * 2 ? Instrument.paper : Instrument.warn
                    )
                }
                row("Distance", String(
                    format: "%.0f–%.0f cm",
                    model.calibratedDistanceRange.lowerBound * 100,
                    model.calibratedDistanceRange.upperBound * 100
                ))
                row("Model", model.summary)
                if result.failedTargets > 0 {
                    row("Skipped targets", "\(result.failedTargets)", tint: Instrument.warn)
                }
            }

            Spacer(minLength: 14)

            VStack(spacing: 9) {
                Button { onAccept(model) } label: {
                    Text("Use this calibration").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Instrument.reticle)
                .foregroundStyle(Instrument.ink)
                .controlSize(.large)

                Button("Run it again", action: onRetry)
                    .font(.footnote)
                    .foregroundStyle(Instrument.paperDim)
            }
        }
    }

    private var failed: some View {
        VStack(spacing: 16) {
            Spacer()
            Instrument.label("Calibration failed")
            Text("Not enough targets were measured")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Instrument.paper)
                .multilineTextAlignment(.center)
            Text("This usually means the face was lost or the phone moved between targets. Sit square to the screen, keep the phone steady, and try again.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Instrument.paperDim)
                .padding(.horizontal, 20)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { onRetry() } label: {
                Text("Try again").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Instrument.reticle)
            .foregroundStyle(Instrument.ink)
            .controlSize(.large)
            Button("Cancel", action: onCancel)
                .font(.footnote)
                .foregroundStyle(Instrument.paperDim)
        }
    }

    private func row(_ label: String, _ value: String, tint: Color = Instrument.paper) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Instrument.paperDim)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(tint)
        }
    }

    private func verdict(_ model: GazeModel) -> String {
        switch model.accuracyDescription {
        case "good": "Small enough to tell screen regions apart"
        case "usable": "Workable for large regions only"
        default: "Too coarse to trust. Run it again."
        }
    }

    private func tint(_ model: GazeModel) -> Color {
        switch model.accuracyDescription {
        case "good": Instrument.reticle
        case "usable": Instrument.paperDim
        default: Instrument.warn
        }
    }
}
