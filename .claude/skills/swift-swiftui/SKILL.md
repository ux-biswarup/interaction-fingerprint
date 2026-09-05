---
name: swift-swiftui
description: Build the iPhone research app UI in Swift and SwiftUI: product screens, debug gaze overlay, session controls, navigation, and state. Use for any view, layout, state-management, or Swift language question in InteractionFingerprintPackage. Priority: now (learn first).
---
# Swift + SwiftUI for this project

Goal for V0: a **simple product-browsing UI** (list → product detail → back) that a participant
can use for 30 to 60 seconds while signals are recorded. It does not need to be pretty. It needs
to be instrumentable and stable.

## Where code goes

- All views and logic: `InteractionFingerprintPackage/Sources/InteractionFingerprintFeature/`
  - `Views/` SwiftUI screens and the debug gaze dot overlay
  - `Tracking/` ARKit session wrapper (see `arkit-truedepth`)
  - `Fingerprint/` event model and aggregation
  - `Models/` Codable structs
  - `Storage/` SQLite and JSON export
- The app target `InteractionFingerprint/App/` only contains `@main`. Do not add features there.
- Anything the app target uses must be `public` with a `public init()`.

## Patterns to use

- Swift 6 strict concurrency is on. UI state is `@MainActor`. ARKit delegate callbacks arrive on a
  background queue: hop to the main actor before touching `@Observable` state.
- Use `@Observable` classes for the recording session and the current screen state. Avoid
  view models per view; keep state in a small number of observable objects injected via
  `.environment(...)`.
- Every screen that participants see must have a **stable screen identifier** (`"product_list"`,
  `"product_detail"`) and every meaningful element a **stable target identifier** (`"price"`,
  `"add_to_cart"`). Attach them with a small `.instrumented(screen:target:)` view modifier.
- Report element frames in screen coordinates using `GeometryReader` + a coordinate space named
  at the root, so gaze points can be matched to areas of interest (AOIs). See
  `interaction-instrumentation`.
- Keep the layout fixed during a session. Layout shifts destroy AOI mapping.
- Tests: Swift Testing (`@Test`, `#expect`) in `InteractionFingerprintPackage/Tests/`. Pure
  logic (aggregation, export) must be testable without a device.

## Things that bite

- `ARSCNView` or a `UIView` from ARKit needs `UIViewRepresentable`. Gaze tracking does not require
  showing the camera feed; run the `ARSession` headless and only draw a dot for debugging.
- `Task` in `onAppear` for starting a session; cancel in `onDisappear`.
- Do not use `Timer` for sampling. Use ARKit's frame callback as the clock (60 Hz) and timestamp
  every event with the same monotonic clock (see `interaction-instrumentation`).

## Build and run

Use the XcodeBuildMCP tools. Simulator builds verify compilation only. Face tracking runs only on
a physical iPhone with Face ID. Check `ARFaceTrackingConfiguration.isSupported` at launch and show
a clear message when unsupported.
