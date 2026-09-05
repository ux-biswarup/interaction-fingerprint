# System Architecture

## V0

```text
iPhone / TrueDepth
        ↓
      ARKit
        ↓
Interaction Events
        ↓
JSON / SQLite
        ↓
Python Analysis
```

## Future

```text
USER
 ↓
Perception Layer
(gaze / face / touch / behavior)
 ↓
Interaction Fingerprint
 ↓
Agent / Reasoning
 ↓
Generative UI
 ↓
Adaptive Experience
 ↓
USER ↺
```

## Technology
- iOS: Swift + SwiftUI
- Perception: ARKit / TrueDepth
- Tracking: own ARKit wrapper in `Tracking/`, with per-person gaze calibration.
  `ios-eye-tracking` was evaluated and rejected: unmaintained since 2020, pins a GRDB
  version that no longer compiles, and projects gaze onto the camera image plane rather
  than the screen plane, which flattens the vertical axis. A patched copy is kept in
  `Vendor/EyeTracking/` as reference only and is not linked into the app.
- Storage: JSON initially; SQLite when required
- Analysis: Python + Pandas + statistics/ML
- Research automation: PRAXIST after a stable dataset and evaluator
- Agent: later
- Generative UI: later

Keep sensing, data modeling, storage and UI decoupled.
