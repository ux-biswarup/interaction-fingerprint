"""The Interaction Fingerprint: features derived from one session's event stream.

Every feature here is defined, with units, in `docs/product/12-FINGERPRINT-FEATURES.md`;
that document is written first and this file follows it. The features describe observable
behaviour only. Nothing in this module names an emotion or an intent, and nothing should.

Inputs are the flattened event frame from `load.load_session`. Time is in seconds on the
device clock, distances on the screen in points, rates per minute of tracked time.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass

import numpy as np
import pandas as pd

from . import geometry as geo

EXPRESSION = [
    "eyeBlink_L", "eyeBlink_R", "eyeSquint_L", "eyeSquint_R", "eyeWide_L", "eyeWide_R",
    "browInnerUp", "browOuterUp_L", "browOuterUp_R",
]


@dataclass(frozen=True)
class Params:
    """Thresholds, stored alongside every result so a fingerprint is reproducible."""
    dispersion_pt: float = 80.0        # I-DT dispersion: (max x - min x) + (max y - min y)
    min_fixation_s: float = 0.12       # a window must span at least this long to be a fixation
    max_gap_s: float = 0.10            # a longer gap between samples (blink, loss) ends any window
    scroll_burst_gap_s: float = 0.30   # scroll rows further apart than this belong to different bursts
    pre_tap_window_s: tuple[float, float] = (0.6, 0.1)  # gaze-before-tap window: from 0.6 s to 0.1 s before


def _pid(value) -> str | None:
    return None if value is None or (isinstance(value, float) and np.isnan(value)) else str(value)


def _mode(series: pd.Series):
    s = series.dropna()
    return None if s.empty else s.mode().iloc[0]


# ---------------------------------------------------------------- fixations and saccades

def fixations(gaze: pd.DataFrame, params: Params = Params()) -> pd.DataFrame:
    """Dispersion-threshold (I-DT) fixation detection over good gaze rows.

    A window that spans at least ``min_fixation_s`` with dispersion at or under
    ``dispersion_pt`` is a fixation, extended while both hold. Any gap between consecutive
    samples longer than ``max_gap_s`` ends a window, so blinks and tracking loss split
    fixations rather than being bridged. Centroids are normalised screen coordinates; the
    screen, product and area of interest are the most common ones among the samples.
    """
    g = gaze[np.isfinite(gaze["x"].astype(float)) & np.isfinite(gaze["y"].astype(float))].sort_values("timestamp")
    t = g["timestamp"].to_numpy(float)
    x = g["x"].to_numpy(float) * geo.POINT_WIDTH
    y = g["y"].to_numpy(float) * geo.POINT_HEIGHT
    n = len(t)

    def dispersion(i, j):
        return (x[i:j + 1].max() - x[i:j + 1].min()) + (y[i:j + 1].max() - y[i:j + 1].min())

    rows = []
    i = 0
    while i < n:
        j = i
        while j < n - 1 and t[j] - t[i] < params.min_fixation_s and t[j + 1] - t[j] <= params.max_gap_s:
            j += 1
        if t[j] - t[i] < params.min_fixation_s:
            i += 1
            continue
        if dispersion(i, j) > params.dispersion_pt:
            i += 1
            continue
        while j < n - 1 and t[j + 1] - t[j] <= params.max_gap_s and dispersion(i, j + 1) <= params.dispersion_pt:
            j += 1
        block = g.iloc[i:j + 1]
        rows.append(dict(
            start=t[i], end=t[j], duration_s=t[j] - t[i], samples=j - i + 1,
            x=float(x[i:j + 1].mean() / geo.POINT_WIDTH), y=float(y[i:j + 1].mean() / geo.POINT_HEIGHT),
            dispersion_pt=float(dispersion(i, j)),
            screen=_mode(block["screen"]) if "screen" in block else None,
            productID=_pid(_mode(block["productID"])) if "productID" in block else None,
            target=_mode(block["target"]) if "target" in block else None,
        ))
        i = j + 1
    columns = ["start", "end", "duration_s", "samples", "x", "y", "dispersion_pt", "screen", "productID", "target"]
    return pd.DataFrame(rows, columns=columns)


def saccades(fix: pd.DataFrame) -> pd.DataFrame:
    """Jumps between consecutive fixations on the same screen: amplitude in points and the
    time between the end of one fixation and the start of the next."""
    rows = []
    for a, b in zip(fix.itertuples(), fix.iloc[1:].itertuples()):
        if a.screen != b.screen or a.productID != b.productID:
            continue
        rows.append(dict(
            start=a.end, end=b.start, gap_s=b.start - a.end,
            amplitude_pt=float(geo.points_error(a.x, a.y, b.x, b.y)),
            screen=a.screen, productID=a.productID,
        ))
    return pd.DataFrame(rows, columns=["start", "end", "gap_s", "amplitude_pt", "screen", "productID"])


# ---------------------------------------------------------------- screens and areas

def screen_visits(events: pd.DataFrame) -> pd.DataFrame:
    """One row per stay on a screen, from the appear and disappear events. A screen still
    showing at the end of the session is closed at the last event."""
    rows, open_ = [], {}
    for e in events[events["event"].isin(["screen_appear", "screen_disappear"])].itertuples():
        key = (e.screen, _pid(e.productID))
        if e.event == "screen_appear":
            open_[key] = e.timestamp
        else:
            start = open_.pop(key, None)
            rows.append(dict(screen=key[0], productID=key[1], start=start, end=e.timestamp))
    end = events["timestamp"].max()
    rows += [dict(screen=k[0], productID=k[1], start=s, end=end) for k, s in open_.items()]
    visits = pd.DataFrame(rows, columns=["screen", "productID", "start", "end"])
    visits["duration_s"] = visits["end"] - visits["start"]
    return visits.sort_values("start").reset_index(drop=True)


def attribute_screens(gaze: pd.DataFrame, visits: pd.DataFrame) -> pd.DataFrame:
    """Fill the screen and product of gaze rows that carry none from the screen visits.

    Recordings up to 6 September 2026 stamped a gaze row's screen from the area under the
    gaze, so a row that fell on no area lost its screen as well, a third of good rows. The
    visit that contains the row's time is the screen it was on. Rows with a screen keep it.
    """
    g = gaze.copy()
    if "screen" not in g:
        g["screen"] = None
    if "productID" not in g:
        g["productID"] = None
    missing = g["screen"].isna()
    if not missing.any() or visits.empty:
        return g
    t = g.loc[missing, "timestamp"].to_numpy(float)
    starts = visits["start"].to_numpy(float)
    idx = np.searchsorted(starts, t, side="right") - 1
    ok = (idx >= 0) & (t <= visits["end"].to_numpy(float)[np.clip(idx, 0, None)])
    screens = np.where(ok, visits["screen"].to_numpy(object)[np.clip(idx, 0, None)], None)
    products = np.where(ok, visits["productID"].to_numpy(object)[np.clip(idx, 0, None)], None)
    g.loc[missing, "screen"] = screens
    g.loc[missing, "productID"] = products
    return g


def tracked_time(gaze: pd.DataFrame, params: Params = Params()) -> float:
    """Seconds of good gaze, summing gaps between consecutive rows up to ``max_gap_s``."""
    t = np.sort(gaze["timestamp"].to_numpy(float))
    if len(t) < 2:
        return 0.0
    return float(np.minimum(np.diff(t), params.max_gap_s).sum())


def area_dwell(events: pd.DataFrame, gaze: pd.DataFrame, params: Params = Params()) -> pd.DataFrame:
    """Dwell per area of interest from the app's enter and exit events.

    Per (screen, product, target): total dwell in seconds, number of visits, revisits
    (visits after the first), mean dwell per visit, and the share of that screen's tracked
    gaze time spent on the area (attention distribution). Dwells are the app's own
    attribution of each gaze sample to the area under it, so they are unaffected by the
    fixation thresholds above.
    """
    exits = events[events["event"] == "area_exit"].copy()
    if exits.empty:
        return pd.DataFrame(columns=["screen", "productID", "target", "dwell_s", "visits", "revisits", "mean_dwell_s", "share"])
    exits["productID"] = exits["productID"].map(_pid)
    exits["dwell_s"] = exits["durationMs"] / 1000
    grouped = exits.groupby(["screen", "productID", "target"], dropna=False)["dwell_s"]
    out = grouped.agg(dwell_s="sum", visits="count", mean_dwell_s="mean").reset_index()
    out["revisits"] = out["visits"] - 1
    g = gaze.copy()
    g["productID"] = g["productID"].map(_pid) if "productID" in g else None
    screen_time = {k: tracked_time(s, params) for k, s in g.groupby(["screen", "productID"], dropna=False)}
    out["share"] = [
        (r.dwell_s / screen_time[(r.screen, r.productID)]) if screen_time.get((r.screen, r.productID), 0) > 0 else np.nan
        for r in out.itertuples()
    ]
    return out.sort_values("dwell_s", ascending=False).reset_index(drop=True)


def fixation_areas(fix: pd.DataFrame) -> pd.DataFrame:
    """Dwell and revisits per area from fixations rather than from per-sample attribution.

    A visit is a run of consecutive fixations on the same area; revisits are visits after
    the first. The app's sample-level enter and exit events flicker at area borders under
    gaze noise, which inflates their visit counts; fixations, which already integrate over
    the noise, give the count a person would recognise. Both are reported.
    """
    if fix.empty:
        return pd.DataFrame(columns=["screen", "productID", "target", "fixation_dwell_s", "fixations", "visits", "revisits"])
    f = fix.copy()
    f["target"] = f["target"].where(f["target"].notna(), "off_area")
    key = f["screen"].astype(str) + "|" + f["productID"].astype(str) + "|" + f["target"].astype(str)
    f["run"] = (key != key.shift()).cumsum()
    runs = f.groupby("run").agg(screen=("screen", "first"), productID=("productID", "first"), target=("target", "first"),
                                dwell=("duration_s", "sum"), n=("duration_s", "size"))
    out = runs.groupby(["screen", "productID", "target"], dropna=False).agg(
        fixation_dwell_s=("dwell", "sum"), fixations=("n", "sum"), visits=("dwell", "size")).reset_index()
    out["revisits"] = out["visits"] - 1
    return out.sort_values("fixation_dwell_s", ascending=False).reset_index(drop=True)


def transitions(events: pd.DataFrame) -> tuple[pd.DataFrame, int]:
    """Gaze transitions between areas of interest, counted from consecutive area entries on
    the same screen, self-transitions excluded. Also returns the number of switches between
    different products on the list screen, the raw material of a comparison count."""
    enters = events[events["event"] == "area_enter"]
    pairs, switches = [], 0
    prev = None
    for e in enters.itertuples():
        cur = (e.screen, _pid(e.productID), e.target)
        if prev is not None and prev[0] == cur[0]:
            if prev[0] == "product_list" and prev[1] != cur[1]:
                switches += 1
            if prev[2] != cur[2]:
                pairs.append((prev[2], cur[2]))
        prev = cur
    if not pairs:
        return pd.DataFrame(), switches
    matrix = pd.crosstab(pd.Series([p[0] for p in pairs], name="from"), pd.Series([p[1] for p in pairs], name="to"))
    return matrix, switches


# ---------------------------------------------------------------- taps

def tap_features(events: pd.DataFrame, gaze: pd.DataFrame, fix: pd.DataFrame, params: Params = Params()) -> pd.DataFrame:
    """One row per tap: what was tapped, how, and how the eyes related to it.

    - ``press_ms``, ``contact_radius_pt``: from the touch hardware.
    - ``element_distance_pt``: median gaze in the pre-tap window to the tapped element's
      frame, zero inside it. NaN when the tap carried no frame.
    - ``looked_first_s``: time from the first fixation inside the element on that screen
      visit to the tap. ``hesitation_s``: time from the end of the last such fixation to the
      tap, zero if the eyes were still on it. Both NaN when no fixation landed on it.
    """
    taps = events[events["event"] == "tap"]
    visits = screen_visits(events)
    px = gaze["x"].to_numpy(float)
    py = gaze["y"].to_numpy(float)
    ts = gaze["timestamp"].to_numpy(float)
    finite = np.isfinite(px) & np.isfinite(py)
    has_frame = all(c in taps for c in ("targetMinX", "targetMinY", "targetMaxX", "targetMaxY"))
    rows = []
    for t in taps.itertuples():
        row = dict(
            timestamp=t.timestamp, screen=t.screen, productID=_pid(t.productID), target=t.target,
            x=t.x, y=t.y,
            press_ms=getattr(t, "durationMs", np.nan),
            contact_radius_pt=getattr(t, "contactRadiusPt", np.nan),
            element_distance_pt=np.nan, looked_first_s=np.nan, hesitation_s=np.nan,
        )
        frame = None
        if has_frame and np.isfinite(t.targetMinX):
            frame = (t.targetMinX, t.targetMinY, t.targetMaxX, t.targetMaxY)
            w = (ts > t.timestamp - params.pre_tap_window_s[0]) & (ts <= t.timestamp - params.pre_tap_window_s[1]) & finite
            if w.sum() >= 3:
                gx, gy = np.median(px[w]), np.median(py[w])
                dx = max(frame[0] - gx, 0, gx - frame[2]) * geo.POINT_WIDTH
                dy = max(frame[1] - gy, 0, gy - frame[3]) * geo.POINT_HEIGHT
                row["element_distance_pt"] = float(np.hypot(dx, dy))
            visit = visits[(visits["start"] <= t.timestamp) & (visits["end"] >= t.timestamp)]
            start = visit["start"].iloc[-1] if not visit.empty else -np.inf
            on = fix[(fix["start"] >= start) & (fix["start"] < t.timestamp)
                     & (fix["x"] >= frame[0]) & (fix["x"] <= frame[2]) & (fix["y"] >= frame[1]) & (fix["y"] <= frame[3])]
            if not on.empty:
                row["looked_first_s"] = float(t.timestamp - on["start"].iloc[0])
                row["hesitation_s"] = float(max(t.timestamp - on["end"].iloc[-1], 0))
        rows.append(row)
    columns = ["timestamp", "screen", "productID", "target", "x", "y", "press_ms", "contact_radius_pt",
               "element_distance_pt", "looked_first_s", "hesitation_s"]
    return pd.DataFrame(rows, columns=columns)


# ---------------------------------------------------------------- scrolling

def scroll_features(events: pd.DataFrame, params: Params = Params()) -> pd.DataFrame:
    """Scroll rhythm per screen visit: bursts (runs of scroll rows closer than
    ``scroll_burst_gap_s``), total travel in points, direction reversals, and peak speed."""
    scrolls = events[events["event"] == "scroll"].copy()
    scrolls["productID"] = scrolls["productID"].map(_pid)
    rows = []
    for (screen, pid), s in scrolls.groupby(["screen", "productID"], dropna=False):
        s = s.sort_values("timestamp")
        gaps = s["timestamp"].diff().fillna(np.inf)
        rows.append(dict(
            screen=screen, productID=pid,
            bursts=int((gaps > params.scroll_burst_gap_s).sum()),
            travel_pt=float(s["offset"].diff().abs().sum()),
            reversals=int(s["reversals"].max() - s["reversals"].min()) if "reversals" in s else 0,
            peak_speed_pt_s=float(s["velocity"].abs().max()) if "velocity" in s else np.nan,
            scrolling_s=float(np.minimum(s["timestamp"].diff().dropna(), params.scroll_burst_gap_s).sum()),
        ))
    return pd.DataFrame(rows, columns=["screen", "productID", "bursts", "travel_pt", "reversals", "peak_speed_pt_s", "scrolling_s"])


# ---------------------------------------------------------------- face, head and holding

def face_summary(all_gaze: pd.DataFrame, params: Params = Params()) -> dict:
    """Observable face and holding covariates over the session, by screen kind.

    Blend shapes are summarised as median and 90th percentile of the raw coefficient; they
    are numbers about the face, not statements about the person. Blink rate counts onsets
    of the app's ``blink`` quality per minute of tracked time.
    """
    def summarise(g: pd.DataFrame) -> dict:
        good = g[g["quality"] == "good"]
        tracked = tracked_time(good, params)
        onsets = int(((g["quality"] == "blink") & (g["quality"].shift() != "blink")).sum())
        out = dict(
            tracked_s=tracked,
            blink_per_min=(onsets / tracked * 60) if tracked > 0 else np.nan,
            eyes_open_share=float(good["eyesOpen"].astype(float).mean()) if not good.empty else np.nan,
            on_display_share=float(((good["x"] >= 0) & (good["x"] <= 1) & (good["y"] >= 0) & (good["y"] <= 1)).mean()) if not good.empty else np.nan,
            distance_cm=float(-good["eyeZ"].mean() * 100) if "eyeZ" in good and not good.empty else np.nan,
            head_yaw_sd_deg=float(np.degrees(good["headYawRad"].std())) if "headYawRad" in good else np.nan,
            head_pitch_sd_deg=float(np.degrees(good["headPitchRad"].std())) if "headPitchRad" in good else np.nan,
            phone_tilt_deg=float(np.degrees(good["deviceTiltRad"].mean())) if "deviceTiltRad" in good else np.nan,
            phone_disturbance_mm=float(good["deviceDisturbanceMm"].median()) if "deviceDisturbanceMm" in good else np.nan,
        )
        for key in EXPRESSION:
            if key in good and not good.empty:
                out[f"{key}_median"] = float(good[key].median())
                out[f"{key}_p90"] = float(good[key].quantile(0.9))
        return out

    result = {"all": summarise(all_gaze)}
    for screen, g in all_gaze.groupby("screen"):
        result[str(screen)] = summarise(g)
    return result


# ---------------------------------------------------------------- navigation

def navigation(events: pd.DataFrame, switches: int) -> dict:
    """Explicit behaviour: products viewed and selected, backtracking, timing."""
    t0 = events["timestamp"].min()
    viewed = events[events["event"] == "product_viewed"]
    selected = events[events["event"] == "product_selected"]
    first_selection = selected["timestamp"].min() if not selected.empty else np.nan
    before = viewed[viewed["timestamp"] < first_selection]["productID"].map(_pid).nunique() if not selected.empty else viewed["productID"].map(_pid).nunique()
    return dict(
        session_s=float(events["timestamp"].max() - t0),
        products_viewed=int(viewed["productID"].map(_pid).nunique()),
        product_views=int(len(viewed)),
        selections=int(len(selected)),
        products_viewed_before_first_selection=int(before),
        time_to_first_selection_s=float(first_selection - t0) if not selected.empty else np.nan,
        backs=int((events["event"] == "back").sum()),
        list_switches=int(switches),
        taps=int((events["event"] == "tap").sum()),
    )


# ---------------------------------------------------------------- the fingerprint

def fingerprint(session: dict, events: pd.DataFrame, params: Params = Params()) -> dict:
    """Everything above, for one session, as one JSON-serialisable document."""
    visits = screen_visits(events)
    all_gaze = attribute_screens(events[events["event"] == "gaze"], visits).reset_index(drop=True)
    gaze = all_gaze[all_gaze["quality"] == "good"].reset_index(drop=True)
    fix = fixations(gaze, params)
    sac = saccades(fix)
    dwell = area_dwell(events, gaze, params)
    matrix, switches = transitions(events)
    taps = tap_features(events, gaze, fix, params)
    scroll = scroll_features(events, params)
    tracked = tracked_time(gaze, params)

    fix_summary = dict(
        count=int(len(fix)),
        per_min=float(len(fix) / tracked * 60) if tracked > 0 else np.nan,
        mean_duration_s=float(fix["duration_s"].mean()) if len(fix) else np.nan,
        median_duration_s=float(fix["duration_s"].median()) if len(fix) else np.nan,
        share_of_tracked=float(fix["duration_s"].sum() / tracked) if tracked > 0 else np.nan,
        saccade_median_amplitude_pt=float(sac["amplitude_pt"].median()) if len(sac) else np.nan,
    )
    tap_summary = dict(
        count=int(len(taps)),
        median_press_ms=float(taps["press_ms"].median()) if len(taps) else np.nan,
        median_contact_radius_pt=float(taps["contact_radius_pt"].median()) if len(taps) else np.nan,
        median_element_distance_pt=float(taps["element_distance_pt"].median()) if taps["element_distance_pt"].notna().any() else np.nan,
        looked_at_share=float((taps["element_distance_pt"] == 0).sum() / taps["element_distance_pt"].notna().sum()) if taps["element_distance_pt"].notna().any() else np.nan,
        median_looked_first_s=float(taps["looked_first_s"].median()) if taps["looked_first_s"].notna().any() else np.nan,
        median_hesitation_s=float(taps["hesitation_s"].median()) if taps["hesitation_s"].notna().any() else np.nan,
    )
    return dict(
        session=dict(id=session.get("id"), appVersion=session.get("appVersion"), device=session.get("device"),
                     startedAtWallClock=(session.get("clockAnchor") or {}).get("wallClock")),
        params=asdict(params),
        tracked_s=tracked,
        screens=_records(visits),
        fixations=fix_summary,
        fixation_list=_records(fix),
        areas=_records(dwell),
        fixation_areas=_records(fixation_areas(fix)),
        transitions={str(k): {str(kk): int(vv) for kk, vv in v.items()} for k, v in matrix.to_dict(orient="index").items()} if not matrix.empty else {},
        taps=tap_summary,
        tap_list=_records(taps),
        scroll=_records(scroll),
        face=face_summary(all_gaze, params),
        navigation=navigation(events, switches),
    )


def flatten(fp: dict) -> dict:
    """The scalar features of a fingerprint as one flat row, for comparing sessions."""
    row = {"tracked_s": fp["tracked_s"]}
    row.update({f"fixation.{k}": v for k, v in fp["fixations"].items()})
    row.update({f"tap.{k}": v for k, v in fp["taps"].items()})
    row.update({f"nav.{k}": v for k, v in fp["navigation"].items()})
    face = fp["face"].get("all", {})
    row.update({f"face.{k}": v for k, v in face.items() if not k.endswith("_p90")})
    scroll = pd.DataFrame(fp["scroll"])
    if not scroll.empty:
        row["scroll.bursts"] = int(scroll["bursts"].sum())
        row["scroll.travel_pt"] = float(scroll["travel_pt"].sum())
        row["scroll.reversals"] = int(scroll["reversals"].sum())
    areas = pd.DataFrame(fp["areas"])
    if not areas.empty:
        by_target = areas.groupby("target")["dwell_s"].sum()
        row.update({f"dwell.{k}_s": float(v) for k, v in by_target.items()})
        row["dwell.revisits_sampled"] = int(areas["revisits"].sum())
    fixed = pd.DataFrame(fp["fixation_areas"])
    if not fixed.empty:
        row["dwell.revisits_fixation"] = int(fixed["revisits"].sum())
    return row


def _records(frame: pd.DataFrame) -> list[dict]:
    if frame.empty:
        return []
    clean = frame.replace({np.nan: None})
    return [{k: (v.item() if hasattr(v, "item") else v) for k, v in r.items()} for r in clean.to_dict(orient="records")]
