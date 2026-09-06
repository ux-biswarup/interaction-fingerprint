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
├── evaluate_gaze.py        # the command above
├── fingerprint/
│   ├── load.py             # sessions, gaze rows, taps, calibration frames
│   ├── geometry.py         # the display geometry the app uses
│   └── gaze.py             # head-plus-eye model, fitting, CV, gaze-before-tap
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
