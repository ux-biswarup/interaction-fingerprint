import SwiftUI

public struct ContentView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            Text("Interaction Fingerprint")
                .font(.title2.weight(.semibold))
            Text(FaceTrackingSupport.statusDescription)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(FaceTrackingSupport.isSupported ? .green : .secondary)
        }
        .padding()
    }
}
