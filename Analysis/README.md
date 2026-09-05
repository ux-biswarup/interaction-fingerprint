# Analysis

Python tooling that reads what the app exports and judges the gaze model offline. It
reproduces the app's own arithmetic, so a change to the model can be tried against real
frames before it is shipped.

```bash
cd Analysis
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python3 -m pytest -q tests
```

## Judge a calibration and a session

```bash
python3 Analysis/evaluate_gaze.py Data/calibration_<t>.json Data/session_<uuid>.jsonl
```

For every gaze source in the calibration file it prints:

- **Axis check.** Correlation of measured horizontal and vertical gaze with the true angles.
  The on-axis pair should be strongly positive, the cross pair near zero. This is what
  caught the rotated camera frame (`docs/product/10-MOTION-FUSION.md` §11).
- **Gain table.** For each readout, each axis, near and far pass: correlation with the true
  eye-in-head rotation and the fraction of it the readout reports. ARKit's eye transforms
  report a fifth to a third (§14). A readout worth adopting reports near one, consistently.
- **Grid cross-validation** of the head-plus-eye model, linear and quadratic, and, for every
  session given, **gaze-before-tap error** and the share of gaze on the display when that
  model is replayed on the session's raw rows. The tap figure is the one that matters; the
  grid has been wrong about free viewing every time it disagreed.

## Layout

```text
Analysis/
├── evaluate_gaze.py        # the command above
├── fingerprint/
│   ├── load.py             # sessions, gaze rows, taps, calibration frames
│   ├── geometry.py         # the display geometry the app uses
│   └── gaze.py             # head-plus-eye model, fitting, CV, gaze-before-tap
└── tests/                  # synthetic checks of the model arithmetic
```

Nothing under `Data/` is committed. Keep it that way.
