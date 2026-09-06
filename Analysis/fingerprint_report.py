#!/usr/bin/env python3
"""Figures and the cross-session table for every session on disk.

    python3 Analysis/fingerprint_report.py               # all of Data/
    python3 Analysis/fingerprint_report.py Data/session_<uuid>.jsonl ...

Writes, under Data/derived/: `figures/<id>_fingerprint.png` per session (scan paths, dwell,
transitions, headline), `fingerprints.csv` (one row per session of scalar features, counts
as per-minute rates), and `figures/stability.png` with the within-person spread of every
feature over the sessions whose gaze can be trusted. Prints the spread table.
Definitions: docs/product/12-FINGERPRINT-FEATURES.md.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).parent))
from fingerprint import conditions  # noqa: E402
from fingerprint import features as ft  # noqa: E402
from fingerprint import figures  # noqa: E402
from fingerprint import load  # noqa: E402
from fingerprint import stability  # noqa: E402

pd.set_option("display.width", 160)


def fingerprint_of(path: Path, derived: Path) -> dict:
    session, events = load.load_session(path)
    out = derived / f"fingerprint_{session.get('id', path.stem)}.json"
    if out.exists() and out.stat().st_mtime >= path.stat().st_mtime:
        return json.loads(out.read_text())
    fp = ft.fingerprint(session, events)
    out.write_text(json.dumps(fp, indent=1, default=float))
    return fp


def main(paths: list[str]) -> None:
    data = Path(__file__).resolve().parents[1] / "Data"
    files = [Path(p) for p in paths] if paths else sorted(data.glob("session_*.jsonl"))
    if not files:
        sys.exit("no sessions found")
    derived = files[0].parent / "derived"
    figure_dir = derived / "figures"
    derived.mkdir(exist_ok=True)
    fingerprints = []
    for path in files:
        try:
            fp = fingerprint_of(path, derived)
        except Exception as error:
            print(f"skipped {path.name}: {error}")
            continue
        fingerprints.append(fp)
        out = figures.fingerprint_card(fp, figure_dir / f"{fp['session']['id']}_fingerprint.png")
        print(f"{figures.headline(fp)}\n  -> {out}")
    table = stability.table(fingerprints)
    table.to_csv(derived / "fingerprints.csv")
    ok = stability.usable(table)
    print(f"\n{len(table)} sessions, {int(ok.sum())} with trustworthy gaze (fixation share ≥ {stability.MIN_FIXATION_SHARE}, taps ≥ {stability.MIN_TAPS})")
    if ok.sum() >= 2:
        spread = stability.spread(table[ok])
        print("\nwithin-person spread over the trustworthy sessions (cv = sd / mean; under 0.2 is a candidate for a stable trait):")
        print(spread.round(3).to_string(index=False))
        out = figures.stability_figure(table[ok], spread, figure_dir / "stability.png")
        print(f"  -> {out}")
    cond = conditions.table(fingerprints)
    cond.to_csv(derived / "fingerprints_by_condition.csv")
    usable = conditions.conditioned(cond)
    if len(usable) >= 4:
        print(f"\n{len(usable)} conditioned sessions pass the quality gate; "
              f"participants {sorted(usable['participant'].dropna().unique())}, days {usable['day'].nunique()}")
        eff = conditions.effects(usable)
        yard = conditions.day_to_day(usable)
        if not eff.empty:
            print("\nfactor effects (d = second level minus first, in within-level sd), largest first:")
            print(eff.head(24).round(2).to_string(index=False))
            out = figures.effects_figure(eff, yard, figure_dir / "effects.png")
            print(f"  -> {out}")
        outcomes = conditions.task_outcomes(usable)
        if not outcomes.empty:
            print("\nsearch task outcomes:")
            print(outcomes.round(2).to_string(index=False))
    print(f"  -> {derived / 'fingerprints.csv'}")


if __name__ == "__main__":
    main(sys.argv[1:])
