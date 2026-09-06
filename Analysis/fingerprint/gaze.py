"""Gaze model fitting and evaluation, mirroring the app's `GazeModelFitter`.

The structure is fixed by physics (`docs/product/10-MOTION-FUSION.md` §11):

    corrected gaze = head direction + f(eye-in-head)

Only ``f`` is fitted. Inputs are standardised, the fit is ridge-regularised with the
penalty scaled to the data, and prediction holds inputs inside the calibrated range with
linear continuation beyond it.
"""
from __future__ import annotations

from dataclasses import dataclass
from itertools import combinations_with_replacement

import numpy as np
import pandas as pd

from . import geometry as geo

MARGIN = 0.15
RIDGE_GRID = (0, 1e-5, 1e-4, 1e-3, 1e-2, 1e-1)


def with_eye_in_head(frame: pd.DataFrame, source_u="u", source_v="v") -> pd.DataFrame:
    """Adds the eye-in-head columns ``eU, eV`` and the true ones ``teU, teV`` when targets exist."""
    f = frame.copy()
    f["eU"] = f[source_u] - f["headU"]
    f["eV"] = f[source_v] - f["headV"]
    if "tx" in f:
        tu, tv = geo.true_direction(f)
        f["trueU"], f["trueV"] = tu, tv
        f["teU"], f["teV"] = tu - f["headU"], tv - f["headV"]
    return f


def gain_table(frame: pd.DataFrame, candidates: dict[str, tuple[str, str]]) -> pd.DataFrame:
    """How much of the true eye-in-head rotation each candidate readout reports.

    ``candidates`` maps a label to the (horizontal, vertical) column names. For each pass
    (near/far by distance median) and axis: correlation with the truth, and the ratio of
    the span of per-target centroids to the span of the true centroids.
    """
    f = frame.copy()
    f["pass"] = np.where(f["distance"] < f["distance"].median(), "near", "far")
    rows = []
    for label, (cu, cv) in candidates.items():
        for ps, s in f.groupby("pass"):
            for axis, (col, truth) in {"horizontal": (cu, "teU"), "vertical": (cv, "teV")}.items():
                cent = s.groupby("ti")[[col, truth]].mean()
                span = (cent[col].max() - cent[col].min()) / (cent[truth].max() - cent[truth].min())
                rows.append(dict(readout=label, axis=axis, pass_=ps,
                                 r=np.corrcoef(s[col], s[truth])[0, 1], gain=span,
                                 within_target_sd=s.groupby("ti")[col].std().median()))
    return pd.DataFrame(rows)


@dataclass
class Model:
    cols: tuple[str, ...]
    order: int
    mu: np.ndarray
    sd: np.ndarray
    lo: np.ndarray
    hi: np.ndarray
    bu: np.ndarray
    bv: np.ndarray
    ridge: float

    def _terms(self, z):
        cols = [np.ones(len(z))] + [z[:, i] for i in range(z.shape[1])]
        if self.order == 2:
            cols += [z[:, i] * z[:, j] for i, j in combinations_with_replacement(range(z.shape[1]), 2)]
        return np.column_stack(cols)

    def _grad(self, z, axis):
        n = z.shape[1]
        zero, one = np.zeros(len(z)), np.ones(len(z))
        cols = [zero] + [one if i == axis else zero for i in range(n)]
        if self.order == 2:
            for i, j in combinations_with_replacement(range(n), 2):
                if i == j == axis:
                    cols.append(2 * z[:, i])
                elif i == axis:
                    cols.append(z[:, j])
                elif j == axis:
                    cols.append(z[:, i])
                else:
                    cols.append(zero)
        return np.column_stack(cols)

    def correct(self, frame: pd.DataFrame, bounded=True):
        raw = frame[list(self.cols)].values
        if bounded:
            slack = (self.hi - self.lo) * MARGIN
            rb = np.clip(raw, self.lo - slack, self.hi + slack)
        else:
            rb = raw
        z, zb = (raw - self.mu) / self.sd, (rb - self.mu) / self.sd
        T = self._terms(zb)
        cu, cv = T @ self.bu, T @ self.bv
        if bounded:
            for axis in range(len(self.cols)):
                step = z[:, axis] - zb[:, axis]
                G = self._grad(zb, axis)
                cu, cv = cu + step * (G @ self.bu), cv + step * (G @ self.bv)
        return frame["headU"].values + cu, frame["headV"].values + cv

    def predict(self, frame: pd.DataFrame, bounded=True):
        cu, cv = self.correct(frame, bounded)
        hx = frame["eyeX"].values + frame["distance"].values * cu
        hy = frame["eyeY"].values + frame["distance"].values * cv
        return geo.normalised(hx, hy)

    @property
    def diagonal_gain(self):
        """Mean slope of corrected against measured along each fitted axis, raw units."""
        z = np.zeros((1, len(self.cols)))
        return tuple((self._grad(z, a) @ b)[0] / self.sd[a] for a, b in ((0, self.bu), (1, self.bv)) if a < len(self.cols))


