import SwiftUI

/// Debug harness for the sensing milestone.
///
/// Not the study interface. Its job is to prove the perception path works end to end and
/// to keep its accuracy visible at all times, so a bad recording is obvious while it is
/// happening rather than during analysis weeks later.
public struct ContentView: View {
    @State private var tracking = FaceTrackingSession()
    @State private var calibration: GazeCalibrationRun?
    @State private var lateralityCheck: EyeLateralityCheck?
    @State private var laterality = EyeLateralityStore.load()
    @State private var isRunningStudy = false
    @State private var lastExport: SessionExporter.Export?
    @State private var cameraStatus = CameraAuthorization.statusDescription
    @State private var viewport: CGSize = .zero
    @State private var previewSummary: String?
    /// Show the camera's view of the face instead of the plain screen. Debug only.
    @State private var showsCamera = false
    @State private var desk = DeskLink()
    @State private var showsStudyPlan = false
    @State private var studyCondition: SessionCondition?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            content
                .onAppear {
                    syncGeometry(proxy.size)
                    // Not in the preview modes the UI tests drive: a local-network prompt
                    // there would have nothing to answer it.
                    if !isStimulusPreview { desk.start() }
                }
                .onChange(of: proxy.size) { _, size in syncGeometry(size) }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onChange(of: tracking.latest) { _, sample in
            feedCalibration(sample)
            feedLateralityCheck(sample)
        }
        .onChange(of: scenePhase) { _, phase in
            // ARKit cannot run in the background, and a live session drains the battery
            // and heats the device.
            if phase != .active {
                calibration = nil
                lateralityCheck = nil
                if !isRunningStudy { tracking.stop() }
            } else if !isStimulusPreview {
                desk.resume()
            }
        }
    }

    /// Opens straight into the stimulus, without a device or a calibration.
    ///
    /// The study screens cannot otherwise be seen anywhere but on a Face ID iPhone mid
    /// session, which makes reviewing their appearance far harder than it should be. Pass
    /// `-stimulusPreview` as a launch argument.
    private var isStimulusPreview: Bool {
        ProcessInfo.processInfo.arguments.contains("-stimulusPreview")
    }

    @ViewBuilder
    private var content: some View {
        if isStimulusPreview, ProcessInfo.processInfo.arguments.contains("-recording") {
            // The recording chrome over the stimulus, without a device. Finishing shows what
            // was exported, so the whole recording path can be exercised by a UI test.
            if let previewSummary {
                Text(previewSummary)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Instrument.paper)
                    .padding(40)
                    .accessibilityIdentifier("export_summary")
            } else {
                StudySessionView(tracking: tracking) { export in
                    previewSummary = export.map(Self.summarise) ?? "no export"
                }
            }
        } else if isStimulusPreview {
            ShopView(
                recorder: EventRecorder(),
                startOn: ProcessInfo.processInfo.arguments.contains("-detail")
                    ? Product.catalogue.first
                    : nil
            )
        } else if isRunningStudy {
            StudySessionView(tracking: tracking, desk: desk, condition: studyCondition) { export in
                isRunningStudy = false
                if let export {
                    lastExport = export
                    if let studyCondition {
                        StudyLog.record(studyCondition)
                        // Back to the block so the next session is one tap away.
                        showsStudyPlan = true
                    }
                }
                studyCondition = nil
            }
        } else if let check = lateralityCheck {
            EyeLateralityView(
                check: check,
                onAccept: { result in
                    laterality = result
                    EyeLateralityStore.save(result)
                    lateralityCheck = nil
                },
                onRetry: { check.restart() },
                onCancel: {
                    lateralityCheck = nil
                    tracking.stop()
                }
            )
        } else if let run = calibration, let geometry = tracking.screenGeometry {
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
                    if case .finished(let result) = run.phase {
                        // Kept for offline analysis of where the fit is weak. Failure to
                        // write it must not block accepting a working calibration.
                        let now = Date()
                        _ = try? SessionExporter.writeCalibration(
                            model: model, points: result.points, failedTargets: result.failedTargets, at: now
                        )
                        desk.calibrationSaved(SessionExporter.CalibrationDocument(
                            createdAt: now, model: model, failedTargets: result.failedTargets, points: result.points
                        ))
                    }
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

            if showsCamera, tracking.state == .running {
                // How the system sees the participant: mesh, head axis, eye lines. The dot
                // is drawn over it exactly as on the plain screen, so the two can be compared.
                FaceMirrorView(session: tracking.arSession)
                    .ignoresSafeArea()
                    .opacity(0.85)
            }

            if tracking.state == .running, let gaze = tracking.displayGaze {
                // A moving phone is a fact about the data, not a reason to change the dot.
                GazeDot(
                    normalised: gaze,
                    viewport: viewport,
                    isConfident: tracking.quality.isConfident || tracking.quality == .deviceMoving
                )
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
            if let laterality {
                Text(laterality.summary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Instrument.paperDim)
            } else {
                Text("Eye labels unverified")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Instrument.warn)
            }

            if tracking.state == .running {
                HStack(spacing: 6) {
                    Circle()
                        .fill(tracking.quality.isConfident ? Instrument.reticle : Instrument.warn)
                        .frame(width: 6, height: 6)
                    Text(tracking.quality.guidance)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tracking.quality.isConfident ? Instrument.paper : Instrument.warn)
                }

                Picker("View", selection: $showsCamera) {
                    Text("Screen").tag(false)
                    Text("Camera").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .padding(.top, 4)
                .accessibilityLabel("Tracking view")
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
                Spacer()
                // Millimetres the screen moved under the eyes in the last reaction window,
                // which is the quantity the motion gate actually judges.
                Instrument.reading(String(format: "%.0f mm moved", tracking.motionDisturbance * 1000), size: 11)
                    .foregroundStyle(tracking.deviceIsSteady ? Instrument.paperDim : Instrument.warn)
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
            // Eye position relative to the camera. Move the phone sideways with the head
            // still: x should change and y should not. If they are swapped, the camera
            // frame is rotated relative to what the geometry assumes.
            if let sample = tracking.latest, let x = sample.eyeX, let y = sample.eyeY {
                Instrument.reading(String(format: "eye     x %+.1f cm  y %+.1f cm", x * 100, y * 100), size: 11)
                    .foregroundStyle(Instrument.paperDim)
            } else {
                Instrument.reading("eye     —", size: 11).foregroundStyle(Instrument.paperDim)
            }
            if let device = tracking.latest?.device {
                Instrument.reading(
                    String(format: "phone   tilt %+.0f°  roll %+.0f°", device.tilt * 180 / .pi, device.roll * 180 / .pi),
                    size: 11
                )
                .foregroundStyle(Instrument.paperDim)
            }
        }
    }

    private var blendShapeList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(TrackedBlendShapes.expressionKeys, id: \.self) { key in
                let value = tracking.latest?.signals[key] ?? 0
                HStack(spacing: 8) {
                    Text(label(for: key))
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 132, alignment: .leading)
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

    /// Names the participant's own eye once the wink test has resolved it, because the
    /// raw channel name is ambiguous and getting it backwards would invert findings.
    private func label(for key: String) -> String {
        guard let side = laterality?.participantSide(forARKitKey: key) else { return key }
        return "\(key) (\(side))"
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button {
                Task { await startLateralityCheck() }
            } label: {
                Text(laterality == nil ? "Check eye labels" : "Re-check eye labels")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(laterality == nil ? Instrument.warn : Instrument.paper)
            .controlSize(.large)
            .disabled(!FaceTrackingSupport.isSupported)

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
                Text(tracking.state == .running ? "Stop tracker" : "Start tracker")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Instrument.paper)
            .controlSize(.large)
            .disabled(!FaceTrackingSupport.isSupported)

            Button {
                showsStudyPlan = true
            } label: {
                Text("Study block")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Instrument.reticle)
            .foregroundStyle(Instrument.ink)
            .controlSize(.large)
            .disabled(!FaceTrackingSupport.isSupported || tracking.model == nil)
            .accessibilityIdentifier("study_block")
            .sheet(isPresented: $showsStudyPlan) {
                StudyPlanView(
                    onStart: { condition in
                        showsStudyPlan = false
                        Task { await startStudy(condition: condition) }
                    },
                    onClose: { showsStudyPlan = false }
                )
            }

            Button {
                Task { await startStudy() }
            } label: {
                Text("Record a free session")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Instrument.paper)
            .controlSize(.large)
            .disabled(!FaceTrackingSupport.isSupported || tracking.model == nil)

            if let lastExport {
                VStack(spacing: 6) {
                    Text("Saved \(lastExport.eventCount) events")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Instrument.reticle)
                    // A share sheet rather than relying on the Files app. It works on any
                    // device, and the researcher can send a recording straight to wherever
                    // the analysis lives instead of hunting for it in a folder.
                    ShareLink(items: [lastExport.documentURL, lastExport.eventsURL]
                        + (SessionExporter.latestCalibration().map { [$0] } ?? [])) {
                        Text("Export session")
                            .font(.caption.weight(.medium))
                    }
                    .tint(Instrument.reticle)
                }
            } else if tracking.model == nil {
                Text("Calibrate before recording a session")
                    .font(.system(size: 10))
                    .foregroundStyle(Instrument.warn)
            }

            Text(cameraStatus)
                .font(.system(size: 10))
                .foregroundStyle(Instrument.paperDim)

            // The live link to the Mac. A readout and a switch, nothing else: it finds the
            // desk by itself and copies over whatever the desk lacks.
            HStack(spacing: 8) {
                Toggle(isOn: $desk.isEnabled) { EmptyView() }
                    .labelsHidden()
                    .tint(Instrument.reticle)
                    .scaleEffect(0.7)
                    .accessibilityLabel("Stream to the desk")
                    .accessibilityIdentifier("desk_link_toggle")
                Text(desk.isEnabled ? "Desk · \(desk.state.label)" + (desk.sentEvents > 0 ? " · \(desk.sentEvents) events" : "") : "Desk · off")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Instrument.paperDim)
                    .accessibilityIdentifier("desk_link_status")
            }
            .padding(.top, 2)
        }
        .padding(.bottom, 30)
    }

    // MARK: Actions

    /// Event counts by kind, read back from the file that was actually written.
    private static func summarise(_ export: SessionExporter.Export) -> String {
        guard
            let data = try? Data(contentsOf: export.documentURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let events = object["events"] as? [[String: Any]]
        else { return "unreadable export" }
        var counts: [String: Int] = [:]
        for event in events {
            if let kind = event["event"] as? String { counts[kind, default: 0] += 1 }
        }
        return counts.keys.sorted().map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: " · ")
    }

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

    private func feedLateralityCheck(_ sample: FaceSample?) {
        guard let sample, let check = lateralityCheck else { return }
        check.receive(
            signals: sample.signals,
            isTracked: sample.isTracked,
            timestamp: sample.timestamp
        )
    }

    private func startLateralityCheck() async {
        guard await grantCamera() else { return }
        if tracking.state != .running { tracking.start() }
        lateralityCheck = EyeLateralityCheck()
    }

    private func startStudy(condition: SessionCondition? = nil) async {
        guard await grantCamera() else { return }
        if tracking.state != .running { tracking.start() }
        lastExport = nil
        studyCondition = condition
        isRunningStudy = true
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
