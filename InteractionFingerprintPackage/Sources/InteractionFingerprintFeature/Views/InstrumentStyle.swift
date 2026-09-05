import SwiftUI

/// Visual language for the sensing tools.
///
/// The reference points are optometry and metrology instruments rather than consumer
/// apps: things that measure and then state how uncertain the measurement is.
///
/// The near-black ground is a functional requirement, not a style choice. A bright screen
/// constricts the pupil and throws glare onto the cornea, both of which degrade the very
/// signal being measured, and any second bright element would compete for the fixation
/// the calibration depends on.
enum Instrument {
    /// Ground. Almost black, very slightly cool.
    static let ink = Color(red: 0.031, green: 0.035, blue: 0.043)
    /// Targets and primary type. Warm white, following the black-and-white fixation
    /// targets used in eye-tracking research.
    static let paper = Color(red: 0.925, green: 0.914, blue: 0.890)
    static let paperDim = Color(red: 0.925, green: 0.914, blue: 0.890).opacity(0.45)
    /// Live measurement. Amber is the instrument-panel colour, and unlike green it does
    /// not read as "passed", which would be a claim the tool has not yet earned.
    static let reticle = Color(red: 0.961, green: 0.773, blue: 0.094)
    /// Error vectors on the residual map. Cool against the warm measurement colour, so
    /// "what we measured" and "how wrong we were" never blur together.
    static let residual = Color(red: 0.420, green: 0.651, blue: 1.0)
    /// Out of envelope.
    static let warn = Color(red: 0.878, green: 0.424, blue: 0.314)

    /// Field label: the vernacular of an instrument panel.
    static func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(Instrument.paperDim)
    }

    /// Any number on screen is monospaced. A reading that changes width as it updates
    /// cannot be read at a glance.
    static func reading(_ text: String, size: CGFloat = 13) -> some View {
        Text(text)
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .foregroundStyle(Instrument.paper)
    }
}
