import SwiftUI

/// Debug harness for the sensing milestone.
///
/// Not the study interface. Its job is to prove the perception path works end to end and
/// to keep its accuracy visible at all times, so a bad recording is obvious while it is
/// happening rather than during analysis weeks later.
public struct ContentView: View {
    @State private var tracking = FaceTrackingSession()
    @State private var calibration: GazeCalibrationRun?
    @State private var cameraStatus = CameraAuthorization.statusDescription
    @State private var viewport: CGSize = .zero
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            content
                .onAppear { syncGeometry(proxy.size) }
                .onChange(of: proxy.size) { _, size in syncGeometry(size) }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onChange(of: tracking.latest) { _, sample in feedCalibration(sample) }
        .onChange(of: scenePhase) { _, phase in
            // ARKit cannot run in the background, and a live session drains the battery
            // and heats the device.
            if phase != .active {
                calibration = nil
                tracking.stop()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let run = calibration, let geometry = tracking.screenGeometry {
            CalibrationView(
                run: run,
                geometry: geometry,
                viewport: viewport,
                onCancel: {
                    calibration = nil
                    tracking.stop()
                },
                onAccept: { model in
                    tracking.model = model
                    GazeModelStore.save(model)
                    calibration = nil
                },
                onRetry: { run.cancel() }
            )
        } else {
            trackingScreen
        }
    }

    // MARK: Tracking screen

    private var trackingScreen: some View {
        ZStack {
            Instrument.ink.ignoresSafeArea()

            if tracking.state == .running, let gaze = tracking.displayGaze {
                GazeDot(normalised: gaze, viewport: viewport, isConfident: tracking.quality.isConfident)
            }

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                if tracking.state == .running { readouts }
                controls
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(spacing: 7) {
            Text("Interaction Fingerprint")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Instrument.paper)

            if !FaceTrackingSupport.isSupported {
                Text(FaceTrackingSupport.statusDescription)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Instrument.warn)
            }

            calibrationBadge

            if tracking.state == .running {
                HStack(spacing: 6) {
                    Circle()
                        .fill(tracking.quality.isConfident ? Instrument.reticle : Instrument.warn)
                        .frame(width: 6, height: 6)
                    Text(tracking.quality.guidance)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tracking.quality.isConfident ? Instrument.paper : Instrument.warn)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 46)
    }

    private var calibrationBadge: some View {
        Group {
            if let model = tracking.model {
                Text(model.summary)
            } else {
                Text("Not calibrated · rough estimate only")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(tracking.model == nil ? Instrument.warn : Instrument.paperDim)
    }

    @ViewBuilder
    private var readouts: some View {
        if case .failed(let message) = tracking.state {
            Text(message)
                .font(.footnote)
                .foregroundStyle(Instrument.warn)
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Instrument.reading(String(format: "%.0f Hz", tracking.measuredHz), size: 11)
                Spacer()
                Instrument.reading(String(format: "%.0f%% tracked", tracking.trackedShare * 100), size: 11)
                Spacer()
                if let z = tracking.latest?.eyeZ {
                    Instrument.reading(String(format: "%.0f cm", -z * 100), size: 11)
                } else {
                    Instrument.reading("— cm", size: 11)
                }
            }
            gazeRow
            blendShapeList
        }
        .padding(13)
        .background(Instrument.paper.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 12)
    }

    private var gazeRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let sample = tracking.latest, let x = sample.gazeX, let y = sample.gazeY {
                Instrument.reading(String(format: "screen  x %.3f  y %.3f", x, y), size: 11)
            } else {
                Instrument.reading("screen  —", size: 11)
            }
            if let sample = tracking.latest, let u = sample.convergenceU, let v = sample.convergenceV {
                Instrument.reading(String(format: "angle   u %+.3f  v %+.3f", u, v), size: 11)
                    .foregroundStyle(Instrument.paperDim)
            } else {
                Instrument.reading("angle   —", size: 11).foregroundStyle(Instrument.paperDim)
            }
        }
    }

    private var blendShapeList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(TrackedBlendShapes.keys, id: \.self) { key in
                let value = tracking.latest?.signals[key] ?? 0
                HStack(spacing: 8) {
                    Text(key)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 100, alignment: .leading)
                        .foregroundStyle(Instrument.paperDim)
                    ProgressView(value: min(max(value, 0), 1))
                        .tint(Instrument.reticle)
                    Text(String(format: "%.2f", value))
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 32, alignment: .trailing)
                        .foregroundStyle(Instrument.paper)
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button {
                Task { await startCalibration() }
            } label: {
                Text(tracking.model == nil ? "Calibrate" : "Recalibrate")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Instrument.paper)
            .controlSize(.large)
            .disabled(!FaceTrackingSupport.isSupported)

            Button {
                Task { await toggleSession() }
            } label: {
                Text(tracking.state == .running ? "Stop session" : "Start session")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Instrument.reticle)
            .foregroundStyle(Instrument.ink)
            .controlSize(.large)
            .disabled(!FaceTrackingSupport.isSupported)

            Text(cameraStatus)
                .font(.system(size: 10))
                .foregroundStyle(Instrument.paperDim)
        }
        .padding(.bottom, 30)
    }

    // MARK: Actions

    private func syncGeometry(_ size: CGSize) {
        viewport = size
        tracking.updateGeometry(pointSize: size, displayScale: displayScale)
    }

    private func feedCalibration(_ sample: FaceSample?) {
        guard let sample, let run = calibration else { return }
        run.receive(
            sample: tracking.latestCalibrationSample,
            quality: tracking.quality,
            timestamp: sample.timestamp
        )
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
        guard let geometry = tracking.screenGeometry else { return }
        calibration = GazeCalibrationRun(geometry: geometry)
    }

    private func grantCamera() async -> Bool {
        let granted = await CameraAuthorization.request()
        cameraStatus = CameraAuthorization.statusDescription
        return granted
    }
}

/// The debug gaze dot. Display only; recorded samples keep the unfiltered angles.
///
/// Dims when the frame is outside the trustworthy envelope rather than disappearing, so
/// the difference between "not tracking" and "tracking badly" stays visible.
private struct GazeDot: View {
    let normalised: CGPoint
    let viewport: CGSize
    let isConfident: Bool

    var body: some View {
        if viewport.width > 0 {
            Circle()
                .fill(Instrument.reticle.opacity(isConfident ? 0.9 : 0.25))
                .frame(width: 22, height: 22)
                .shadow(color: Instrument.reticle.opacity(isConfident ? 0.5 : 0), radius: 10)
                .position(
                    x: Double(normalised.x) * viewport.width,
                    y: Double(normalised.y) * viewport.height
                )
                .allowsHitTesting(false)
        }
    }
}
