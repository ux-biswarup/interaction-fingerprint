# Interaction Fingerprint — Xcode Setup

A minimal setup guide for the iPhone/TrueDepth research prototype.

## 1. Prerequisites

- macOS
- Latest stable Xcode
- Physical iPhone with Face ID / supported face-tracking hardware
- Apple ID signed into Xcode
- USB cable or wireless device connection

**Important:** ARKit face tracking is not available in the iOS Simulator. Test on a physical device. Apple recommends checking `ARFaceTrackingConfiguration.isSupported` at runtime. [Apple ARKit documentation](https://developer.apple.com/documentation/arkit/tracking-and-visualizing-faces)

## 2. Project structure

Recommended initial structure:

```text
interaction-fingerprint/
├── InteractionFingerprint/
│   ├── App/
│   ├── Views/
│   ├── Tracking/
│   ├── Fingerprint/
│   ├── Models/
│   └── Storage/
├── Research/
├── Data/
├── Analysis/
├── README.md
└── .gitignore
```

Keep the first milestone small:

**iPhone → ARKit → raw signals → local JSON export**

Do not add agents or generative UI yet.

## 3. Create the iOS app target

If the repository is currently just a cloned Git repository:

1. Open Xcode.
2. Create **File → New → Project**.
3. Choose **iOS → App**.
4. Product Name: `InteractionFingerprint`
5. Interface: `SwiftUI`
6. Language: `Swift`
7. Save the project inside the cloned `interaction-fingerprint` repository.
8. Commit the generated Xcode project to Git.

Recommended deployment target: use a current iOS version supported by your installed Xcode rather than targeting an unnecessarily old OS.

## 4. Add required Apple frameworks

For the first prototype, use:

- `ARKit`
- `SwiftUI`
- `Foundation`

You do **not** need a separate TrueDepth SDK. TrueDepth face/eye tracking is exposed through ARKit.

ARKit's `ARFaceAnchor` provides:

- face transform
- left/right eye transforms
- `lookAtPoint`
- facial blend-shape coefficients

Apple documents 50+ blend-shape coefficients. [ARFaceAnchor](https://developer.apple.com/documentation/arkit/arfaceanchor)

## 5. Camera permission

Add this to the app target's `Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>This camera access is used to study gaze and facial interaction signals for the Interaction Fingerprint research prototype.</string>
```

Apple requires a camera usage description, and face-tracking apps also need an appropriate privacy policy when distributed. [Apple device support and privacy guidance](https://developer.apple.com/documentation/ARKit/verifying-device-support-and-user-permission)

## 6. Add the eye-tracking package

For the first version, use the existing open-source `ios-eye-tracking` package rather than building the tracking/storage layer from scratch.

Repository:

https://github.com/kyle-fox/ios-eye-tracking

In Xcode:

1. **File → Add Package Dependencies…**
2. Enter:
   `https://github.com/kyle-fox/ios-eye-tracking`
3. Select the package version/range offered by Xcode.
4. Add the `EyeTracking` product to your app target.

The package provides:

- 60fps gaze stream
- ARKit facial blend-shape recording
- SQLite persistence via GRDB
- JSON export
- fixation detection
- scan-path visualization

## 7. First signals to record

Do not record every possible facial coefficient initially.

Start with:

### Gaze
- gaze X
- gaze Y
- timestamp

### Eyes
- `eyeBlinkLeft`
- `eyeBlinkRight`
- `eyeSquintLeft`
- `eyeSquintRight`
- `eyeWideLeft`
- `eyeWideRight`

### Brows
- `browInnerUp`
- `browOuterUpLeft`
- `browOuterUpRight`

> Note: these are the Swift API names. ARKit's `rawValue` strings, which are what land in
> the exported JSON and in pandas columns, use a different spelling: `eyeBlink_L`,
> `eyeSquint_R`, `browOuterUp_L`, and so on. `browInnerUp` is the same in both.

### Face/head
- face position
- face rotation

### App behavior
- screen/product ID
- tap
- scroll
- back
- product viewed
- product selected
- session start/end

The important research principle is:

> **Capture observable signals. Do not label them as emotions.**

For example, record `eyeSquintLeft = 0.42`, not `confused = true`.

## 8. Define the Interaction Fingerprint

Create a normalized event model that combines sensor and product events.

Example:

```json
{
  "timestamp": 1725543210.42,
  "screen": "product_detail",
  "target": "price",
  "event": "gaze",
  "gazeX": 0.61,
  "gazeY": 0.38,
  "durationMs": 1800,
  "signals": {
    "eyeSquintLeft": 0.21,
    "eyeSquintRight": 0.19,
    "eyeBlinkLeft": 0.03,
    "eyeBlinkRight": 0.04
  }
}
```

Later, aggregate these raw events into higher-level features such as:

- dwell time
- revisit count
- gaze transitions
- backtracking
- attention distribution
- hesitation duration
- product comparison count

These aggregated features are the actual **Interaction Fingerprint**.

## 9. Device testing

Connect the physical iPhone and:

1. Select the iPhone as the Xcode run destination.
2. Sign the app with your Apple Developer account.
3. Build and run.
4. Grant camera permission.
5. Confirm face tracking starts.
6. Display a simple gaze point for debugging.
7. Record a 30–60 second session.
8. Export the session.
9. Verify timestamps and gaze coordinates.

Do not use the Simulator for this part.

## 10. Git workflow

Commit the project in small milestones:

```text
chore: create iOS app
feat: add ARKit face tracking
feat: add gaze recording
feat: add facial signal recording
feat: add interaction event model
feat: add session export
```

Do **not** commit:

- participant recordings
- raw face/camera video
- private research data
- API keys
- signing credentials
- personal identifiers

Add a `Data/` or `ResearchData/` ignore rule if participant data will be stored locally.

## 11. V0 definition of done

The first milestone is complete when:

- [ ] iOS app runs on a physical iPhone
- [ ] ARKit face tracking works
- [ ] gaze coordinates are captured
- [ ] selected eye/facial signals are captured
- [ ] app interaction events are captured
- [ ] events have synchronized timestamps
- [ ] one session can be exported as JSON
- [ ] no raw participant video is required for the fingerprint
- [ ] exported data can be loaded into Python for analysis

## 12. What comes next

After V0:

```text
Raw signals
    ↓
Interaction events
    ↓
Fingerprint features
    ↓
Small user study
    ↓
Baseline vs fingerprint
    ↓
Evidence
    ↓
Adaptive UI
    ↓
Agent
    ↓
Generative UI
```

**Do not introduce PRAXIST until you have a working dataset and a measurable evaluation function.**
