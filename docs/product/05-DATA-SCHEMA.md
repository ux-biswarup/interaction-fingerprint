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


## Implemented schema, version 1

One stream. Sensor samples and interaction events share a type and a table, because the
point of the fingerprint is that they are comparable in time. Splitting them would push the
join into analysis, where an off-by-one would be invisible.

### Columns on every row

| Column | Meaning |
| --- | --- |
| `schemaVersion` | 1. Bumped only with a note in this file. |
| `sequence` | Gapless within a session. A jump means events were lost, which analysis must be able to see rather than infer. |
| `timestamp` | Seconds on the device monotonic clock, the same base as `ARFrame.timestamp`. Never `Date()`, which jumps when the system clock is corrected. |
| `event` | One of the kinds below. |
| `screen` | `product_list` or `product_detail`. |
| `target` | The area of interest, or null. |
| `productID` | The product in view, or null. |
| `x`, `y` | Normalised to the screen, origin top left. Tap position, or gaze position. |
| `durationMs` | What just ended: a dwell, a press, a screen visit. |
| `metrics` | Event-specific numbers. Documented below. |
| `eyesOpen` | False during a blink. Sample kept so blink rate stays measurable. |
| `quality` | Why the gaze on this row is or is not trustworthy. |
| `signals` | Blend-shape coefficients, keyed by ARKit raw value. Nine expression shapes (`eyeBlink_L`, `eyeBlink_R`, `eyeSquint_L`, `eyeSquint_R`, `eyeWide_L`, `eyeWide_R`, `browInnerUp`, `browOuterUp_L`, `browOuterUp_R`) and eight eye-direction shapes (`eyeLookUp_L`, `eyeLookDown_L`, `eyeLookIn_L`, `eyeLookOut_L` and the `_R` set). |

Absent values are written as explicit `null`, never omitted, so pandas receives the same
columns on every row.

### Event kinds

`session_start`, `session_end`, `screen_appear`, `screen_disappear`, `tap`, `scroll`,
`back`, `product_viewed`, `product_selected`, `gaze`, `area_enter`, `area_exit`,
`ambient_light`, `buffer_overflow`.

`buffer_overflow` exists so that a dataset never has an unmarked hole in it.

### Keys inside `metrics`

| Key | On | Meaning |
| --- | --- | --- |
| `contactRadiusPt` | `tap` | Radius of the finger's contact patch, in points. A proxy for press firmness on hardware with no force sensor, which is every current iPhone. |
| `targetMinX`, `targetMinY`, `targetMaxX`, `targetMaxY` | `tap` | The tapped element's frame, normalised like `x` and `y`. The eyes rest on a row's label while the finger lands anywhere on the row, so gaze accuracy is judged against this frame, not the fingertip. Absent when the tap hit no registered area. |
| `offset` | `scroll` | Content offset in points. |
| `velocity` | `scroll` | Points per second, signed. |
| `reversal` | `scroll` | 1 on the row where direction changed. |
| `reversals` | `scroll` | Running count. Steady scrolling is reading; back and forth is searching. |
| `ambientIntensity` | `ambient_light` | Lumens. A covariate, not a signal: a darker room otherwise looks like a participant difference. |
| `colourTemperature` | `ambient_light` | Kelvin. |
| `eyeX`, `eyeY`, `eyeZ` | `gaze` | Eye midpoint in metres in the display frame: X to the participant's right, Y up the screen, Z towards the phone. `eyeZ` is negative; its magnitude is the viewing distance. Before 5 September 2026 (evening) these were in ARKit's landscape-native camera frame, with X and Y swapped relative to this; see `10-MOTION-FUSION.md` §11. |
| `convergenceU`, `convergenceV` | `gaze` | Gaze direction ratios from ARKit's convergence point, dx/dz and dy/dz. The physical measurement behind `x`, `y`. With these and the eye position, a session can be re-mapped offline under a better calibration. |
| `perEyeU`, `perEyeV` | `gaze` | The same from each eye's own orientation, averaged. |
| `headYawRad`, `headPitchRad`, `headRollRad` | `gaze` | Head orientation relative to the phone, in the display frame. Note that this changes when the phone turns, not only when the head does. |
| `pupilU`, `pupilV` | `gaze` | Pupil offset from the centre of the eye opening as a fraction of the opening's width, from Vision's face landmarks, averaged over both eyes and paired with the display axes. Null when no fresh landmarks were available. An experimental eye-in-head readout; see `11-LEARNED-EYE-MODEL.md`. |
| `learnedU`, `learnedV` | `gaze` | The learned eye model's eye-in-head estimate, ratios in the display frame, from two eye crops and the head direction. Null when the model did not run on that frame. See `11-LEARNED-EYE-MODEL.md`. |
| `headForwardU`, `headForwardV` | `gaze` | The head's forward direction as ratios in the same units as the gaze angles. The fixed-gain term of the gaze model: corrected gaze = head + f(gaze − head). |
| `deviceTiltRad` | `gaze` | How far the screen leans back from vertical, radians. 0 upright, π/2 flat facing up. From gravity, so it does not drift. How the phone is held is a covariate the analysis needs; a participant lying down is a different viewing geometry. |
| `deviceRollRad` | `gaze` | Sideways lean of the phone, radians. Positive when the top leans to the participant's right. |
| `deviceRotationRadPerS` | `gaze` | Smoothed angular speed of the phone. A hand-steadiness covariate. |
| `deviceDisturbanceMm` | `gaze` | How far the screen moved under the eyes over the last 120 ms. Above 20 the row's `quality` reads `device_moving`. See `10-MOTION-FUSION.md`. |

### Session record

Carries the session id, app version, device model and screen geometry, the clock anchor
that converts monotonic time to wall time, the gaze calibration in force, and the verified
eye laterality. A session without a laterality check cannot support any claim about one eye
against the other, and a session without a calibration figure cannot be pooled with one
that has a good figure.

### Files

Two per session, in the app's Documents directory and shareable from the app.
`session_<uuid>.json` holds the session record and every event. `session_<uuid>.jsonl`
holds one event per line, which pandas reads with `lines=True`.

One per accepted calibration, `calibration_<unix seconds>.json`: the chosen model, the
number of targets that failed the fixation check, and every frame the fit used, each with
its target, target index, both gaze measurements (angles, eye position, distance, head
pose, folded eye-direction shapes). The accuracy figure says how good a calibration is;
these points say where it is weak. The most recent one is shared along with a session.
