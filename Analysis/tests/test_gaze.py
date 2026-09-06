import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fingerprint import gaze as gz  # noqa: E402
from fingerprint import geometry as geo  # noqa: E402

TARGETS = [(x, y) for y in (0.15, 0.38, 0.62, 0.85) for x in (0.15, 0.5, 0.85)]


def synthetic(gain=0.2, head=(0.03, -0.05), scale=(0.85, 0.8), offset=(0.09, -0.06), frames=6):
    """A person whose eye-in-head rotation is reported compressed, offset and scaled."""
    rows = []
    for ti, (tx, ty) in enumerate(TARGETS):
        for d in (0.32, 0.46):
            for _ in range(frames):
                eyeX, eyeY = 0.01, -0.04
                TX, TY = geo.target_metres(tx, ty)
                tu, tv = (TX - eyeX) / d, (TY - eyeY) / d
                eu, ev = tu - head[0], tv - head[1]
                rows.append(dict(ti=ti, tx=tx, ty=ty, eyeX=eyeX, eyeY=eyeY, distance=d,
                                 headU=head[0], headV=head[1],
                                 u=head[0] + gain * (scale[0] * eu + offset[0]),
                                 v=head[1] + gain * (scale[1] * ev + offset[1])))
    return gz.with_eye_in_head(pd.DataFrame(rows))


def test_head_plus_eye_recovers_a_compressed_signal_exactly():
    f = synthetic()
    acc, worst = gz.grid_cv(f)
    assert acc < 1e-6 and worst < 1e-6
    m = gz.fit(f)
    gu, gv = m.diagonal_gain
    assert abs(gu - 1 / (0.2 * 0.85)) < 1e-6 and abs(gv - 1 / (0.2 * 0.8)) < 1e-6


def test_head_passes_through_with_unit_gain():
    m = gz.fit(synthetic())
    base = pd.DataFrame(dict(eU=[0.01], eV=[-0.02], headU=[0.03], headV=[-0.05], eyeX=[0], eyeY=[0], distance=[0.35]))
    turned = base.assign(headU=0.13)
    cu0, _ = m.correct(base)
    cu1, _ = m.correct(turned)
    assert abs((cu1[0] - cu0[0]) - 0.1) < 1e-9


def test_gain_table_reports_the_compression():
    f = synthetic(gain=0.25)
    table = gz.gain_table(f, {"eye-in-head": ("eU", "eV")})
    assert np.allclose(table["gain"], 0.25 * np.where(table["axis"] == "horizontal", 0.85, 0.8), atol=1e-6)
    assert (table["r"] > 0.999).all()


def test_prediction_continues_linearly_beyond_the_range():
    m = gz.fit(synthetic(), order=2)
    far = pd.DataFrame(dict(eU=[0.9], eV=[0.0], headU=[0.03], headV=[-0.05], eyeX=[0], eyeY=[0], distance=[0.35]))
    edge_val = m.hi[0] + (m.hi[0] - m.lo[0]) * gz.MARGIN
    edge = far.assign(eU=edge_val)
    step = far.assign(eU=edge_val + 1e-4)
    cu_far, _ = m.correct(far)
    cu_edge, _ = m.correct(edge)
    cu_step, _ = m.correct(step)
    slope = (cu_step[0] - cu_edge[0]) / 1e-4
    assert abs(cu_far[0] - (cu_edge[0] + slope * (0.9 - edge_val))) < 1e-6


def test_gaze_before_tap_uses_the_window_before_the_tap():
    gaze = pd.DataFrame(dict(timestamp=np.arange(0, 2, 1 / 60)))
    px = np.full(len(gaze), 0.5)
    py = np.full(len(gaze), 0.5)
    taps = pd.DataFrame(dict(timestamp=[1.0], x=[0.5], y=[0.5 + 100 / geo.POINT_HEIGHT]))
    err, n = gz.gaze_before_tap(gaze, taps, px, py)
    assert n == 1 and abs(err - 100) < 1e-6


def test_gaze_before_tap_ignores_rows_without_a_coordinate():
    gaze = pd.DataFrame(dict(timestamp=np.arange(0, 2, 1 / 60)))
    px = np.full(len(gaze), 0.5)
    py = np.full(len(gaze), 0.5)
    px[30:40] = np.nan  # a stretch inside the window with no recorded gaze
    taps = pd.DataFrame(dict(timestamp=[1.0], x=[0.5], y=[0.5 + 100 / geo.POINT_HEIGHT]))
    err, n = gz.gaze_before_tap(gaze, taps, px, py)
    assert n == 1 and abs(err - 100) < 1e-6
