import SwiftUI

/// The stimulus palette and type scale.
///
/// Every colour is stated explicitly rather than taken from the semantic system colours,
/// and the whole surface is pinned to the light appearance. That is a research requirement,
/// not a style preference: a participant whose phone is in dark mode must see exactly the
/// same screen as one whose phone is not, or the stimulus has quietly become a variable.
///
/// The look is deliberately unremarkable. It should read as a competent, ordinary shop.
/// Anything distinctive would draw the eye for its own sake, and the study measures where
/// people look.
enum Shop {
    static let background = Color(red: 0.961, green: 0.961, blue: 0.969)
    static let surface = Color.white
    static let ink = Color(red: 0.110, green: 0.110, blue: 0.118)
    static let inkSecondary = Color(red: 0.431, green: 0.431, blue: 0.451)
    static let inkTertiary = Color(red: 0.612, green: 0.612, blue: 0.639)
    static let hairline = Color(red: 0.898, green: 0.898, blue: 0.918)
    /// A plain retail blue. Recognisable as a call to action without being memorable.
    static let action = Color(red: 0.039, green: 0.384, blue: 0.816)
    static let star = Color(red: 0.961, green: 0.651, blue: 0.137)
    /// Neutral tint behind product imagery, so no product is more eye-catching than another.
    static let imageWell = Color(red: 0.925, green: 0.929, blue: 0.941)
}
