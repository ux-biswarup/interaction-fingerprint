import SwiftUI

/// Debug harness for the tracking milestone.
///
/// This is not the study UI. Its only job is to prove the sensor path end to end:
/// permission, session start, frame delivery, gaze projection and blend-shape reads.
/// The product screens that participants will use come with the instrumentation
/// milestone.
public struct ContentView: View {
    @State private var tracking = FaceTrackingSession()
    @State private var cameraStatus = CameraAuthorization.statusDescription
    @State private var viewport: CGSize = .zero
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if tracking.state == .running {
                GazeDot(normalised: tracking.smoothedGaze, viewport: viewport)
            }

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                readouts
                controls
            }
            .padding(20)
        }
        .preferredColorScheme(.dark)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            viewport = size
            tracking.updateViewport(size)
        }
        .onChange(of: scenePhase) { _, phase in
            // ARKit cannot run in the background, and a session left running drains
            // the battery and heats the device.
            if phase != .active { tracking.stop() }
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 6) {
            Text("Interaction Fingerprint")
                .font(.title3.weight(.semibold))
            Text(FaceTrackingSupport.statusDescription)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(FaceTrackingSupport.isSupported ? Color.green : .secondary)
            Text(cameraStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
            VStack(alignment: .leading, spacing: 10) {
                statRow
                gazeRow
                blendShapeList
            }
            .font(.system(.caption, design: .monospaced))
            .padding(14)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .padding(.bottom, 14)
        }
    }

    private var statRow: some View {
        HStack {
            Label(
                tracking.latest?.isTracked == true ? "tracked" : "no face",
                systemImage: tracking.latest?.isTracked == true ? "face.smiling" : "eye.slash"
            )
            .foregroundStyle(tracking.latest?.isTracked == true ? Color.green : Color.orange)
            Spacer()
            Text(String(format: "%.0f Hz", tracking.measuredHz))
            Spacer()
            Text(String(format: "%.0f%% tracked", tracking.trackedShare * 100))
        }
    }

    private var gazeRow: some View {
        HStack {
            if let sample = tracking.latest, let x = sample.gazeX, let y = sample.gazeY {
                Text(String(format: "gaze  x %.3f   y %.3f", x, y))
            } else {
                Text("gaze  —")
            }
            Spacer()
            Text("\(tracking.frameCount) frames")
                .foregroundStyle(.secondary)
        }
    }

    private var blendShapeList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(TrackedBlendShapes.keys, id: \.self) { key in
                let value = tracking.latest?.signals[key] ?? 0
                HStack(spacing: 8) {
                    Text(key)
                        .frame(width: 130, alignment: .leading)
                        .foregroundStyle(.secondary)
                    ProgressView(value: min(max(value, 0), 1))
                        .tint(.green)
                    Text(String(format: "%.2f", value))
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Toggle("Mirror horizontally", isOn: $tracking.mirrorHorizontally)
                .font(.caption)
                .disabled(tracking.state != .running)

            Button(tracking.state == .running ? "Stop session" : "Start session") {
                Task { await toggleSession() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!FaceTrackingSupport.isSupported)
        }
    }

    // MARK: Actions

    private func toggleSession() async {
        if tracking.state == .running {
            tracking.stop()
            return
        }
        let granted = await CameraAuthorization.request()
        cameraStatus = CameraAuthorization.statusDescription
        guard granted else { return }
        tracking.start()
    }
}

/// The debug gaze dot. Display only; the recorded sample keeps the raw position.
private struct GazeDot: View {
    let normalised: CGPoint?
    let viewport: CGSize

    var body: some View {
        if let normalised, viewport.width > 0 {
            Circle()
                .fill(.green.opacity(0.85))
                .frame(width: 26, height: 26)
                .shadow(color: .green.opacity(0.6), radius: 12)
                .position(
                    x: normalised.x * viewport.width,
                    y: normalised.y * viewport.height
                )
                .allowsHitTesting(false)
        }
    }
}
