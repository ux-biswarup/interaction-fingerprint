# Data Schema

## Principles
1. Timestamp everything.
2. Keep raw observations separate from inferred states.
3. Exclude personally identifying information.
4. Prefer on-device processing.
5. Store only signals needed for the research question.
6. Associate events with session, screen and UI target.
7. Record calibration quality with every session. An uncalibrated or poorly calibrated
   session is not comparable with a good one, and pooling them hides real effects.

## Event example

```json
{
  "timestamp": 1725543210.42,
  "screen": "product_detail",
  "target": "price",
  "event": "gaze",
  "gazeX": 0.61,
  "gazeY": 0.38,
  "rawGazeX": 0.0123,
  "rawGazeY": -0.0417,
  "isCalibrated": true,
  "eyesOpen": true,
  "durationMs": 1800,
  "signals": {
    "eyeSquint_L": 0.21,
    "eyeSquint_R": 0.19,
    "eyeBlink_L": 0.03,
    "eyeBlink_R": 0.04
  }
}
```

Notes on the fields above, all verified against ARKit on device:

- Signal keys are ARKit's own `rawValue` strings, which are **not** the Swift case names.
  `.eyeBlinkLeft` serialises as `eyeBlink_L`. A test pins these so an SDK change cannot
  silently rename every analysis column.
- `gazeX` and `gazeY` are normalised to the screen, origin top left. `rawGazeX` and
  `rawGazeY` are the physical intersection of the gaze ray with the plane of the display,
  in metres in camera space. The raw pair is kept because it does not depend on the
  calibration in force during recording, so an old session can be re-mapped offline if a
  better calibration is fitted later.
- `isCalibrated` is false when the values came from the uncalibrated geometric fallback.
  Those sessions must not be pooled with calibrated ones.
- `eyesOpen` is false during a blink. Gaze is meaningless then and must be filtered before
  fixation detection, but the sample is still recorded so blink rate stays measurable.
- Optional fields are written as explicit `null`, never omitted, so pandas receives a
  stable column set.

## Derived features
Examples:
- `gaze_dwell_ms`
- `gaze_transition_count`
- `price_revisit_count`
- `product_revisit_count`
- `backtrack_count`
- `decision_time_ms`
- `attention_share_by_area`
- `hesitation_ms`

Derived features must not overwrite raw observations.

## Areas of interest
Map gaze coordinates to semantic UI regions such as:
`product_image`, `price`, `rating`, `reviews`, `description`, `cta`.
