import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fingerprint import features as ft  # noqa: E402
from fingerprint import geometry as geo  # noqa: E402

RATE = 60.0


def gaze_path(segments, screen="product_detail", product="sku_1", start=100.0):
    """Gaze rows from (x, y, seconds, target) segments at 60 Hz with a little jitter."""
    rng = np.random.default_rng(0)
    rows, t = [], start
    for x, y, seconds, target in segments:
        for _ in range(int(round(seconds * RATE))):
            rows.append(dict(event="gaze", timestamp=t, quality="good", eyesOpen=True, screen=screen, productID=product,
                             target=target, x=x + rng.normal(0, 4 / geo.POINT_WIDTH), y=y + rng.normal(0, 4 / geo.POINT_HEIGHT),
                             eyeZ=-0.31))
            t += 1 / RATE
    return pd.DataFrame(rows)


def test_fixations_find_two_stable_looks_and_ignore_the_jump_between():
    gaze = gaze_path([(0.3, 0.3, 0.5, "title"), (0.7, 0.8, 0.4, "cta")])
    fix = ft.fixations(gaze)
    assert len(fix) == 2
    assert abs(fix.iloc[0].x - 0.3) < 0.02 and abs(fix.iloc[0].y - 0.3) < 0.02
    assert abs(fix.iloc[0].duration_s - 0.5) < 0.05 and abs(fix.iloc[1].duration_s - 0.4) < 0.05
    assert list(fix["target"]) == ["title", "cta"]
    sac = ft.saccades(fix)
    assert len(sac) == 1 and abs(sac.iloc[0].amplitude_pt - geo.points_error(0.3, 0.3, 0.7, 0.8)) < 40


def test_a_gap_longer_than_max_gap_splits_a_fixation():
    a = gaze_path([(0.5, 0.5, 0.4, "title")])
    b = gaze_path([(0.5, 0.5, 0.4, "title")], start=a["timestamp"].iloc[-1] + 0.3)  # a blink
    fix = ft.fixations(pd.concat([a, b], ignore_index=True))
    assert len(fix) == 2


def test_a_sweep_across_the_screen_is_not_a_fixation():
    # 0.8 of the width in a quarter second: every 120 ms window spans about 150 pt.
    n = 15
    gaze = pd.DataFrame(dict(event="gaze", timestamp=100 + np.arange(n) / RATE, quality="good", eyesOpen=True,
                             screen="s", productID="p", target=None, x=np.linspace(0.1, 0.9, n), y=0.5, eyeZ=-0.3))
    assert ft.fixations(gaze).empty


def test_screen_visits_pair_appear_with_disappear_and_close_the_last_one():
    ev = pd.DataFrame([
        dict(event="screen_appear", screen="product_list", productID=None, timestamp=0.0),
        dict(event="screen_disappear", screen="product_list", productID=None, timestamp=5.0, durationMs=5000),
        dict(event="screen_appear", screen="product_detail", productID="sku_1", timestamp=5.0),
        dict(event="gaze", screen="product_detail", productID="sku_1", timestamp=9.0),
    ])
    visits = ft.screen_visits(ev)
    assert list(visits["screen"]) == ["product_list", "product_detail"]
    assert abs(visits.iloc[0].duration_s - 5) < 1e-9 and abs(visits.iloc[1].duration_s - 4) < 1e-9


def test_area_dwell_sums_exits_and_shares_against_tracked_time():
    gaze = gaze_path([(0.5, 0.2, 2.0, "title"), (0.5, 0.8, 2.0, "cta")])
    ev = pd.concat([gaze, pd.DataFrame([
        dict(event="area_exit", screen="product_detail", productID="sku_1", target="title", durationMs=1000, timestamp=101),
        dict(event="area_exit", screen="product_detail", productID="sku_1", target="title", durationMs=1000, timestamp=103),
        dict(event="area_exit", screen="product_detail", productID="sku_1", target="cta", durationMs=2000, timestamp=104),
    ])], ignore_index=True)
    dwell = ft.area_dwell(ev, gaze).set_index("target")
    assert abs(dwell.loc["title", "dwell_s"] - 2.0) < 1e-9 and dwell.loc["title", "visits"] == 2 and dwell.loc["title", "revisits"] == 1
    assert abs(dwell.loc["cta", "share"] - 0.5) < 0.02  # 2 s of 4 s tracked


def test_fixation_areas_count_runs_not_flicker():
    gaze = gaze_path([(0.5, 0.2, 0.3, "title"), (0.5, 0.25, 0.3, "title"), (0.5, 0.8, 0.3, "cta"), (0.5, 0.2, 0.3, "title")])
    fix = ft.fixations(gaze, ft.Params(dispersion_pt=30))
    areas = ft.fixation_areas(fix).set_index("target")
    assert areas.loc["title", "visits"] == 2 and areas.loc["title", "revisits"] == 1
    assert areas.loc["cta", "visits"] == 1


