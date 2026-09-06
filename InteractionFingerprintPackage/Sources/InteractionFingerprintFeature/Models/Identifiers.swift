import Foundation

/// Screens a participant can be on.
///
/// Declared once as an enum rather than written as strings at each call site. A screen
/// name that drifts by one character between the code that records it and the code that
/// analyses it produces an empty result set and no error, which is the worst kind of bug
/// a study can have.
public enum ScreenID: String, Codable, Sendable, CaseIterable {
    case productList = "product_list"
    case productDetail = "product_detail"
}

/// Semantic regions within a screen, from the experiment plan.
///
/// Gaze is matched against these, and dwell, revisits and transitions are all computed per
/// target. Adding one means adding a hypothesis about it.
public enum TargetID: String, Codable, Sendable, CaseIterable {
    case productImage = "product_image"
    case title
    case price
    case rating
    case reviews
    case description
    case cta
    case backButton = "back"
    case listItem = "list_item"
    /// The list screen's title bar. Not a hypothesis: it exists so that a tap or a gaze
    /// there is attributed to something rather than falling through to the default label.
    case header
}

/// What happened.
public enum EventKind: String, Codable, Sendable, CaseIterable {
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case screenAppear = "screen_appear"
    case screenDisappear = "screen_disappear"
    case tap
    case scroll
    case back
    case productViewed = "product_viewed"
    case productSelected = "product_selected"
    case gaze
    case areaEnter = "area_enter"
    case areaExit = "area_exit"
    case ambientLight = "ambient_light"
    /// Emitted rather than silently dropping data when the buffer cannot keep up.
    case bufferOverflow = "buffer_overflow"
}
