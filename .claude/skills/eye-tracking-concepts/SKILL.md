---
name: eye-tracking-concepts
description: Eye-tracking vocabulary and algorithms applied to ARKit gaze data: fixations, saccades, dwell, scan paths, areas of interest, dispersion-based fixation detection, and the accuracy limits of TrueDepth gaze. Use when defining or computing gaze features. Priority: next.
---
# Eye-tracking concepts for ARKit data

## Vocabulary

- **Gaze point**: where the eyes are estimated to look on screen at one sample.
- **Fixation**: gaze held within a small area for at least about 100 ms. Where processing happens.
- **Saccade**: rapid jump between fixations (20 to 80 ms). Little or no visual intake.
- **Dwell**: total time gaze stays within one AOI during one visit, or summed over visits.
- **Revisit**: a return to an AOI after looking elsewhere.
- **Scan path**: ordered sequence of fixations. Compare with transition matrices or string edit
  distance over AOI labels.
- **AOI (area of interest)**: a screen region with a semantic label (`price`, `image`).
- **Time to first fixation**: latency until an AOI is first fixated after it appears.

## What ARKit gaze actually is

`lookAtPoint` is an eye-convergence estimate from the face model, not a pupil-based tracker.
Expect 1 to 3 cm error at 30 to 40 cm distance, drift with head movement, and worse accuracy near
screen edges. Consequences:

- AOIs must be large (at least 60 to 80 points in each dimension). Merge small elements.
- Fixation thresholds must be loose: dispersion 60 to 100 points, minimum duration 100 to 150 ms.
- Always report per-session calibration residuals and exclude sessions above a threshold.
- Blinks appear as `isTracked` drops or `eyeBlink` near 1. Remove gaze samples where either
  `eyeBlinkLeft` or `eyeBlinkRight` exceeds 0.5 before fixation detection.

## Fixation detection (I-DT, dispersion threshold)

```text
window = samples covering min_duration (e.g. 120 ms)
while samples remain:
    if (max(x) - min(x)) + (max(y) - min(y)) of window <= dispersion_threshold:
        extend window while the dispersion condition still holds
        emit fixation (centroid, start, end)
    else:
        drop first sample of window
```

Implement in `Analysis/fingerprint/features.py`, parameterized, unit-tested on a synthetic path.
Store parameters alongside results. On device, only the AOI hit per sample is computed.

## Features that matter for the fingerprint

dwell per AOI, revisit count, transition matrix, share of tracked time per AOI (attention
distribution), fixation count and mean duration, time to first fixation on the actionable
element, and hesitation (last fixation on the target to tap). Define each with units in
`docs/product/12-FINGERPRINT-FEATURES.md`.

## Do not

- Infer emotion or confusion from squint or brow values. They are observable signals only.
- Compare raw sample counts across sessions with different tracking-loss rates. Normalize by
  tracked time.

## Related
`arkit-truedepth`, `fingerprint-data-modeling`, `python-pandas`.
