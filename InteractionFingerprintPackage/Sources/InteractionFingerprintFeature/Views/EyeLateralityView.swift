import SwiftUI

/// The wink test. Resolves which physical eye each ARKit channel reports on.
struct EyeLateralityView: View {
    let check: EyeLateralityCheck
    let onAccept: (EyeLaterality) -> Void
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Instrument.ink.ignoresSafeArea()

            switch check.phase {
            case .settling, .measuring:
                prompting
            case .finished(let result, let disagreed):
                finished(result, disagreed: disagreed)
            }
        }
        .padding(24)
    }

    private var prompting: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Instrument.label("Eye labels")
                Text(check.instruction)
                    .font(.system(size: 24, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Instrument.paper)
                Text("Apple's documentation and this device disagree about which channel is which eye. Rather than guess, we measure it.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Instrument.paperDim)
                    .padding(.horizontal, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()

            VStack(spacing: 8) {
                channel("eyeBlink_L", value: check.peakLeftChannel)
                channel("eyeBlink_R", value: check.peakRightChannel)
            }
            .padding(.bottom, 24)

            Button("Cancel", action: onCancel)
                .font(.footnote)
                .foregroundStyle(Instrument.paperDim)
        }
    }

    private func channel(_ name: String, value: Double) -> some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 88, alignment: .leading)
                .foregroundStyle(Instrument.paperDim)
            ProgressView(value: min(max(value, 0), 1))
                .tint(Instrument.reticle)
            Text(String(format: "%.2f", value))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(Instrument.paper)
        }
    }

    @ViewBuilder
    private func finished(_ result: EyeLaterality?, disagreed: Bool) -> some View {
        VStack(spacing: 0) {
            Spacer()
            if let result {
                VStack(spacing: 12) {
                    Instrument.label("Measured")
                    Text("eyeBlink_L is your\n\(result.arkitLeftIsParticipantRight ? "right" : "left") eye")
                        .font(.system(size: 26, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Instrument.paper)
                    Text(String(format: "Separation %.2f", result.separation))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Instrument.paperDim)
                    if result.arkitLeftIsParticipantRight {
                        Text("This is the opposite of Apple's documentation. The measurement wins, and every export will carry the verified side.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Instrument.paperDim)
                            .padding(.horizontal, 20)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button { onAccept(result) } label: {
                    Text("Save this mapping").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Instrument.reticle)
                .foregroundStyle(Instrument.ink)
                .controlSize(.large)
            } else {
                VStack(spacing: 12) {
                    Instrument.label("Inconclusive")
                    Text(disagreed ? "The two winks disagreed" : "Neither eye closed clearly")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Instrument.paper)
                        .multilineTextAlignment(.center)
                    Text(disagreed
                         ? "That usually means one wink closed the wrong eye. Try again, closing only the eye named."
                         : "Close the named eye fully and keep the other wide open, then hold still.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Instrument.paperDim)
                        .padding(.horizontal, 20)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            Button("Run it again", action: onRetry)
                .font(.footnote)
                .foregroundStyle(Instrument.paperDim)
                .padding(.top, 10)
            Button("Cancel", action: onCancel)
                .font(.footnote)
                .foregroundStyle(Instrument.paperDim)
                .padding(.top, 6)
        }
    }
}
