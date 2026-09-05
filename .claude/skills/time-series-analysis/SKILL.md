---
name: time-series-analysis
description: Analyze gaze and facial signals as time series rather than isolated values: resampling, smoothing, change-point and burst detection, windowed features, alignment of UI events with sensor streams. Use when a question is about how signals evolve during a task. Priority: next.
---
# Time-series analysis of interaction signals

## Represent the session as aligned streams

- Sensor stream: gaze and blend shapes at 60 Hz (or 30 Hz), indexed by `t` seconds from session
  start, from the same monotonic clock as UI events.
- Event stream: sparse UI events (`tap`, `scroll`, `screen_appear`).
- Build a `DatetimeIndex` or `TimedeltaIndex` with `pd.to_timedelta(events.t, unit="s")` and
  resample the sensor stream to a fixed grid (`.resample("33ms").mean()`) so sessions align.

## Standard operations

- **Smoothing**: rolling median (window 5) for gaze position to kill single-sample jumps;
  exponential smoothing for blend shapes if needed. Keep raw columns alongside.
- **Windowing**: compute features in windows anchored to UI events, e.g. 2 s before each `tap`
  and 2 s after each `screen_appear`. Compare windows across conditions instead of whole sessions.
- **Change points**: detect shifts in blink rate or squint level with a simple CUSUM or the
  `ruptures` package. Report the timestamps and check them against observer notes.
- **Bursts**: blink bursts (3 or more blinks within 2 s) and saccade bursts. Count per minute.
- **Cross-correlation**: lag between a UI event (e.g. price appears) and a change in a signal
  (e.g. squint). Lags under 100 ms are not plausible responses; treat them as noise.
- **Rates**: blinks per minute, saccades per second, AOI switches per minute. Rates are
  comparable across sessions; counts are not.

## Quality checks before any of the above

gap detection (`t.diff()` above 2 sample periods), tracking-loss segments, sample-rate drift,
duplicated sequence numbers. Mark bad segments and exclude them from windowed features.

## Visuals that help

- Timeline plot: gaze target as colored bands, blend shapes as lines, UI events as vertical
  markers. One per session, saved to `Data/derived/plots/`.
- Event-locked average: mean squint from -2 s to +2 s around every `tap`, with a CI band.

## Related
`python-pandas`, `eye-tracking-concepts`, `data-visualization`, `basic-statistics`.
