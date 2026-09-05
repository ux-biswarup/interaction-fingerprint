---
name: python-pandas
description: Analyze exported Interaction Fingerprint sessions in Python with pandas: loading JSON/JSONL exports, normalizing events, computing dwell/revisit/transition features, and structuring the Analysis/ folder. Use for anything under Analysis/. Priority: now.
---
# Python + pandas for session analysis

## Environment

```bash
cd Analysis
python3 -m venv .venv && source .venv/bin/activate
pip install pandas numpy pyarrow matplotlib jupyter
pip freeze > requirements.txt
```

Commit `requirements.txt`. Never commit `.venv/` or anything under `Data/`.

## What exists

`Analysis/evaluate_gaze.py` judges a calibration and sessions offline: axis check, gain
table per gaze source, grid CV, and gaze-before-tap error. `Analysis/fingerprint/` holds the
loaders, the display geometry and the head-plus-eye gaze model, mirroring the app's Swift.
Start there before writing new analysis; see `Analysis/README.md`.

**The judge is gaze-before-tap error on free-viewing sessions, not grid accuracy.** The
grid has been wrong about free viewing every time the two disagreed.

## Layout

```text
Analysis/
├── requirements.txt
├── fingerprint/            # importable package
│   ├── load.py             # read exports into DataFrames
│   ├── features.py         # dwell, revisits, transitions, hesitation
│   └── quality.py          # gap detection, tracking loss, sample-rate checks
├── notebooks/              # exploratory; clear outputs before committing
└── tests/                  # pytest for features.py using a tiny synthetic session
```

## Loading

```python
import json, pandas as pd
def load_session(path):
    with open(path) as f:
        doc = json.load(f)
    events = pd.json_normalize(doc["events"], sep="_")   # signals_eyeBlinkLeft, head_pitch ...
    events["t"] = events["timestamp"] - events["timestamp"].min()
    return doc["session"], events.sort_values("sequence").reset_index(drop=True)
```

For `.jsonl`: `pd.read_json(path, lines=True)`. Cast `event`, `screen`, `target` to `category`.

## Data quality first, always

- Check `sequence` is contiguous: `events["sequence"].diff().dropna().ne(1).sum()` should be 0.
- Sample rate: `1 / events.query("event == 'gaze'")["t"].diff().median()` should be near 60 or 30.
- Tracking loss: share of gaze rows with `isTracked == False`. Report it per session.
- Print these in every notebook before any feature.

## Feature recipes

- Dwell per target: group consecutive gaze rows by run of `target`
  (`(events.target != events.target.shift()).cumsum()`), then sum durations per run.
- Revisits: number of runs per target minus one.
- Transition matrix: `pd.crosstab(run_targets.shift(), run_targets)`.
- Hesitation: time from the last gaze run on `add_to_cart` to the `tap` on it.
- Always return tidy frames: one row per (session, screen, target, feature, value).

## Rules

- Functions take DataFrames and return DataFrames; no global state. Test them with a synthetic
  ten-event session in `tests/`.
- Keep raw events immutable. Derived frames get new names.
- Save intermediate tables as Parquet under `Data/derived/` (git-ignored).

## Related
`fingerprint-data-modeling`, `basic-statistics`, `data-visualization`, `time-series-analysis`.
