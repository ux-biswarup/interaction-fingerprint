import SwiftUI

/// Hosts the study stimulus and records everything that happens in it.
///
/// This is where the two streams meet. Gaze samples arrive from ARKit, interaction events
/// arrive from the interface, and both are stamped from the same monotonic clock so they
/// are directly comparable. Gaze is attributed to a semantic region here, on device, while
/// the raw coordinate is kept as well: if the region definitions turn out to be wrong, the
/// recording can be re-attributed offline, which would be impossible if only the label had
/// been stored.
public struct StudySessionView: View {
    let tracking: FaceTrackingSession
    /// The live link to the researcher's Mac, when the app has one.
    let desk: DeskLink?
    /// The study condition, or nil for a free recording. With a condition the session shows
    /// the task prompt first, starts on Begin, ends by itself at the limit or on the
    /// selection, and writes a `task_result` event.
    let condition: SessionCondition?
    let onFinish: (SessionExporter.Export?) -> Void

    @State private var recorder = EventRecorder()
    @State private var registry = AreaOfInterestRegistry()
    @State private var viewport: CGSize = .zero
    @State private var lastAmbientAt: TimeInterval = 0
    @State private var exportError: String?
    @State private var hasBegun = false
    @State private var remaining: TimeInterval?
    @State private var selectedProduct: String?
    @State private var isFinishing = false
    @Environment(\.displayScale) private var displayScale

    /// Ambient light changes slowly, so sampling it every frame would add tens of thousands
    /// of rows that say the same thing.
    private let ambientInterval: TimeInterval = 2

