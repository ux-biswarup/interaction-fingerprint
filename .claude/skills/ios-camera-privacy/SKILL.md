---
name: ios-camera-privacy
description: Handle iOS camera permission, ARKit privacy requirements, on-device processing, and data minimization for the face-tracking research app. Use when touching Info.plist keys, permission prompts, data retention, or App Store / participant privacy wording. Priority: now.
---
# iOS camera and privacy APIs

## Permission

- Key: `NSCameraUsageDescription`. In this project it is set in `Config/Shared.xcconfig` as
  `INFOPLIST_KEY_NSCameraUsageDescription` because the Info.plist is generated. Do not add a
  separate Info.plist unless you also remove `GENERATE_INFOPLIST_FILE`.
- ARKit prompts for camera access on the first `session.run`. Check status first with
  `AVCaptureDevice.authorizationStatus(for: .video)` and request with
  `await AVCaptureDevice.requestAccess(for: .video)` so the prompt appears at a moment you control,
  after the participant has read the study explanation.
- Handle `.denied` and `.restricted` with a screen that explains and deep-links to Settings via
  `UIApplication.openSettingsURLString`. Never loop the prompt.

## What ARKit face data is and is not

- Apple's rules: face-tracking data may only be used for the app's core feature, must not be used
  for advertising or shared with third parties, and the app needs a privacy policy. Keep a copy of
  the study's privacy notice in `Research/privacy-notice.md` and show a summary in the app.
- ARKit exposes derived geometry and blend-shape coefficients. The app **never** stores camera
  frames, `capturedImage`, depth maps, or face mesh vertices. Only numeric signals listed in the
  setup guide, section 7.
- No participant identifiers in the data. Sessions get a random UUID. Any mapping from UUID to a
  person stays on paper or in a separate encrypted file outside the repo.

## Data minimization checklist for every new signal

- Is it in the V0 list (gaze x/y, the nine eye/brow blend shapes, head pose, UI events)?
- Can the hypothesis be tested with a lower sample rate or a coarser value?
- Is it deleted when the participant asks? Provide a "delete this session" button.
- Does it leave the device? For V0 the answer is no; export is a manual JSON file transfer.

## Project settings

- `Config/InteractionFingerprint.entitlements` is empty and should stay empty for V0. No iCloud,
  no push, no background modes.
- `Data/` is git-ignored. Exports are written to the app's Documents directory so the participant
  or researcher can pull them with the Files app or Finder.

## Related
`privacy-responsible-ai`, `arkit-truedepth`.
