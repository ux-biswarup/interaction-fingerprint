---
name: interaction-instrumentation
description: Capture app interaction events (taps, scrolls, back navigation, product viewed/selected, session start/end, dwell) with timestamps synchronized to gaze and face signals. Use when adding event logging, AOI hit-testing, or timing code. Priority: now.
---
# Interaction instrumentation

The fingerprint is only as good as the alignment between UI events and sensor samples. Everything
here is about **one clock, stable identifiers, and no missing events**.

## One clock

- Master clock: the ARKit frame timestamp (`ARFrame.timestamp`, seconds since boot, monotonic).
- UI events must use the same clock. Use `ProcessInfo.processInfo.systemUptime`, which is the same
  time base as `ARFrame.timestamp` and `CACurrentMediaTime()`. Never use `Date()` for ordering.
- Store one `Date()` at session start so the analysis can convert to wall time.

## Identifiers

- `screen`: `"product_list"`, `"product_detail"`, `"cart"`. Snake case, fixed, documented in
  `Research/screens.md`.
- `target`: element within a screen, e.g. `"price"`, `"image"`, `"title"`, `"add_to_cart"`,
  `"back"`. Also record the product ID separately as `productID`.
- Identifiers are strings in code exactly once, in an enum with raw values, to prevent drift.

## Events to record in V0

| event | when | fields |
| --- | --- | --- |
| `session_start`, `session_end` | recording toggled | device info, app version, calibration residual |
| `screen_appear`, `screen_disappear` | `onAppear` / `onDisappear` | `screen`, `productID` |
| `tap` | `.simultaneousGesture(TapGesture())` on instrumented views | `screen`, `target`, `productID`, x/y normalized |
| `scroll` | `ScrollView` offset changes, throttled to about 20 Hz | `screen`, `offsetY`, velocity |
| `back` | navigation pop | from `screen` to `screen` |
| `product_viewed` | detail screen visible for at least 500 ms | `productID` |
| `product_selected` | add to cart or select action | `productID` |
| `gaze` | every ARKit frame, or downsampled to 30 Hz | `gazeX`, `gazeY`, `isTracked`, `target` hit |
| `face` | every ARKit frame | blend shapes and head pose (may be merged into `gaze` rows) |
| `aoi_enter`, `aoi_exit` | gaze target changes | `target`, `durationMs` on exit |

## Areas of interest (AOIs)

- Each instrumented view reports its frame in the root coordinate space via a `PreferenceKey`.
- Maintain a registry `[screen: [target: CGRect]]` that updates on layout. Freeze layout during a
  session so this rarely changes.
- On each gaze sample, hit-test the point against the current screen's AOIs. Write the resulting
  `target` (or `nil`) into the gaze row. Compute dwell later in analysis, not on device, except for
  the debug overlay.

## Implementation notes

- A single `@Observable final class EventRecorder` on the main actor with `func record(_ event: FingerprintEvent)`.
  Append to an in-memory buffer and flush to SQLite every second or every 200 events.
- Do not drop events under load. If the buffer grows past a limit, log a `buffer_overflow` event
  rather than silently discarding.
- Include a monotonically increasing `sequence` number in every row to detect gaps.
- Log the debug overlay state (`gazeDotVisible: true/false`) as an event. It changes behavior.

## Related
`fingerprint-data-modeling`, `arkit-truedepth`, `swift-swiftui`.
