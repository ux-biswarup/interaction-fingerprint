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

## The desk: live dashboard and automatic transfer

```bash
pip3 install --user aiohttp zeroconf           # once
python3 Analysis/dashboard/server.py --open    # http://localhost:8765
```

The phone finds the desk on the local network by itself, streams every event while a
session records, and uploads whatever it recorded while away. The desk writes the same
files the app exports into `Data/` and shows the live gaze, taps and fingerprint. See
`docs/product/13-DESK-LINK.md`.

## Compute a session's fingerprint (Phase 3)

```bash
python3 Analysis/fingerprint_session.py Data/session_<uuid>.jsonl [more sessions]
```

Prints fixations and saccades, dwell and revisits per area of interest (from the app's
per-sample attribution and from fixations), gaze transitions, tap character with first
look and hesitation, scroll rhythm, face and holding covariates, and navigation counts;
writes `Data/derived/fingerprint_<uuid>.json`; with several sessions ends with a
side-by-side table. Every feature is defined with units in
`docs/product/12-FINGERPRINT-FEATURES.md`, and the thresholds used are stored in the output.

## Phase 1b: the learned eye model

`eyemodel/` holds the dataset readers, eye-crop extraction, the network, training,
evaluation and the Core ML export. It trains on MPIIFaceGaze (direct download, CC BY-NC-SA
4.0, cite Zhang et al. CVPRW 2017), unpacked anywhere outside the repository:

```bash
python3 -m eyemodel.train --root ~/Datasets/MPIIFaceGaze/MPIIFaceGaze --epochs 20 \
    --holdout p12,p13,p14 --augment --out ~/Datasets/eyemodel.pt
python3 -m eyemodel.evaluate --root ~/Datasets/MPIIFaceGaze/MPIIFaceGaze \
    --weights ~/Datasets/eyemodel.pt --subjects p12,p13,p14
python3 -m eyemodel.export_coreml --weights ~/Datasets/eyemodel.pt --out ~/Datasets/EyeInHead.mlpackage
xcrun coremlcompiler compile ~/Datasets/EyeInHead.mlpackage ~/Datasets/EyeInHead_compiled
# then copy EyeInHead.mlmodelc into the package's Resources/ folder
```

The dataset is never copied into this repository. See `docs/product/11-LEARNED-EYE-MODEL.md`.

## Layout

```text
Analysis/
├── evaluate_gaze.py        # judge a calibration and its sources against taps
├── fingerprint_session.py  # the Interaction Fingerprint of a session
├── dashboard/
│   ├── server.py           # the desk: receives from the phone, serves the dashboard
│   └── static/             # the dashboard page, script and styles
├── fingerprint/
│   ├── load.py             # sessions, gaze rows, taps, calibration frames
│   ├── geometry.py         # the display geometry the app uses
│   ├── gaze.py             # head-plus-eye model, fitting, CV, gaze-before-tap
│   └── features.py         # fixations, dwell, transitions, taps, scroll, face, navigation
├── eyemodel/
│   ├── gazecapture.py      # GazeCapture reader, crops, direction labels
│   ├── mpiifacegaze.py     # MPIIFaceGaze reader with head pose
│   ├── dataset.py          # torch Dataset of eye crops
│   ├── model.py            # the two-branch network
│   ├── train.py            # training with person-level hold-out
│   ├── evaluate.py         # per-person correlation, gain and error
│   └── export_coreml.py    # Core ML conversion with a parity check
└── tests/                  # synthetic checks; no participant data
```

Nothing under `Data/` is committed. Keep it that way.
