"""Readers for the app's exports."""
from __future__ import annotations

import json
from pathlib import Path

import pandas as pd

EYE_LOOK_KEYS = {
    "in_l": "eyeLookIn_L", "out_l": "eyeLookOut_L", "in_r": "eyeLookIn_R", "out_r": "eyeLookOut_R",
    "up_l": "eyeLookUp_L", "down_l": "eyeLookDown_L", "up_r": "eyeLookUp_R", "down_r": "eyeLookDown_R",
}


def load_session(path: str | Path) -> tuple[dict, pd.DataFrame]:
    """The session record and one row per event, metrics and signals flattened.

    Gaze rows carry the raw measurement (``eyeX/Y/Z``, ``convergenceU/V``, ``perEyeU/V``,
    ``headForwardU/V``, ``pupilU/V`` when present) alongside the screen coordinate the app
    computed at the time, so any later model can be replayed against them.
    """
    path = Path(path)
    if path.suffix == ".jsonl":
        events = pd.read_json(path, lines=True)
        doc_path = path.with_suffix(".json")
        session = json.load(open(doc_path))["session"] if doc_path.exists() else {}
    else:
        doc = json.load(open(path))
        session = doc["session"]
        events = pd.DataFrame(doc["events"])
    metrics = pd.json_normalize(events["metrics"]) if "metrics" in events else pd.DataFrame(index=events.index)
    signals = pd.json_normalize(events["signals"]) if "signals" in events else pd.DataFrame(index=events.index)
    frame = pd.concat([events.drop(columns=[c for c in ("metrics", "signals") if c in events]), metrics, signals], axis=1)
    frame["t"] = frame["timestamp"] - frame["timestamp"].min()
    return session, frame.sort_values("sequence").reset_index(drop=True)


def gaze_rows(events: pd.DataFrame, quality: str | None = "good") -> pd.DataFrame:
    """Gaze events, optionally only those the app judged trustworthy."""
    gaze = events[events["event"] == "gaze"]
    if quality is not None:
        gaze = gaze[gaze["quality"] == quality]
    gaze = gaze.copy()
    if "eyeZ" in gaze:
        gaze["distance"] = -gaze["eyeZ"]
    k = EYE_LOOK_KEYS
    if all(v in gaze for v in k.values()):
        gaze["lookU"] = ((gaze[k["in_l"]] - gaze[k["out_l"]]) + (gaze[k["out_r"]] - gaze[k["in_r"]])) / 2
        gaze["lookV"] = ((gaze[k["up_l"]] - gaze[k["down_l"]]) + (gaze[k["up_r"]] - gaze[k["down_r"]])) / 2
    return gaze.reset_index(drop=True)


def taps(events: pd.DataFrame) -> pd.DataFrame:
    return events[events["event"] == "tap"].reset_index(drop=True)


def load_calibration(path: str | Path) -> tuple[dict, dict[str, pd.DataFrame]]:
    """The chosen model and one DataFrame of frames per gaze source.

    Each frame carries its target (normalised), target index, and the full
    ``GazeMeasurement``: ``u, v, eyeX, eyeY, distance, headYaw, headPitch, lookU, lookV,
    headU, headV``.
    """
    doc = json.load(open(path))
    frames: dict[str, pd.DataFrame] = {}
    for source in ("convergence", "perEye", "pupil", "learned"):
        rows = [
            dict(ti=p["targetIndex"], tx=p["target"][0], ty=p["target"][1], **p[source])
            for p in doc["points"]
            if p.get(source)
        ]
        if rows:
            frames[source] = pd.DataFrame(rows)
    return doc.get("model"), frames
