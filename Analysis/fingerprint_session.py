#!/usr/bin/env python3
"""Compute the Interaction Fingerprint of one or more recorded sessions.

    python3 Analysis/fingerprint_session.py Data/session_<uuid>.jsonl [more sessions]

For each session: prints the fingerprint in readable form and writes
``Data/derived/fingerprint_<uuid>.json`` next to the recordings (never committed). With two
or more sessions, ends with a side-by-side table of the scalar features. Feature
definitions and units: `docs/product/12-FINGERPRINT-FEATURES.md`.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).parent))
from fingerprint import features as ft  # noqa: E402
from fingerprint import load  # noqa: E402

pd.set_option("display.width", 160)


def describe(fp: dict) -> None:
    s, f, t, n = fp["session"], fp["fixations"], fp["taps"], fp["navigation"]
    print(f"\n=== session {str(s['id'])[:8]}  {n['session_s']:.0f} s, {fp['tracked_s']:.0f} s of good gaze")
    print(f"  fixations   {f['count']} ({f['per_min']:.0f}/min), median {f['median_duration_s']*1000:.0f} ms, "
          f"{f['share_of_tracked']*100:.0f}% of tracked time, saccade median {f['saccade_median_amplitude_pt']:.0f} pt")
    print(f"  taps        {t['count']}, press {t['median_press_ms']:.0f} ms, contact {t['median_contact_radius_pt']:.1f} pt, "
          f"looked at the element first on {t['looked_at_share']*100:.0f}%, first look {t['median_looked_first_s']:.2f} s before, "
          f"hesitation {t['median_hesitation_s']:.2f} s")
    print(f"  navigation  {n['products_viewed']} products viewed ({n['product_views']} views), {n['selections']} selected, "
          f"{n['products_viewed_before_first_selection']} viewed before the first, {n['backs']} backs, {n['list_switches']} list switches, "
          f"first selection at {n['time_to_first_selection_s']:.1f} s")
    scroll = pd.DataFrame(fp["scroll"])
    if not scroll.empty:
        print(f"  scrolling   {int(scroll['bursts'].sum())} bursts, {scroll['travel_pt'].sum():.0f} pt travelled, "
              f"{int(scroll['reversals'].sum())} reversals, peak {scroll['peak_speed_pt_s'].max():.0f} pt/s")
    face = fp["face"]["all"]
    print(f"  face        blink {face['blink_per_min']:.1f}/min, distance {face['distance_cm']:.0f} cm, head yaw sd {face['head_yaw_sd_deg']:.1f}°, "
          f"phone tilt {face['phone_tilt_deg']:.0f}°, disturbance {face['phone_disturbance_mm']:.1f} mm, on display {face['on_display_share']*100:.0f}%")
    shapes = {k[:-7]: v for k, v in face.items() if k.endswith("_median")}
    print("  blend shapes (median) " + "  ".join(f"{k} {v:.2f}" for k, v in shapes.items()))
    areas = pd.DataFrame(fp["areas"])
    if not areas.empty:
        print("  dwell by area (top 8):")
        cols = ["screen", "productID", "target", "dwell_s", "visits", "revisits", "share"]
        print("    " + areas[cols].head(8).round(2).to_string(index=False).replace("\n", "\n    "))
    fixed = pd.DataFrame(fp["fixation_areas"])
    if not fixed.empty:
        print("  dwell by area from fixations (top 8):")
        print("    " + fixed.head(8).round(2).to_string(index=False).replace("\n", "\n    "))
    if fp["transitions"]:
        print("  transitions between areas:")
        print("    " + pd.DataFrame(fp["transitions"]).fillna(0).astype(int).T.to_string().replace("\n", "\n    "))
    taps = pd.DataFrame(fp["tap_list"])
    if not taps.empty:
        cols = ["screen", "target", "press_ms", "contact_radius_pt", "element_distance_pt", "looked_first_s", "hesitation_s"]
        print("  taps:")
        print("    " + taps[cols].round(2).to_string(index=False).replace("\n", "\n    "))


def main(paths: list[str]) -> None:
    if not paths:
        sys.exit(__doc__)
    rows = {}
    for p in paths:
        session, events = load.load_session(p)
        fp = ft.fingerprint(session, events)
        describe(fp)
        out_dir = Path(p).parent / "derived"
        out_dir.mkdir(exist_ok=True)
        out = out_dir / f"fingerprint_{session.get('id', Path(p).stem)}.json"
        out.write_text(json.dumps(fp, indent=1, default=float))
        print(f"  written {out}")
        rows[str(session.get("id"))[:8]] = ft.flatten(fp)
    if len(rows) > 1:
        print("\n=== side by side")
        table = pd.DataFrame(rows)
        print(table.round(2).to_string())


if __name__ == "__main__":
    main(sys.argv[1:])