    public init(
        tracking: FaceTrackingSession,
        desk: DeskLink? = nil,
        condition: SessionCondition? = nil,
        onFinish: @escaping (SessionExporter.Export?) -> Void
    ) {
        self.tracking = tracking
        self.desk = desk
        self.condition = condition
        self.onFinish = onFinish
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                ShopView(recorder: recorder)
                    .coordinateSpace(.named(InstrumentationSpace.root))
                    .onPreferenceChange(AreaOfInterestKey.self) { areas in
                        registry.update(areas)
                        desk?.areasChanged(areas, viewport: proxy.size)
                    }

                TouchObserver { touch in
                    // A drag is a scroll, already recorded from the scroll view's geometry.
                    guard touch.travelPoints < ObservingRecogniser.tapTravelLimit else { return }
                    let area = registry.hitTest(
                        normalised: CGPoint(
                            x: touch.location.x / max(proxy.size.width, 1),
                            y: touch.location.y / max(proxy.size.height, 1)
                        ),
                        viewport: proxy.size
                    )
                    recorder.tapped(
                        screen: area?.screen ?? .productList,
                        target: area?.target ?? .listItem,
                        productID: area?.productID,
                        at: touch.location,
                        viewport: proxy.size,
                        contactArea: touch.contactRadius,
                        pressDurationMs: touch.pressDurationMs,
                        targetFrame: area?.frame
                    )
                }
                .frame(width: 0, height: 0)

                banner

                if let condition, !hasBegun {
                    prompt(condition)
                }
            }
            // The stimulus is pinned to the light appearance, so the app-wide dark scheme
            // used by the instrument screens must not leak into it.
            .preferredColorScheme(.light)
            .onAppear {
                viewport = proxy.size
                if condition == nil {
                    startSession(viewport: proxy.size)
                } else if tracking.state != .running {
                    tracking.start()
                }
            }
            .onChange(of: proxy.size) { _, size in viewport = size }
        }
        .ignoresSafeArea(.keyboard)
        .onChange(of: tracking.latest) { _, sample in record(sample) }
        .task(id: hasBegun) { await runClock() }
    }

    // MARK: Study task

    /// Read from the screen, the same words every time. Recording starts on Begin, so the
    /// reading is not part of the session.
    private func prompt(_ condition: SessionCondition) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text(condition.task == .browse ? "Browse" : "Search")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(condition.prompt)
                    .font(.system(size: 22, weight: .semibold))
                Text(condition.paceNote)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                Button {
                    hasBegun = true
                    startSession(viewport: viewport)
                } label: {
                    Text("Begin")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("begin_task")
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(20)
        }
    }

    /// Counts the limit down once the session has begun and ends it at zero.
    private func runClock() async {
        guard hasBegun, let condition else { return }
        let end = Date().addingTimeInterval(condition.limitSeconds)
        while !Task.isCancelled {
            let left = end.timeIntervalSinceNow
            remaining = max(left, 0)
            if left <= 0 {
                finish(timedOut: true)
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func noteSelection(_ productID: String) {
        guard let condition, condition.endsOnSelection, selectedProduct == nil else { return }
        selectedProduct = productID
        // Long enough for the participant to see the basket state change.
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            finish(timedOut: false)
        }
    }

    // MARK: Recording banner

    /// Sits over the stimulus rather than inside it, so the shop's own layout is exactly
    /// what a participant would see without any recording apparatus attached.
    ///
    /// Placed in the top right of the shop's own header row, below the sensor housing. The
    /// root view ignores safe areas because gaze has to be mapped against the whole display,
    /// so the inset is read back from the window; without it this sat under the Dynamic
    /// Island and the Finish button could not be pressed.
    ///
    /// It shows the researcher a count and a colour, and deliberately no words about
    /// tracking state. A participant reading "hold the phone still" mid-task is a confound.
    private var banner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tracking.quality.isConfident ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .accessibilityLabel(tracking.quality.isConfident ? "Tracking" : tracking.quality.guidance)
            if let condition, condition.showsCountdown, let remaining {
                // The one thing a hurried participant is meant to see.
                Text("\(Int(remaining.rounded(.up))) s")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(remaining < 10 ? Color.red : Shop.ink)
                    .monospacedDigit()
                    .accessibilityIdentifier("countdown")
            } else {
                Text("\(recorder.eventCount)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Shop.inkSecondary)
                    .monospacedDigit()
            }
            Divider().frame(height: 14)
            Button("Finish") { finish() }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Shop.action)
                .accessibilityIdentifier("finish_recording")
                .accessibilityHint("Stops recording and saves the session")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Shop.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .padding(.top, SafeAreaProbe.top + 4)
        .padding(.trailing, 12)
        .environment(\.colorScheme, .light)
    }

    // MARK: Lifecycle

    private func startSession(viewport: CGSize) {
        let record = SessionRecord(
            appID: Bundle.main.bundleIdentifier ?? "InteractionFingerprint",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            device: DeviceRecord(
                model: UIDevice.current.model,
                systemVersion: UIDevice.current.systemVersion,
                screenPointWidth: Double(viewport.width),
                screenPointHeight: Double(viewport.height),
                displayScale: displayScale
            ),
            calibration: tracking.model,
            eyeLaterality: EyeLateralityStore.load(),
            condition: condition
        )
        let desk = self.desk
        recorder.sink = { event in
            desk?.record(event)
            if event.event == EventKind.productSelected.rawValue, let productID = event.productID {
                noteSelection(productID)
            }
        }
        recorder.start(session: record)
        desk?.sessionStarted(record)
        if tracking.state != .running { tracking.start() }
    }

    private func record(_ sample: FaceSample?) {
        guard let sample, recorder.isRecording else { return }

        let area = sample.gazeX.flatMap { x in
            sample.gazeY.flatMap { y in
                registry.hitTest(normalised: CGPoint(x: x, y: y), viewport: viewport)
            }
        }
        recorder.recordGaze(sample, screen: area?.screen, area: area)

        if sample.timestamp - lastAmbientAt >= ambientInterval {
            lastAmbientAt = sample.timestamp
            recorder.recordAmbientLight(
                intensity: tracking.ambientIntensity,
                temperature: tracking.ambientColourTemperature
            )
        }
    }

    private func finish(timedOut: Bool = false) {
        guard !isFinishing else { return }
        isFinishing = true
        if let condition, recorder.isRecording {
            let correct = condition.task == .browse
                || (selectedProduct != nil && selectedProduct == StudyPlan.correctSearchProduct(in: Product.catalogue)?.id)
            recorder.taskResult(correct: correct, selected: selectedProduct, timedOut: timedOut)
        }
        guard let result = recorder.stop() else {
            onFinish(nil)
            return
        }
        do {
            let export = try SessionExporter.write(session: result.session, events: result.events)
            // After the file exists, so a desk that missed the stream can ask for it.
            desk?.sessionEnded(result.session)
            onFinish(export)
        } catch {
            exportError = error.localizedDescription
            onFinish(nil)
        }
    }
}
