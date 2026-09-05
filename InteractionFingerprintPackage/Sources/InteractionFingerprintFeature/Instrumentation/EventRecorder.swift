import Foundation
import Observation
import SwiftUI

/// Collects every event of a session into one ordered stream.
///
/// Two rules drive the design. Everything is stamped from `SessionClock`, so a tap and a
/// gaze sample are directly comparable in time. And nothing is ever silently dropped: if
/// the buffer fills, an explicit overflow event is written, because a dataset with an
/// unmarked hole in it is worse than one that admits the hole.
@MainActor
@Observable
public final class EventRecorder {

    /// Beyond this the buffer stops growing and records that it did.
    nonisolated public static let bufferLimit = 200_000
    /// Scroll offsets arrive far faster than they carry information.
    nonisolated public static let scrollThrottle: TimeInterval = 1.0 / 20.0
    /// A product counts as viewed once its detail screen has been up this long.
    nonisolated public static let productViewedAfter: TimeInterval = 0.5

    public private(set) var session: SessionRecord?
    public private(set) var events: [FingerprintEvent] = []
    public private(set) var isRecording = false
    public private(set) var droppedEvents = 0

    public var eventCount: Int { events.count }

    private var sequence = 0
    private var overflowed = false
    private var lastScrollAt: TimeInterval?
    private var currentArea: AreaOfInterest?
    private var currentAreaSince: TimeInterval?
    private var screenSince: [ScreenID: TimeInterval] = [:]
    private var productViewedReported: Set<String> = []

    public init() {}

    // MARK: Session lifecycle

    public func start(session: SessionRecord) {
        events.removeAll(keepingCapacity: true)
        sequence = 0
        overflowed = false
        droppedEvents = 0
        currentArea = nil
        currentAreaSince = nil
        screenSince = [:]
        productViewedReported = []
        self.session = session
        isRecording = true
        append(FingerprintEvent(sequence: nextSequence(), timestamp: SessionClock.now, event: .sessionStart))
    }

    @discardableResult
    public func stop() -> (session: SessionRecord, events: [FingerprintEvent])? {
        guard isRecording, var session else { return nil }
        closeCurrentArea(at: SessionClock.now)
        append(FingerprintEvent(sequence: nextSequence(), timestamp: SessionClock.now, event: .sessionEnd))
        session.endedAt = SessionClock.now
        self.session = session
        isRecording = false
        return (session, events)
    }

    // MARK: Interaction events

    public func screenAppeared(_ screen: ScreenID, productID: String? = nil) {
        guard isRecording else { return }
        let now = SessionClock.now
        screenSince[screen] = now
        append(FingerprintEvent(
            sequence: nextSequence(), timestamp: now, event: .screenAppear,
            screen: screen, productID: productID
        ))
    }

    public func screenDisappeared(_ screen: ScreenID, productID: String? = nil) {
        guard isRecording else { return }
        let now = SessionClock.now
        let duration = screenSince[screen].map { (now - $0) * 1000 }
        screenSince[screen] = nil
        append(FingerprintEvent(
            sequence: nextSequence(), timestamp: now, event: .screenDisappear,
            screen: screen, productID: productID, durationMs: duration
        ))
    }

    /// A tap, with what the hardware can say about how it was made.
    ///
    /// Contact area and press duration are cheap to capture and are behavioural signals in
    /// their own right: a hesitant tap and a decisive one differ measurably.
    public func tapped(
        screen: ScreenID,
        target: TargetID,
        productID: String? = nil,
        at point: CGPoint,
        viewport: CGSize,
        contactArea: Double?,
        pressDurationMs: Double?
    ) {
        guard isRecording, viewport.width > 0, viewport.height > 0 else { return }
        var metrics: [String: Double] = [:]
        if let contactArea { metrics["contactRadiusPt"] = contactArea }
        append(FingerprintEvent(
            sequence: nextSequence(), timestamp: SessionClock.now, event: .tap,
            screen: screen, target: target, productID: productID,
            x: Double(point.x) / Double(viewport.width),
            y: Double(point.y) / Double(viewport.height),
            durationMs: pressDurationMs,
            metrics: metrics
        ))
    }

