import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fingerprint import features as ft  # noqa: E402
from fingerprint import figures, stability  # noqa: E402
from test_features import gaze_path  # noqa: E402


def synthetic_fingerprint(seed=0, taps=True):
    rng = np.random.default_rng(seed)
    gaze = gaze_path([(0.5, 0.2, 0.5 + rng.uniform(0, 0.2), "title"), (0.5, 0.85, 0.5, "cta"), (0.5, 0.2, 0.4, "title")])
    rows = [dict(event="session_start", timestamp=99.9), dict(event="screen_appear", screen="product_detail", productID="sku_1", timestamp=99.95),
            dict(event="area_enter", screen="product_detail", productID="sku_1", target="title", timestamp=100.0),
            dict(event="area_enter", screen="product_detail", productID="sku_1", target="cta", timestamp=100.6)]
    if taps:
        rows.append(dict(event="tap", screen="product_detail", productID="sku_1", target="cta", timestamp=101.2, x=0.5, y=0.86, durationMs=120,
                         contactRadiusPt=20, targetMinX=0.0, targetMaxX=1.0, targetMinY=0.8, targetMaxY=0.9))
    rows.append(dict(event="session_end", timestamp=101.5))
    ev = pd.concat([pd.DataFrame(rows), gaze], ignore_index=True)
    return ft.fingerprint({"id": f"S{seed}", "clockAnchor": {"wallClock": 1000 + seed}}, ev)


def test_fingerprint_card_and_stability_figure_render(tmp_path):
    fps = [synthetic_fingerprint(s) for s in range(3)]
    out = figures.fingerprint_card(fps[0], tmp_path / "card.png")
    assert out.exists() and out.stat().st_size > 10_000
    table = stability.table(fps)
    assert list(table.index) == ["S0", "S1", "S2"]
    ok = stability.usable(table)
    assert not ok.any()  # one tap each: below the tap floor, so no session counts as trustworthy
    spread = stability.spread(table)
    assert "fixation.per_min" in set(spread["feature"]) and (spread["cv"] >= 0).all()
    fig = figures.stability_figure(table, spread, tmp_path / "stability.png")
    assert fig.exists()


def test_counts_become_per_minute_rates_in_the_table():
    fp = synthetic_fingerprint(0)
    fp["navigation"]["backs"] = 3
    fp["navigation"]["session_s"] = 30
    table = stability.table([fp])
    assert abs(table.loc["S0", "nav.backs"] - 6.0) < 1e-9  # 3 in half a minute



def test_condition_effects_find_an_injected_pace_effect(tmp_path):
    from fingerprint import conditions
    fps = []
    for i in range(8):
        fp = synthetic_fingerprint(i)
        pace = "hurried" if i % 2 else "relaxed"
        fp["session"]["condition"] = dict(participant="P1", task="browse", pace=pace, posture="sitting", light="daylight")
        fp["session"]["startedAtWallClock"] = 1000 + 86400 * (i // 2)
        fp["navigation"]["taps"] = 5
        fp["fixations"]["share_of_tracked"] = 0.7
        fp["taps"]["median_press_ms"] = 80 if pace == "hurried" else 160 + i
        fps.append(fp)
    table = conditions.table(fps)
    assert list(table["pace"]).count("hurried") == 4 and table["day"].nunique() == 4
    usable = conditions.conditioned(table)
    assert len(usable) == 8
    eff = conditions.effects(usable)
    press = eff[(eff["factor"] == "pace") & (eff["feature"] == "tap.median_press_ms")].iloc[0]
    assert press["level_b"] == "hurried" and press["d"] < -2
    yard = conditions.day_to_day(usable)
    assert "tap.median_press_ms" in set(yard["feature"])
    out = figures.effects_figure(eff, yard, tmp_path / "effects.png")
    assert out.exists()


def test_task_result_is_read_into_the_fingerprint():
    gaze = gaze_path([(0.5, 0.2, 0.5, "title")])
    ev = pd.concat([pd.DataFrame([dict(event="session_start", timestamp=99.9),
                                  dict(event="task_result", timestamp=101.0, productID="sku_103", metrics=None, correct=1, timedOut=0),
                                  dict(event="session_end", timestamp=101.1)]), gaze], ignore_index=True)
    fp = ft.fingerprint({"id": "T", "condition": {"task": "search"}}, ev)
    assert fp["task"] == dict(correct=True, timedOut=False, selected="sku_103")
    assert fp["session"]["condition"]["task"] == "search"
