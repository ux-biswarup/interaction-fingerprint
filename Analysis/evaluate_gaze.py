#!/usr/bin/env python3
"""Judge a calibration and its gaze sources against the grid and against taps.

    python3 Analysis/evaluate_gaze.py Data/calibration_*.json Data/session_*.jsonl

Prints, for every gaze source in the calibration file: the axis check, the gain table
(how much of the true eye rotation each readout carries), grid cross-validation of the
head-plus-eye model, and, for each session given, gaze-before-tap error and the share of
gaze on the display when that model is replayed on the session's raw rows.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent))
from fingerprint import gaze as gz  # noqa: E402
from fingerprint import load  # noqa: E402

pd.set_option("display.width", 160)

SESSION_COLUMNS = {"convergence": ("convergenceU", "convergenceV"), "perEye": ("perEyeU", "perEyeV"), "pupil": (None, None)}


def session_frame(gaze: pd.DataFrame, source: str) -> pd.DataFrame | None:
    g = gaze.rename(columns={"headForwardU": "headU", "headForwardV": "headV"})
    if "headU" not in g:
        return None
    if source == "pupil":
        if "pupilU" not in g:
            return None
        g = g.dropna(subset=["pupilU", "pupilV"]).copy()
        g["u"], g["v"] = g["headU"] + g["pupilU"], g["headV"] + g["pupilV"]
    else:
        cu, cv = SESSION_COLUMNS[source]
        if cu not in g:
            return None
        g["u"], g["v"] = g[cu], g[cv]
    return gz.with_eye_in_head(g)


def main(paths: list[str]) -> None:
    cal_paths = [p for p in paths if "calibration_" in Path(p).name]
    sess_paths = [p for p in paths if "session_" in Path(p).name]
    if not cal_paths:
        sys.exit("give one calibration_*.json")
    model, frames = load.load_calibration(sorted(cal_paths)[-1])
    print(f"calibration: {sorted(cal_paths)[-1]}")
    if model:
        b = model["basis"]
        print(f"  app chose: {model['source']} order {b['order']} camera {b['solvesCameraOffset']} "
              f"accuracy {model['accuracyPoints']:.0f} pt worst {model['worstTargetPoints']:.0f}")

    sessions = []
    for p in sess_paths:
        _, ev = load.load_session(p)
        sessions.append((Path(p).name[8:12], load.gaze_rows(ev), load.taps(ev)))

    for source, frame in frames.items():
        f = gz.with_eye_in_head(frame)
        print(f"\n=== source: {source}  ({len(f)} frames, {f['ti'].nunique()} targets, "
              f"distance {f['distance'].min():.2f}–{f['distance'].max():.2f} m)")
        print("  axis check   corr(u,trueU) %+.2f  corr(v,trueV) %+.2f  corr(u,trueV) %+.2f  corr(v,trueU) %+.2f" % (
            np.corrcoef(f["u"], f["trueU"])[0, 1], np.corrcoef(f["v"], f["trueV"])[0, 1],
            np.corrcoef(f["u"], f["trueV"])[0, 1], np.corrcoef(f["v"], f["trueU"])[0, 1]))
        cands = {"eye-in-head": ("eU", "eV")}
        if "lookU" in f:
            cands["blend shapes"] = ("lookU", "lookV")
        print(gz.gain_table(f, cands).round(3).to_string(index=False))

        for order in (1, 2):
            for ridge in (0, 1e-3):
                acc, worst = gz.grid_cv(f, order=order, ridge=ridge)
                m = gz.fit(f, order=order, ridge=ridge)
                line = f"  head+{'quadratic' if order == 2 else 'linear'} ridge {ridge:<6} grid CV {acc:6.1f} pt worst {worst:4.0f}  gain {tuple(round(g, 2) for g in m.diagonal_gain)}"
                for name, gaze, taps in sessions:
                    sf = session_frame(gaze, source)
                    if sf is None or sf.empty:
                        line += f" | {name}: n/a"
                        continue
                    px, py = m.predict(sf)
                    err, n = gz.gaze_before_tap(sf, taps, px, py)
                    line += f" | {name}: tap {err:4.0f} pt ({n}) on-display {gz.on_display(px, py):.2f}"
                print(line)

    for name, gaze, taps in sessions:
        px, py = gaze["x"].values, gaze["y"].values
        err, n = gz.gaze_before_tap(gaze, taps, px, py)
        print(f"\nsession {name} as recorded by the app: gaze-before-tap {err:.0f} pt ({n} taps), on-display {gz.on_display(px, py):.2f}, "
              f"{len(gaze)} good gaze rows")


if __name__ == "__main__":
    main(sys.argv[1:])