def test_transitions_exclude_self_and_count_list_switches():
    ev = pd.DataFrame([
        dict(event="area_enter", screen="product_list", productID="sku_1", target="list_item", timestamp=0),
        dict(event="area_enter", screen="product_list", productID="sku_2", target="list_item", timestamp=1),
        dict(event="area_enter", screen="product_list", productID="sku_1", target="list_item", timestamp=2),
        dict(event="area_enter", screen="product_detail", productID="sku_1", target="title", timestamp=3),
        dict(event="area_enter", screen="product_detail", productID="sku_1", target="price", timestamp=4),
        dict(event="area_enter", screen="product_detail", productID="sku_1", target="price", timestamp=5),
        dict(event="area_enter", screen="product_detail", productID="sku_1", target="cta", timestamp=6),
    ])
    matrix, switches = ft.transitions(ev)
    assert switches == 2
    assert matrix.loc["title", "price"] == 1 and matrix.loc["price", "cta"] == 1
    assert matrix.to_numpy().sum() == 2  # the list-to-list repeats and the price-to-price one are not transitions


def test_tap_features_measure_first_look_hesitation_and_element_distance():
    # Look at the CTA from t=100.0 for 0.5 s, look away for 1 s, tap the CTA at 101.5 while looking at the title.
    gaze = gaze_path([(0.5, 0.85, 0.5, "cta"), (0.5, 0.2, 1.0, "title")])
    tap_t = gaze["timestamp"].iloc[-1] + 0.01
    ev = pd.concat([gaze, pd.DataFrame([
        dict(event="screen_appear", screen="product_detail", productID="sku_1", timestamp=99.0),
        dict(event="tap", screen="product_detail", productID="sku_1", target="cta", timestamp=tap_t, x=0.6, y=0.86,
             durationMs=120, contactRadiusPt=20, targetMinX=0.0, targetMaxX=1.0, targetMinY=0.8, targetMaxY=0.9),
    ])], ignore_index=True)
    fix = ft.fixations(gaze)
    taps = ft.tap_features(ev, gaze, fix)
    t = taps.iloc[0]
    assert abs(t.looked_first_s - 1.5) < 0.1
    assert abs(t.hesitation_s - 1.0) < 0.1
    # The eyes were on the title in the pre-tap window, 0.6 of the height above the CTA frame's top.
    assert abs(t.element_distance_pt - 0.6 * geo.POINT_HEIGHT) < 30
    assert t.press_ms == 120 and t.contact_radius_pt == 20


def test_scroll_features_count_bursts_travel_and_reversals():
    ev = pd.DataFrame([
        dict(event="scroll", screen="product_list", productID=None, timestamp=t, offset=o, reversals=r, velocity=v)
        for t, o, r, v in [(0.0, 0, 0, 0), (0.05, 50, 0, 1000), (0.1, 100, 0, 1000), (2.0, 80, 1, -400), (2.05, 60, 1, -400)]
    ])
    s = ft.scroll_features(ev).iloc[0]
    assert s.bursts == 2 and s.travel_pt == 140 and s.reversals == 1 and s.peak_speed_pt_s == 1000


def test_fingerprint_is_serialisable_and_flattens():
    import json
    gaze = gaze_path([(0.5, 0.2, 0.5, "title"), (0.5, 0.85, 0.5, "cta")])
    ev = pd.concat([pd.DataFrame([dict(event="session_start", timestamp=99.9), dict(event="screen_appear", screen="product_detail", productID="sku_1", timestamp=99.95)]),
                    gaze, pd.DataFrame([dict(event="session_end", timestamp=101.1)])], ignore_index=True)
    fp = ft.fingerprint({"id": "TEST"}, ev)
    json.dumps(fp, default=float)
    row = ft.flatten(fp)
    assert row["fixation.count"] == 2 and row["nav.taps"] == 0
    assert fp["params"]["dispersion_pt"] == 80.0


def test_gaze_without_a_screen_is_attributed_from_the_visit_it_fell_in():
    visits = pd.DataFrame(dict(screen=["product_list", "product_detail"], productID=[None, "sku_1"], start=[0.0, 5.0], end=[5.0, 9.0]))
    gaze = pd.DataFrame(dict(timestamp=[1.0, 6.0, 7.0, 20.0], screen=[None, "product_detail", None, None], productID=[None, "sku_1", None, None]))
    out = ft.attribute_screens(gaze, visits)
    assert list(out["screen"]) == ["product_list", "product_detail", "product_detail", None]
    assert list(out["productID"]) == [None, "sku_1", "sku_1", None]
