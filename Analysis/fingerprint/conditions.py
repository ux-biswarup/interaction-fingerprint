"""Features by study condition: what moves when the situation is changed on purpose.

Phase 4 records each session under a condition (participant, task, pace, posture, light;
`SessionCondition` in the app, `04-EXPERIMENT-PLAN.md`). For every factor and feature this
module reports the difference between levels in units of the spread within levels, and
the day-to-day spread of each feature under a fixed condition, which is the yardstick a
condition effect has to clear. Observations only; no feature is a state of mind.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

from . import stability

FACTORS = ["task", "pace", "posture", "light"]
CONDITION_COLUMNS = ["participant", "task", "pace", "posture", "light"]


def table(fingerprints: list[dict]) -> pd.DataFrame:
    """The stability table plus the condition columns, the day, and the task outcome."""
    base = stability.table(fingerprints)
    extra = {}
    for fp in fingerprints:
        sid = fp["session"]["id"]
        cond = fp["session"].get("condition") or {}
        row = {c: cond.get(c) for c in CONDITION_COLUMNS}
        started = fp["session"].get("startedAtWallClock")
        row["day"] = int(started // 86400) if started else None
        task = fp.get("task") or {}
        row["task.correct"] = task.get("correct")
        row["task.timed_out"] = task.get("timedOut")
        extra[sid] = row
    return base.join(pd.DataFrame(extra).T)


def conditioned(frame: pd.DataFrame) -> pd.DataFrame:
    """Only sessions that carry a condition and pass the quality gate."""
    if "task" not in frame:
        return frame.iloc[0:0]
    return frame[frame["task"].notna() & stability.usable(frame)]


def effects(frame: pd.DataFrame, features: list[str] = stability.FEATURES) -> pd.DataFrame:
    """Per factor and feature: mean at each level and the standardised difference.

    ``d`` is (mean of the second level − mean of the first) over the pooled within-level
    standard deviation, the two levels being the first two in the factor's natural order
    (browse→search, relaxed→hurried, sitting→lying back, daylight→lamp). Positive means the
    feature is larger under the second. Sessions of all participants are pooled; with more
    than one participant the participant column should be used to split first.
    """
    order = {"task": ["browse", "search"], "pace": ["relaxed", "hurried"],
             "posture": ["sitting", "lying_back", "standing"], "light": ["daylight", "lamp"]}
    rows = []
    for factor in FACTORS:
        if factor not in frame:
            continue
        levels = [lv for lv in order[factor] if lv in set(frame[factor].dropna())]
        if len(levels) < 2:
            continue
        a, b = levels[0], levels[1]
        for key in features:
            if key not in frame:
                continue
            va = pd.to_numeric(frame.loc[frame[factor] == a, key], errors="coerce").dropna()
            vb = pd.to_numeric(frame.loc[frame[factor] == b, key], errors="coerce").dropna()
            if len(va) < 2 or len(vb) < 2:
                continue
            pooled = np.sqrt(((len(va) - 1) * va.var(ddof=1) + (len(vb) - 1) * vb.var(ddof=1)) / (len(va) + len(vb) - 2))
            rows.append(dict(factor=factor, feature=key, level_a=a, level_b=b, n_a=len(va), n_b=len(vb),
                             mean_a=va.mean(), mean_b=vb.mean(), d=(vb.mean() - va.mean()) / pooled if pooled > 0 else np.nan))
    out = pd.DataFrame(rows)
    return out.reindex(out["d"].abs().sort_values(ascending=False).index).reset_index(drop=True) if not out.empty else out


def day_to_day(frame: pd.DataFrame, features: list[str] = stability.FEATURES) -> pd.DataFrame:
    """The yardstick: for each feature, the coefficient of variation across days within one
    participant and one (task, pace) condition, averaged over the conditions that have at
    least two days. A condition effect smaller than this is not distinguishable from a day."""
    if not {"participant", "task", "pace", "day"} <= set(frame.columns):
        return pd.DataFrame(columns=["feature", "day_cv", "conditions"])
    rows = []
    for key in features:
        if key not in frame:
            continue
        cvs = []
        for _, group in frame.groupby(["participant", "task", "pace"], dropna=True):
            per_day = pd.to_numeric(group.groupby("day")[key].mean(), errors="coerce").dropna()
            if len(per_day) >= 2 and per_day.mean():
                cvs.append(per_day.std(ddof=1) / abs(per_day.mean()))
        if cvs:
            rows.append(dict(feature=key, day_cv=float(np.mean(cvs)), conditions=len(cvs)))
    return pd.DataFrame(rows)


def task_outcomes(frame: pd.DataFrame) -> pd.DataFrame:
    """Search-task success and time by pace and participant."""
    if "task" not in frame:
        return pd.DataFrame()
    search = frame[frame["task"] == "search"]
    if search.empty:
        return pd.DataFrame()
    return search.groupby(["participant", "pace"], dropna=True).agg(
        sessions=("task.correct", "size"),
        correct_share=("task.correct", lambda s: pd.to_numeric(s, errors="coerce").mean()),
        timed_out_share=("task.timed_out", lambda s: pd.to_numeric(s, errors="coerce").mean()),
        time_to_selection_s=("nav.time_to_first_selection_s", "median"),
    ).reset_index()
