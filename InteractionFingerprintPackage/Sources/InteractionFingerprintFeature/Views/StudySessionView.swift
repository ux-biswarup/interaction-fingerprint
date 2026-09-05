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
    let onFinish: (SessionExporter.Export?) -> Void

    @State private var recorder = EventRecorder()
    @State private var registry = AreaOfInterestRegistry()
    @State private var viewport: CGSize = .zero
    @State private var lastAmbientAt: TimeInterval = 0
    @State private var exportError: String?
    @Environment(\.displayScale) private var displayScale

    /// Ambient light changes slowly, so sampling it every frame would add tens of thousands
    /// of rows that say the same thing.
    private let ambientInterval: TimeInterval = 2

    public init(tracking: FaceTrackingSession, onFinish: @escaping (SessionExporter.Export?) -> Void) {
        self.tracking = tracking
        self.onFinish = onFinish
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                ShopView(recorder: recorder)
                    .coordinateSpace(.named(InstrumentationSpace.root))
                    .onPreferenceChange(AreaOfInterestKey.self) { areas in
                        registry.update(areas)
                    }

                TouchObserver { touch in
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
                        pressDurationMs: touch.pressDurationMs
                    )
                }
                .frame(width: 0, height: 0)

                banner
            }
            .onAppear {
                viewport = proxy.size
                startSession(viewport: proxy.size)
            }
            .onChange(of: proxy.size) { _, size in viewport = size }
        }
        .ignoresSafeArea(.keyboard)
        .onChange(of: tracking.latest) { _, sample in record(sample) }
    }

    // MARK: Recording banner

    private var banner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tracking.quality.isConfident ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(tracking.quality.isConfident ? "Recording" : tracking.quality.guidance)
                .font(.caption2.weight(.medium))
            Text("\(recorder.eventCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("Finish") { finish() }
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule())
        .padding(.top, 4)
        .allowsHitTesting(true)
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
            eyeLaterality: EyeLateralityStore.load()
        )
        recorder.start(session: record)
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

    private func finish() {
        guard let result = recorder.stop() else {
            onFinish(nil)
            return
        }
        do {
            let export = try SessionExporter.write(session: result.session, events: result.events)
            onFinish(export)
        } catch {
            exportError = error.localizedDescription
            onFinish(nil)
        }
    }
}
