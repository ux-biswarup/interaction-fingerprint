import SwiftUI

/// A semantic region of a screen that gaze can be attributed to.
public struct AreaOfInterest: Equatable, Sendable {
    public let screen: ScreenID
    public let target: TargetID
    public let productID: String?
    /// Frame in the root coordinate space, in points.
    public let frame: CGRect

    public init(screen: ScreenID, target: TargetID, productID: String?, frame: CGRect) {
        self.screen = screen
        self.target = target
        self.productID = productID
        self.frame = frame
    }
}

/// Collects the areas of interest currently on screen.
struct AreaOfInterestKey: PreferenceKey {
    static let defaultValue: [AreaOfInterest] = []
    static func reduce(value: inout [AreaOfInterest], nextValue: () -> [AreaOfInterest]) {
        value.append(contentsOf: nextValue())
    }
}

/// Where the gaze currently is, in semantic terms.
///
/// Hit testing happens here on device rather than in analysis so that dwell can be
/// computed live for the adaptive stages later, but the raw gaze coordinate is recorded
/// too. If the region definitions turn out to be wrong, a recording can be re-attributed
/// offline; if only the region label had been kept, it could not.
public struct AreaOfInterestRegistry: Sendable {
    public private(set) var areas: [AreaOfInterest] = []

    public init(areas: [AreaOfInterest] = []) {
        self.areas = areas
    }

    public mutating func update(_ areas: [AreaOfInterest]) {
        self.areas = areas
    }

    /// The region under a normalised gaze point, or nil if it fell on none.
    ///
    /// Later registrations win when regions overlap, matching how SwiftUI draws them: the
    /// thing on top is the thing being looked at.
    public func hitTest(normalised point: CGPoint, viewport: CGSize) -> AreaOfInterest? {
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let location = CGPoint(
            x: Double(point.x) * Double(viewport.width),
            y: Double(point.y) * Double(viewport.height)
        )
        return areas.last { $0.frame.contains(location) }
    }
}

public extension View {
    /// Marks this view as a measurable region.
    ///
    /// The frame is reported in the root coordinate space, which is why the root must
    /// declare `.coordinateSpace(.named(InstrumentationSpace.root))`. Without that the
    /// frames come back relative to the wrong ancestor and every gaze attribution is
    /// silently offset.
    func areaOfInterest(
        _ target: TargetID,
        on screen: ScreenID,
        productID: String? = nil
    ) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AreaOfInterestKey.self,
                    value: [
                        AreaOfInterest(
                            screen: screen,
                            target: target,
                            productID: productID,
                            frame: proxy.frame(in: .named(InstrumentationSpace.root))
                        )
                    ]
                )
            }
        }
    }
}

public enum InstrumentationSpace {
    public static let root = "interactionFingerprint.root"
}
