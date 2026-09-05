---
name: arkit-truedepth
description: Access face, eye, and gaze signals through ARKit face tracking on TrueDepth iPhones: ARFaceTrackingConfiguration, ARFaceAnchor, lookAtPoint, eye transforms, blend shapes, and mapping gaze to screen coordinates. Use for anything in Tracking/. Priority: now.
---
# ARKit / TrueDepth face and gaze tracking

There is no separate TrueDepth SDK. Everything comes through ARKit's `ARFaceTrackingConfiguration`.

## Setup

```swift
guard ARFaceTrackingConfiguration.isSupported else { /* show unsupported message */ }
let config = ARFaceTrackingConfiguration()
config.maximumNumberOfTrackedFaces = 1
session.delegate = self            // ARSessionDelegate
session.run(config, options: [.resetTracking, .removeExistingAnchors])
```

Requires `NSCameraUsageDescription` (already set in `Config/Shared.xcconfig`). Does **not** run in
the Simulator. Devices: iPhone X and later with Face ID, and iPad Pro with Face ID.

## What ARFaceAnchor gives you per frame (about 60 Hz)

- `transform`: face position and rotation relative to the camera. Record position (x, y, z) and
  rotation (as Euler angles or quaternion). This is the "face/head" signal in the guide.
- `leftEyeTransform`, `rightEyeTransform`: per-eye pose.
- `lookAtPoint`: estimated point the eyes converge on, in face-anchor space.
- `blendShapes`: dictionary of `ARFaceAnchor.BlendShapeLocation` to `NSNumber` in 0...1.
  V0 records only: `eyeBlinkLeft/Right`, `eyeSquintLeft/Right`, `eyeWideLeft/Right`,
  `browInnerUp`, `browOuterUpLeft/Right`. Do not record all 52 yet.
  Those are Swift case names. The `rawValue` strings that reach the exported data are
  different: `eyeBlink_L`, `eyeSquint_R`, `browOuterUp_L` and so on. Use
  `TrackedBlendShapes.keys` rather than writing either spelling by hand.
- `isTracked`: false when the face is lost. Record it. Gaps are data.

Use `session(_:didUpdate anchors:)` for anchors and `session(_:didUpdate frame:)` for the frame
timestamp (`frame.timestamp`, seconds, monotonic). Use the frame timestamp as the master clock.

## Projecting gaze onto the screen

1. Compute a point along the look direction: `lookAtPoint` in anchor space →
   `anchor.transform * lookAtPoint` gives world space (camera space when world alignment is camera).
2. Project with `frame.camera.projectPoint(_:orientation:viewportSize:)` using the current
   interface orientation and the screen size in points.
3. The front camera image is mirrored relative to the screen; flip x if the dot moves the wrong way.
4. Smooth with a low-pass filter (alpha around 0.1 to 0.3) for the debug dot only. Store the
   **raw** point in the data and note the filter parameters if you also store smoothed values.
5. Normalize to 0...1 of screen width/height for storage (`gazeX`, `gazeY`). Keep the raw device
   points too if storage is not a problem.

Accuracy is coarse (roughly 1 to 3 cm at arm's length). Design areas of interest large enough
to tolerate that. Add a short 5-point calibration screen and store its residuals per session.

## Existing package

`docs/INTERACTION_FINGERPRINT_XCODE_SETUP.md` suggests `kyle-fox/ios-eye-tracking`. It is
unmaintained since 2020 and pins GRDB 4, which does not compile with Xcode 26. If it is present
in this repo it lives under `Vendor/` as a patched local package. Treat its `EyeTracking.swift`
as reference code for the projection math and 60 fps recording loop.

## Common failures

- Dot frozen: session paused in background. Restart on `scenePhase == .active`.
- Dot mirrored or rotated: orientation passed to `projectPoint` does not match the UI.
- Face tracking stops in low light or with sunglasses. Log `isTracked` transitions.
- Battery and heat: stop the session the moment recording ends.

## Related
`ios-camera-privacy`, `interaction-instrumentation`, `eye-tracking-concepts`.
