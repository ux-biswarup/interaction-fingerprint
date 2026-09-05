import UIKit

/// The window's real safe area, read directly from the scene.
///
/// The tracker deliberately ignores safe areas at the root, because gaze has to be mapped
/// against the whole physical display or the coordinates are wrong. That leaves the
/// stimulus with no insets of its own to work from, and content slides under the sensor
/// housing. This reads the true values back so the shop can lay itself out normally while
/// the measurement layer still sees the full screen.
@MainActor
enum SafeAreaProbe {
    static var insets: UIEdgeInsets {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow?.safeAreaInsets ?? .zero
    }

    static var top: CGFloat { insets.top }
    static var bottom: CGFloat { insets.bottom }
}