    /// Scroll position, throttled, with velocity and direction reversals.
    ///
    /// Reversals matter more than raw offset. Scrolling down steadily is reading; scrolling
    /// up and down repeatedly is searching, and the difference is a behavioural marker the
    /// offset alone does not carry.
    public func scrolled(screen: ScreenID, offset: Double, productID: String? = nil) {
        guard isRecording else { return }
        let now = SessionClock.now
        if let last = lastScrollAt, now - last < Self.scrollThrottle { return }

        var metrics: [String: Double] = ["offset": offset]
        if let last = lastScrollAt, let previous = lastScrollOffset {
            let elapsed = now - last
            if elapsed > 0 {
                let velocity = (offset - previous) / elapsed
                metrics["velocity"] = velocity
                if let lastVelocity, lastVelocity * velocity < 0 {
                    reversalCount += 1
                    metrics["reversal"] = 1
                }
                lastVelocity = velocity
            }
        }
        metrics["reversals"] = Double(reversalCount)

        lastScrollAt = now
        lastScrollOffset = offset
        append(FingerprintEvent(
            sequence: nextSequence(), timestamp: now, event: .scroll,
            screen: screen, productID: productID, metrics: metrics
        ))
    }

    private var lastScrollOffset: Double?
    private var lastVelocity: Double?
    private var reversalCount = 0

    public func wentBack(from screen: ScreenID, productID: String? = nil) {
        guard isRecording else { return }
        append(FingerprintEvent(
            sequence: nextSequence(), timestamp: SessionClock.now, event: .back,
            screen: screen, target: .backButton, productID: productID
        ))
    }

    public func productSelected(_ productID: String, on screen: ScreenID) {
        guard isRecording else { return }
        append(FingerprintEvent(
            sequence: nextSequence(), timestamp: SessionClock.now, event: .productSelected,
            screen: screen, target: .cta, productID: productID
        ))
    }

    /// Fires once per product, only after the detail screen has been up long enough that a
    /// glance in passing does not count as a view.
    public func noteProductVisible(_ productID: String, since: TimeInterval) {
        guard isRecording, !productViewedReported.contains(productID) else { return }
        let now = SessionClock.now
        guard now - since >= Self.productViewedAfter else { return }
        productViewedReported.insert(productID)
        append(FingerprintEvent(
            sequence: nextSequence(), timestamp: now, event: .productViewed,
            screen: .productDetail, productID: productID,
            durationMs: (now - since) * 1000
        ))
    }

    // MARK: Sensor events

    /// One gaze sample, with the region it landed on.
    public func recordGaze(
        _ sample: FaceSample,
        screen: ScreenID?,
        area: AreaOfInterest?
    ) {
        guard isRecording else { return }
        trackAreaTransition(to: area, at: sample.timestamp, screen: screen)
        append(FingerprintEvent(
            sequence: nextSequence(),
            timestamp: sample.timestamp,
            event: .gaze,
            screen: screen,
            target: area?.target,
            productID: area?.productID,
            x: sample.gazeX,
            y: sample.gazeY,
            eyesOpen: sample.eyesOpen,
            quality: sample.quality,
            signals: sample.signals
        ))
    }

    /// Ambient light, recorded because tracking quality and pupil size both depend on it.
    /// Without it, a session that was simply darker looks like a participant difference.
    public func recordAmbientLight(intensity: Double, temperature: Double) {
        guard isRecording else { return }
        append(FingerprintEvent(
            sequence: nextSequence(), timestamp: SessionClock.now, event: .ambientLight,
            metrics: ["ambientIntensity": intensity, "colourTemperature": temperature]
        ))
    }

    // MARK: Areas of interest

    private func trackAreaTransition(to area: AreaOfInterest?, at time: TimeInterval, screen: ScreenID?) {
        guard currentArea?.target != area?.target || currentArea?.productID != area?.productID else {
            return
        }
        closeCurrentArea(at: time)
        if let area {
            currentArea = area
            currentAreaSince = time
            append(FingerprintEvent(
                sequence: nextSequence(), timestamp: time, event: .areaEnter,
                screen: area.screen, target: area.target, productID: area.productID
            ))
        }
    }

    private func closeCurrentArea(at time: TimeInterval) {
        guard let area = currentArea, let since = currentAreaSince else { return }
        append(FingerprintEvent(
            sequence: nextSequence(), timestamp: time, event: .areaExit,
            screen: area.screen, target: area.target, productID: area.productID,
            durationMs: (time - since) * 1000
        ))
        currentArea = nil
        currentAreaSince = nil
    }

    // MARK: Buffer

    private func nextSequence() -> Int {
        sequence += 1
        return sequence
    }

    private func append(_ event: FingerprintEvent) {
        guard events.count < Self.bufferLimit else {
            droppedEvents += 1
            guard !overflowed else { return }
            overflowed = true
            // Recorded, not hidden. A gap that analysis cannot see is far worse than one
            // it can exclude.
            events.append(
                FingerprintEvent(
                    sequence: sequence, timestamp: SessionClock.now, event: .bufferOverflow
                )
            )
            return
        }
        events.append(event)
    }
}
