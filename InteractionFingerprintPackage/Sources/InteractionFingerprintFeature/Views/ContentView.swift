import SwiftUI

/// Debug harness for the sensing milestone.
///
/// Not the study interface. Its only job is to prove the perception path works end to
/// end and to make its accuracy visible: permission, session start, frame delivery,
/// gaze ray projection, calibration quality and blend-shape reads. The shopping screens
/// participants will use arrive with the instrumentation milestone.
public struct ContentView: View {
    @State private var tracking = FaceTrackingSession()
    @State private var calibrationRun: GazeCalibrationRun?
    @State private var cameraStatus = CameraAuthorization.statusDescription
    @State private var viewport: CGSize = .zero
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            content
                .onAppear {
                    viewport = proxy.size
                    tracking.updateGeometry(pointSize: proxy.size, displayScale: displayScale)
                }
                .onChange(of: proxy.size) { _, size in
                    viewport = size
                    tracking.updateGeometry(pointSize: size, displayScale: displayScale)
                }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onChange(of: tracking.latest) { _, sample in
            guard let sample, let run = calibrationRun else { return }
            run.receive(
                raw: rawPoint(from: sample),
                eyesOpen: sample.eyesOpen,
                timestamp: sample.timestamp
            )
            if case .finished(let fit) = run.phase { completeCalibration(with: fit) }
        }
        .onChange(of: scenePhase) { _, phase in
            // ARKit cannot run in the background, and a live session drains the battery
            // and heats the device.
            if phase != .active {
                calibrationRun = nil
                tracking.stop()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let run = calibrationRun {
            CalibrationView(run: run, viewport: viewport) {
                calibrationRun = nil
                tracking.stop()
            }
        } else {
            trackingScreen
        }
    }

    // MARK: Tracking screen

    private var trackingScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if tracking.state == .running, let gaze = tracking.displayGaze {
                GazeDot(normalised: gaze, viewport: viewport)
            }

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                readouts
                controls
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(spacing: 5) {
            Text("Interaction Fingerprint")
                .font(.title3.weight(.semibold))
            Text(FaceTrackingSupport.statusDescription)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(FaceTrackingSupport.isSupported ? Color.green : .secondary)
            Text(cameraStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
            calibrationBadge
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 44)
    }

    private var calibrationBadge: some View {
        Group {
            if let calibration = tracking.calibration {
                Text(String(
                    format: "Calibrated · %@ · mean error %.0f pt",
                    calibration.qualityDescription,
                    calibration.meanResidualPoints
                ))
                .foregroundStyle(calibration.meanResidualPoints < 80 ? Color.green : Color.orange)
            } else {
                Text("Not calibrated · gaze is a rough estimate")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2)
        .padding(.top, 2)
    }

    @ViewBuilder
    private var readouts: some View {
        if case .failed(let message) = tracking.state {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)
        }

        if tracking.state == .running {
            VStack(alignment: .leading, spacing: 9) {
                statRow
                gazeRow
                blendShapeList
            }
            .font(.system(.caption2, design: .monospaced))
            .padding(13)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .padding(.bottom, 12)
        }
    }

    private var statRow: some View {
        HStack {
            let tracked = tracking.latest?.isTracked == true
            let open = tracking.latest?.eyesOpen == true
            Label(
                tracked ? (open ? "tracked" : "blink") : "no face",
                systemImage: tracked ? (open ? "eye" : "eye.slash") : "person.slash"
            )
            .foregroundStyle(tracked ? (open ? Color.green : Color.yellow) : Color.orange)
            Spacer()
            Text(String(format: "%.0f Hz", tracking.measuredHz))
            Spacer()
            Text(String(format: "%.0f%% tracked", tracking.trackedShare * 100))
        }
    }

    private var gazeRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let sample = tracking.latest, let x = sample.gazeX, let y = sample.gazeY {
                Text(String(format: "screen   x %.3f   y %.3f", x, y))
            } else {
                Text("screen   —")
            }
            if let sample = tracking.latest, let x = sample.rawGazeX, let y = sample.rawGazeY {
                Text(String(format: "raw (mm) x %+.1f   y %+.1f", x * 1000, y * 1000))
                    .foregroundStyle(.secondary)
            } else {
                Text("raw (mm) —").foregroundStyle(.secondary)
            }
        }
    }

    private var blendShapeList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(TrackedBlendShapes.keys, id: \.self) { key in
                let value = tracking.latest?.signals[key] ?? 0
                HStack(spacing: 8) {
                    Text(key)
                        .frame(width: 108, alignment: .leading)
                        .foregroundStyle(.secondary)
                    ProgressView(value: min(max(value, 0), 1))
                        .tint(.green)
                    Text(String(format: "%.2f", value))
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button {
                Task { await startCalibration() }
            } label: {
                Text(tracking.calibration == nil ? "Calibrate" : "Recalibrate")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!FaceTrackingSupport.isSupported)

            Button {
                Task { await toggleSession() }
            } label: {
                Text(tracking.state == .running ? "Stop session" : "Start session")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!FaceTrackingSupport.isSupported)
        }
        .padding(.bottom, 28)
    }

    // MARK: Actions

    private func rawPoint(from sample: FaceSample) -> CGPoint? {
        guard let x = sample.rawGazeX, let y = sample.rawGazeY else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func toggleSession() async {
        if tracking.state == .running {
            tracking.stop()
            return
        }
        guard await grantCamera() else { return }
        tracking.start()
    }

    private func startCalibration() async {
        guard await grantCamera() else { return }
        if tracking.state != .running { tracking.start() }
        let run = GazeCalibrationRun(screenPointSize: viewport)
        run.begin()
        calibrationRun = run
    }

    private func completeCalibration(with fit: GazeCalibration?) {
        calibrationRun = nil
        guard let fit else { return }
        tracking.calibration = fit
        GazeCalibrationStore.save(fit)
    }

    private func grantCamera() async -> Bool {
        let granted = await CameraAuthorization.request()
        cameraStatus = CameraAuthorization.statusDescription
        return granted
    }
}

/// The debug gaze dot. Display only; recorded samples keep the unfiltered position.
private struct GazeDot: View {
    let normalised: CGPoint
    let viewport: CGSize

    var body: some View {
        if viewport.width > 0 {
            Circle()
                .fill(.green.opacity(0.85))
                .frame(width: 24, height: 24)
                .shadow(color: .green.opacity(0.6), radius: 12)
                .position(
                    x: normalised.x * viewport.width,
                    y: normalised.y * viewport.height
                )
                .allowsHitTesting(false)
        }
    }
}
