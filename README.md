# Interaction Fingerprint

Research prototype that captures **observable interaction signals** on iPhone
(gaze, eye and brow blend shapes, head pose, taps, scrolls, dwell) and combines
them into a normalized event stream: the *Interaction Fingerprint*.

The guiding principle: **capture observable signals, do not label them as emotions.**
Record `eyeSquintLeft = 0.42`, never `confused = true`.

## Status

V0 milestone: **iPhone → ARKit → raw signals → local JSON export**.
See the definition of done in [docs/INTERACTION_FINGERPRINT_XCODE_SETUP.md](docs/INTERACTION_FINGERPRINT_XCODE_SETUP.md#11-v0-definition-of-done).

## Requirements

- macOS with a current Xcode (built with Xcode 26)
- A physical iPhone with Face ID. **ARKit face tracking does not run in the Simulator.**
- Deployment target: iOS 18.0

## Layout

```text
interaction-fingerprint/
├── InteractionFingerprint.xcworkspace/   # Open this in Xcode
├── InteractionFingerprint.xcodeproj/     # Thin app shell
├── InteractionFingerprint/               # App target
│   ├── App/                              # @main entry point
│   └── Assets.xcassets/
├── InteractionFingerprintPackage/        # All feature code (Swift package)
│   └── Sources/InteractionFingerprintFeature/
│       ├── Views/                        # SwiftUI screens (product UI, debug gaze overlay)
│       ├── Tracking/                     # ARKit face/gaze session
│       ├── Fingerprint/                  # Event model + feature aggregation
│       ├── Models/                       # Codable data types
│       └── Storage/                      # SQLite / JSON export
├── Config/                               # xcconfig build settings + entitlements
├── Research/                             # Study design, hypotheses, protocols
├── Analysis/                             # Python / pandas notebooks and scripts
├── Data/                                 # Local session exports (git-ignored)
└── docs/                                 # Setup guide
```

Feature code lives in the Swift package so it can be unit-tested without a device.
The app target only launches the package's root view.

## Build and run

Open the workspace, select your iPhone as the run destination, sign with your
Apple ID, and run. Grant camera permission when prompted.

Before the first device build, copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig` and set your `DEVELOPMENT_TEAM`. That file is git-ignored.
Full procedure and troubleshooting: [docs/DEVICE_INSTALL.md](docs/DEVICE_INSTALL.md).

From the terminal, with [XcodeBuildMCP](https://xcodebuildmcp.com) installed:

```bash
xcodebuildmcp simulator build --workspace-path InteractionFingerprint.xcworkspace --scheme InteractionFingerprint --simulator-name 'iPhone 17'
```

The simulator build verifies compilation only. Face tracking needs a device.

## Privacy

Camera frames are processed on-device by ARKit. The app stores derived numeric
signals only. No video or images are recorded. Participant data under `Data/`
is never committed. See section 10 of the setup guide.

## License

MIT. See [LICENSE](LICENSE).
