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

## Phase 1b: the learned eye model

`eyemodel/` holds the GazeCapture reader, eye-crop extraction, the network and the training
entry point. It needs the dataset, requested under its research licence from
http://gazecapture.csail.mit.edu/download.php, unpacked to a folder of numbered subjects:

```bash
python3 -m eyemodel.train --root /path/to/GazeCapture --limit 50 --epochs 3   # smoke run
python3 -m eyemodel.train --root /path/to/GazeCapture --epochs 20
```

The dataset is never copied into this repository. See `docs/product/11-LEARNED-EYE-MODEL.md`.

## Layout

```text
Analysis/
├── evaluate_gaze.py        # the command above
├── fingerprint/
│   ├── load.py             # sessions, gaze rows, taps, calibration frames
│   ├── geometry.py         # the display geometry the app uses
│   └── gaze.py             # head-plus-eye model, fitting, CV, gaze-before-tap
├── eyemodel/
│   ├── gazecapture.py      # dataset reader, crops, direction labels
│   ├── dataset.py          # torch Dataset of eye crops
│   ├── model.py            # the two-branch network
│   └── train.py            # training with person-level hold-out
└── tests/                  # synthetic checks; no participant data
```

Nothing under `Data/` is committed. Keep it that way.
