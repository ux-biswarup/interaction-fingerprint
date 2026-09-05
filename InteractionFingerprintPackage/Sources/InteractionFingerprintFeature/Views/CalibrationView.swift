import SwiftUI

/// Full screen calibration target sequence.
///
/// Deliberately austere. Anything else on screen competes for the gaze that is being
/// measured, which would bias the very samples the fit depends on.
struct CalibrationView: View {
    let run: GazeCalibrationRun
    let viewport: CGSize
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let target = run.currentTarget {
                target_marker
                    .position(
                        x: target.x * viewport.width,
                        y: target.y * viewport.height
                    )
            }

            VStack {
                Spacer()
                VStack(spacing: 6) {
                    Text(instruction)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let index = run.currentIndex {
                        Text("\(index + 1) of \(run.targets.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Button("Cancel", action: onCancel)
                        .font(.caption)
                        .padding(.top, 4)
                }
                .padding(.bottom, 28)
            }
        }
    }

    private var instruction: String {
        switch run.phase {
        case .settling: "Look at the circle"
        case .collecting: "Hold still"
        default: ""
        }
    }

    private var isCollecting: Bool {
        if case .collecting = run.phase { return true }
        return false
    }

    private var target_marker: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.35), lineWidth: 2)
                .frame(width: 44, height: 44)
            Circle()
                .fill(isCollecting ? Color.green : Color.white)
                .frame(width: isCollecting ? 16 : 10, height: isCollecting ? 16 : 10)
        }
        .animation(.easeInOut(duration: 0.2), value: isCollecting)
    }
}
