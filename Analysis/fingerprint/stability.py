"""Across sessions of one person: which features hold still and which move.

A fingerprint is only a fingerprint if some of it is stable for a person across sessions
while differing between people. With one person recorded so far, only the first half can
be asked. This module gives the within-person spread of every scalar feature and a quality
filter for the sessions that go into it. Definitions: `docs/product/12-FINGERPRINT-FEATURES.md`.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

# A session whose gaze rarely settles into fixations was recorded with a calibration that
# put the gaze off the screen; its gaze features describe the calibration, not the person.
MIN_FIXATION_SHARE = 0.40
MIN_TAPS = 3

# Features compared across sessions. Rates and shares only: totals scale with session length.
FEATURES = [
    "fixation.per_min", "fixation.median_duration_s", "fixation.share_of_tracked", "fixation.saccade_median_amplitude_pt",
    "tap.median_press_ms", "tap.median_contact_radius_pt", "tap.looked_at_share", "tap.median_looked_first_s",
    "nav.time_to_first_selection_s", "nav.list_switches", "nav.backs",
    "scroll.bursts", "scroll.reversals", "scroll.travel_pt",
    "face.blink_per_min", "face.distance_cm", "face.head_yaw_sd_deg", "face.head_pitch_sd_deg", "face.phone_tilt_deg",
    "face.eyeSquint_L_median", "face.browInnerUp_median",
    "dwell.revisits_fixation",
]
PER_MINUTE = {"nav.list_switches", "nav.backs", "scroll.bursts", "scroll.reversals", "scroll.travel_pt", "dwell.revisits_fixation"}


def table(fingerprints: list[dict]) -> pd.DataFrame:
    """One row per session of flattened scalars, indexed by session id, oldest first, with
    length-dependent counts turned into per-minute rates."""
    from . import features as ft
    rows = {}
    for fp in fingerprints:
        flat = ft.flatten(fp)
        flat["startedAt"] = fp["session"].get("startedAtWallClock")
        minutes = (fp["navigation"].get("session_s") or 0) / 60
        for key in PER_MINUTE:
            if key in flat and minutes > 0:
                flat[key] = flat[key] / minutes
        rows[fp["session"]["id"]] = flat
    frame = pd.DataFrame(rows).T
    frame = frame.sort_values("startedAt") if "startedAt" in frame else frame
    return frame.apply(pd.to_numeric, errors="ignore")


def usable(frame: pd.DataFrame) -> pd.Series:
    """Sessions whose gaze features can be trusted, see `MIN_FIXATION_SHARE`."""
    share = frame.get("fixation.share_of_tracked", pd.Series(0, index=frame.index)).fillna(0)
    taps = frame.get("nav.taps", pd.Series(0, index=frame.index)).fillna(0)
    return (share >= MIN_FIXATION_SHARE) & (taps >= MIN_TAPS)


def spread(frame: pd.DataFrame, features: list[str] = FEATURES) -> pd.DataFrame:
    """Per feature: sessions with a value, median, standard deviation, coefficient of
    variation (sd / |mean|) and the min–max range. Sorted by cv, the most stable first."""
    rows = []
    for key in features:
        if key not in frame:
            continue
        values = pd.to_numeric(frame[key], errors="coerce").dropna()
        if len(values) < 2:
            continue
        mean = values.mean()
        rows.append(dict(feature=key, n=len(values), median=values.median(), sd=values.std(ddof=1),
                         cv=(values.std(ddof=1) / abs(mean)) if mean else (0.0 if values.std(ddof=1) == 0 else np.nan),
                         low=values.min(), high=values.max()))
    return pd.DataFrame(rows).sort_values("cv").reset_index(drop=True)
