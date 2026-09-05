import SwiftUI
import UIKit

/// What the hardware can tell us about a single press.
public struct TouchMetrics: Sendable, Equatable {
    /// Where the touch ended, in the root coordinate space, in points.
    public let location: CGPoint
    /// Radius of the finger's contact patch, in points. A proxy for how firmly the screen
    /// was pressed on hardware without a force sensor, which includes every current iPhone.
    public let contactRadius: Double
    /// How long the finger stayed down.
    public let pressDurationMs: Double
    /// How far the finger travelled while down. A press that slides is a different gesture
    /// from one that lands cleanly.
    public let travelPoints: Double

    public init(location: CGPoint, contactRadius: Double, pressDurationMs: Double, travelPoints: Double) {
        self.location = location
        self.contactRadius = contactRadius
        self.pressDurationMs = pressDurationMs
        self.travelPoints = travelPoints
    }
}

/// Observes every touch in the window without altering any of them.
///
/// SwiftUI's own gestures hand back a location and nothing else. Contact area, press
/// duration and travel need the underlying `UITouch`, which means a gesture recogniser.
/// This one never recognises: it watches, reports, and gets out of the way, so the app's
/// real buttons and scroll views behave exactly as they would without it.
public struct TouchObserver: UIViewRepresentable {
    public var onTouch: (TouchMetrics) -> Void

    public init(onTouch: @escaping (TouchMetrics) -> Void) {
        self.onTouch = onTouch
    }

    public func makeUIView(context: Context) -> UIView {
        let view = PassthroughView()
        context.coordinator.recogniser.onTouch = onTouch
        return view
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.recogniser.onTouch = onTouch
        // Attached to the window rather than to this view, because a view sized to nothing
        // receives no touches, and one sized to everything would sit on top of the app.
        guard let window = uiView.window,
              context.coordinator.attachedTo !== window else { return }
        context.coordinator.attachedTo?.removeGestureRecognizer(context.coordinator.recogniser)
        window.addGestureRecognizer(context.coordinator.recogniser)
        context.coordinator.attachedTo = window
    }

    public static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.attachedTo?.removeGestureRecognizer(coordinator.recogniser)
        coordinator.attachedTo = nil
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    public final class Coordinator {
        let recogniser = ObservingRecogniser()
        var attachedTo: UIWindow?

        init() {}
    }

    /// Zero-sized and invisible to hit testing, so it cannot intercept anything.
    private final class PassthroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
}

/// A recogniser that reports touches and never claims them.
public final class ObservingRecogniser: UIGestureRecognizer {
    var onTouch: ((TouchMetrics) -> Void)?

    private var startedAt: TimeInterval?
    private var startLocation: CGPoint?
    private var peakRadius: Double = 0

    public override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        // Both of these are essential. Without them the app's own buttons stop working.
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    convenience init() { self.init(target: nil, action: nil) }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        startedAt = SessionClock.now
        startLocation = touch.location(in: view)
        peakRadius = Double(touch.majorRadius)
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        peakRadius = max(peakRadius, Double(touch.majorRadius))
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        defer { reset() }
        guard let touch = touches.first, let startedAt, let startLocation else { return }
        let end = touch.location(in: view)
        onTouch?(
            TouchMetrics(
                location: end,
                contactRadius: max(peakRadius, Double(touch.majorRadius)),
                pressDurationMs: (SessionClock.now - startedAt) * 1000,
                travelPoints: hypot(end.x - startLocation.x, end.y - startLocation.y)
            )
        )
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        reset()
    }

    public override func reset() {
        super.reset()
        startedAt = nil
        startLocation = nil
        peakRadius = 0
        state = .possible
    }
}