def fit(frame: pd.DataFrame, cols=("eU", "eV"), order=1, ridge=0.0) -> Model:
    x = frame[list(cols)].values
    mu, sd = x.mean(0), x.std(0)
    sd = np.where(sd > 1e-9, sd, 1.0)
    m = Model(tuple(cols), order, mu, sd, x.min(0), x.max(0), None, None, ridge)
    T = m._terms((x - mu) / sd)
    yu, yv = frame["teU"].values, frame["teV"].values

    def solve(y):
        A = T.T @ T
        if ridge > 0:
            w = A.shape[0]
            A = A + np.diag([0] + [ridge * np.trace(A) / w] * (w - 1))
        return np.linalg.solve(A, T.T @ y)

    m.bu, m.bv = solve(yu), solve(yv)
    return m


def grid_cv(frame: pd.DataFrame, **kwargs) -> tuple[float, float]:
    """Leave-one-target-out accuracy: mean and worst centroid error in points."""
    errs = []
    for g in sorted(frame["ti"].unique()):
        tr, ho = frame[frame["ti"] != g], frame[frame["ti"] == g]
        px, py = fit(tr, **kwargs).predict(ho, bounded=False)
        errs.append(geo.points_error(px.mean(), py.mean(), ho["tx"].iloc[0], ho["ty"].iloc[0]))
    return float(np.mean(errs)), float(np.max(errs))


def gaze_before_tap(gaze: pd.DataFrame, taps: pd.DataFrame, px, py, lead=(0.6, 0.1)) -> tuple[float, int]:
    """Median distance in points between each tap and the gaze in the window before it.

    A person looks at what they are about to tap, so this is ground truth for free viewing
    that the calibration grid never sees.
    """
    px, py = np.asarray(px, dtype=float), np.asarray(py, dtype=float)
    finite = np.isfinite(px) & np.isfinite(py)
    errs = []
    for _, t in taps.iterrows():
        # Rows the app recorded without a coordinate (no fresh reading from the source in
        # force) are skipped rather than allowed to turn the median into NaN.
        w = ((gaze["timestamp"] > t["timestamp"] - lead[0]) & (gaze["timestamp"] <= t["timestamp"] - lead[1])).values & finite
        if w.sum() >= 3:
            errs.append(geo.points_error(np.median(px[w]), np.median(py[w]), t["x"], t["y"]))
    return (float(np.median(errs)) if errs else float("nan")), len(errs)


def gaze_before_tap_to_element(gaze: pd.DataFrame, taps: pd.DataFrame, px, py, lead=(0.6, 0.1)) -> tuple[float, int]:
    """Like `gaze_before_tap`, but the distance is to the tapped element's frame: zero when the
    gaze rests anywhere inside it, otherwise the distance to its nearest edge, in points.

    The fingertip lands wherever is convenient on a wide row while the eyes rest on its
    label, so the point distance overstates gaze error. Uses the ``targetMin/Max`` columns
    the app records on taps; taps without them are skipped.
    """
    px, py = np.asarray(px, dtype=float), np.asarray(py, dtype=float)
    finite = np.isfinite(px) & np.isfinite(py)
    cols = ("targetMinX", "targetMinY", "targetMaxX", "targetMaxY")
    if not all(c in taps for c in cols):
        return float("nan"), 0
    errs = []
    for _, t in taps.dropna(subset=list(cols)).iterrows():
        w = ((gaze["timestamp"] > t["timestamp"] - lead[0]) & (gaze["timestamp"] <= t["timestamp"] - lead[1])).values & finite
        if w.sum() < 3:
            continue
        gx, gy = np.median(px[w]), np.median(py[w])
        dx = max(t["targetMinX"] - gx, 0, gx - t["targetMaxX"]) * geo.POINT_WIDTH
        dy = max(t["targetMinY"] - gy, 0, gy - t["targetMaxY"]) * geo.POINT_HEIGHT
        errs.append(float(np.hypot(dx, dy)))
    return (float(np.median(errs)) if errs else float("nan")), len(errs)


def on_display(px, py) -> float:
    return float(((px >= 0) & (px <= 1) & (py >= 0) & (py <= 1)).mean())
