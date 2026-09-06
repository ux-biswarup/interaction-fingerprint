"""Figures of a fingerprint, for the write-up and for looking at a session as a whole.

Everything is drawn from the fingerprint document (`features.fingerprint`), never from
the raw events, so a figure and the numbers beside it can never disagree. Output is PNG
through matplotlib's non-interactive backend. Definitions: `docs/product/12-FINGERPRINT-FEATURES.md`.
"""
from __future__ import annotations

import math
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

from . import geometry as geo  # noqa: E402

INK, PAPER, ACCENT, BLUE, WARN, DIM = "#0d0d0f", "#f4f1ea", "#f5c400", "#6aa9ff", "#ff7a5c", "#8b8a86"
SCREEN_ORDER = ["product_list", "product_detail"]
TARGET_ORDER = ["list_item", "product_image", "title", "price", "rating", "reviews", "description", "cta", "back", "header", "off_area"]


def _phone_axes(ax, title):
    ax.set_facecolor(PAPER)
    ax.set_xlim(0, geo.POINT_WIDTH)
    ax.set_ylim(geo.POINT_HEIGHT, 0)
    ax.set_aspect("equal")
    ax.set_xticks([])
    ax.set_yticks([])
    for spine in ax.spines.values():
        spine.set_edgecolor("#2a2a30")
        spine.set_linewidth(2)
    ax.set_title(title, color=PAPER, fontsize=9, loc="left")


def scan_path(fp: dict, ax, screen: str) -> None:
    """Fixations as circles sized by duration, joined in order; taps as crosses with the
    element they hit. One screen kind per panel, all visits overlaid."""
    fix = pd.DataFrame(fp.get("fixation_list", []))
    taps = pd.DataFrame(fp.get("tap_list", []))
    _phone_axes(ax, f"{screen.replace('_', ' ')} · scan path")
    if not fix.empty and "screen" in fix:
        f = fix[fix["screen"] == screen]
        xs, ys = f["x"].to_numpy() * geo.POINT_WIDTH, f["y"].to_numpy() * geo.POINT_HEIGHT
        ax.plot(xs, ys, color=BLUE, linewidth=0.6, alpha=0.5, zorder=1)
        ax.scatter(xs, ys, s=12 + 160 * f["duration_s"].clip(upper=1.5), facecolors=(0.42, 0.65, 1.0, 0.25),
                   edgecolors=BLUE, linewidths=0.8, zorder=2)
    if not taps.empty and "screen" in taps:
        t = taps[taps["screen"] == screen]
        for row in t.itertuples():
            if getattr(row, "element_distance_pt", None) is not None and not (isinstance(row.element_distance_pt, float) and math.isnan(row.element_distance_pt)):
                colour = ACCENT if row.element_distance_pt == 0 else WARN
            else:
                colour = DIM
            ax.scatter([row.x * geo.POINT_WIDTH], [row.y * geo.POINT_HEIGHT], marker="x", s=60, color=colour, linewidths=1.8, zorder=3)


def dwell_bars(fp: dict, ax) -> None:
    """Fixation-based dwell per area, list screen in yellow, detail screens in blue."""
    areas = pd.DataFrame(fp.get("fixation_areas", []))
    ax.set_facecolor(INK)
    ax.tick_params(colors=PAPER, labelsize=8)
    for spine in ax.spines.values():
        spine.set_visible(False)
    ax.set_title("dwell by area from fixations, seconds", color=PAPER, fontsize=9, loc="left")
    if areas.empty:
        ax.text(0.5, 0.5, "no fixations", color=DIM, ha="center", transform=ax.transAxes)
        return
    areas["target"] = areas["target"].fillna("off_area")
    by = areas.groupby(["screen", "target"], dropna=False)["fixation_dwell_s"].sum().reset_index()
    by["order"] = by["target"].map({t: i for i, t in enumerate(TARGET_ORDER)}).fillna(99)
    by = by.sort_values(["screen", "order"], ascending=[False, True])
    labels = [f"{r.target}" + (" (list)" if r.screen == "product_list" else "") for r in by.itertuples()]
    colours = [ACCENT if r.screen == "product_list" else BLUE for r in by.itertuples()]
    ax.barh(labels, by["fixation_dwell_s"], color=colours)
    ax.invert_yaxis()
    ax.grid(axis="x", color="#26262c", linewidth=0.5)


def transition_graph(fp: dict, ax) -> None:
    """Areas on a circle, arrows weighted by how often the gaze moved from one to the next."""
    tr = fp.get("transitions") or {}
    ax.set_facecolor(INK)
    ax.set_xticks([])
    ax.set_yticks([])
    for spine in ax.spines.values():
        spine.set_visible(False)
    ax.set_title("gaze transitions between areas", color=PAPER, fontsize=9, loc="left")
    nodes = sorted({k for k in tr} | {kk for v in tr.values() for kk in v}, key=lambda t: TARGET_ORDER.index(t) if t in TARGET_ORDER else 99)
    if not nodes:
        ax.text(0.5, 0.5, "no transitions", color=DIM, ha="center", transform=ax.transAxes)
        return
    angles = {n: 2 * math.pi * i / len(nodes) for i, n in enumerate(nodes)}
    pos = {n: (math.cos(a), math.sin(a)) for n, a in angles.items()}
    peak = max(v for row in tr.values() for v in row.values()) or 1
    for src, row in tr.items():
        for dst, count in row.items():
            if count <= 0 or src == dst:
                continue
            (x0, y0), (x1, y1) = pos[src], pos[dst]
            ax.annotate("", xy=(x1 * 0.85, y1 * 0.85), xytext=(x0 * 0.85, y0 * 0.85),
                        arrowprops=dict(arrowstyle="-|>", color=BLUE, alpha=0.25 + 0.75 * count / peak,
                                        linewidth=0.5 + 3 * count / peak, connectionstyle="arc3,rad=0.15"))
    for n, (x, y) in pos.items():
        total = sum(tr.get(n, {}).values()) + sum(row.get(n, 0) for row in tr.values())
        ax.scatter([x], [y], s=120 + 6 * total, color=INK, edgecolors=ACCENT, linewidths=1.5, zorder=3)
        ax.text(x * 1.22, y * 1.22, n, color=PAPER, fontsize=8, ha="center", va="center")
    ax.set_xlim(-1.5, 1.5)
    ax.set_ylim(-1.5, 1.5)
    ax.set_aspect("equal")


def headline(fp: dict) -> str:
    s, f, t, n, face = fp["session"], fp["fixations"], fp["taps"], fp["navigation"], fp["face"].get("all", {})
    def v(x, d=0, suffix=""):
        return "—" if x is None or (isinstance(x, float) and math.isnan(x)) else f"{x:.{d}f}{suffix}"
    return (f"session {str(s.get('id'))[:8]} · {v(n.get('session_s'))} s · {v(fp.get('tracked_s'))} s tracked · "
            f"{v(f.get('per_min'))} fixations/min, median {v((f.get('median_duration_s') or 0) * 1000)} ms · "
            f"{n.get('taps')} taps, looked at first {v((t.get('looked_at_share') or float('nan')) * 100, 0, '%')} · "
            f"blink {v(face.get('blink_per_min'), 1)}/min · {v(face.get('distance_cm'))} cm")


def fingerprint_card(fp: dict, path: Path) -> Path:
    """One page: both scan paths, dwell bars, the transition graph, and the headline numbers."""
    fig = plt.figure(figsize=(12, 9), facecolor=INK)
    grid = fig.add_gridspec(2, 3, width_ratios=[1, 1, 1.4], height_ratios=[1, 1], wspace=0.25, hspace=0.25)
    scan_path(fp, fig.add_subplot(grid[:, 0]), "product_list")
    scan_path(fp, fig.add_subplot(grid[:, 1]), "product_detail")
    dwell_bars(fp, fig.add_subplot(grid[0, 2]))
    transition_graph(fp, fig.add_subplot(grid[1, 2]))
    fig.suptitle(headline(fp), color=PAPER, fontsize=10, x=0.02, ha="left")
    fig.text(0.02, 0.01, "circles: fixations sized by duration · crosses: taps, yellow when the gaze was on the element, red when not · "
             "features as defined in docs/product/12-FINGERPRINT-FEATURES.md", color=DIM, fontsize=7)
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, dpi=110, facecolor=INK)
    plt.close(fig)
    return path


def effects_figure(effects: pd.DataFrame, yardstick: pd.DataFrame, path: Path) -> Path:
    """Standardised difference between the levels of each factor, per feature, beside the
    day-to-day spread of the same feature under a fixed condition."""
    if effects.empty:
        return path
    pivot = effects.pivot_table(index="feature", columns="factor", values="d", aggfunc="first")
    yard = yardstick.set_index("feature")["day_cv"] if not yardstick.empty else pd.Series(dtype=float)
    fig, (left, right) = plt.subplots(1, 2, figsize=(11, 0.3 * len(pivot) + 2), facecolor=INK,
                                      gridspec_kw=dict(width_ratios=[1.6, 1], wspace=0.6))
    for ax in (left, right):
        ax.set_facecolor(INK)
        ax.tick_params(colors=PAPER, labelsize=7)
        for spine in ax.spines.values():
            spine.set_visible(False)
    image = left.imshow(pivot.to_numpy(dtype=float), cmap="coolwarm", vmin=-2, vmax=2, aspect="auto")
    left.set_yticks(range(len(pivot.index)))
    left.set_yticklabels(pivot.index)
    left.set_xticks(range(len(pivot.columns)))
    left.set_xticklabels([f"{c}" for c in pivot.columns])
    for i, feature in enumerate(pivot.index):
        for j, factor in enumerate(pivot.columns):
            v = pivot.loc[feature, factor]
            if pd.notna(v):
                left.text(j, i, f"{v:+.1f}", ha="center", va="center", color=INK if abs(v) > 1 else PAPER, fontsize=7)
    left.set_title("second level minus first, in within-level sd (d)", color=PAPER, fontsize=9, loc="left")
    bar = fig.colorbar(image, ax=left, fraction=0.03, pad=0.02)
    bar.ax.tick_params(colors=PAPER, labelsize=7)
    values = [yard.get(f, np.nan) for f in pivot.index]
    right.barh(range(len(pivot.index)), values, color=DIM)
    right.set_yticks(range(len(pivot.index)))
    right.set_yticklabels([""] * len(pivot.index))
    right.invert_yaxis()
    right.set_title("day-to-day spread, same condition (cv)", color=PAPER, fontsize=9, loc="left")
    right.grid(axis="x", color="#26262c", linewidth=0.5)
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, dpi=110, facecolor=INK, bbox_inches="tight")
    plt.close(fig)
    return path


def stability_figure(table: pd.DataFrame, stability: pd.DataFrame, path: Path) -> Path:
    """Left: each feature's spread across sessions as a coefficient of variation. Right:
    every session's features as deviations from the median, so a session that stands out
    stands out."""
    fig, (left, right) = plt.subplots(1, 2, figsize=(14, 0.32 * len(stability) + 2), facecolor=INK,
                                      gridspec_kw=dict(width_ratios=[1, 1.6], wspace=0.55))
    for ax in (left, right):
        ax.set_facecolor(INK)
        ax.tick_params(colors=PAPER, labelsize=7)
        for spine in ax.spines.values():
            spine.set_visible(False)
    s = stability.sort_values("cv")
    colours = [ACCENT if c < 0.2 else BLUE if c < 0.5 else WARN for c in s["cv"]]
    left.barh(s["feature"], s["cv"], color=colours)
    left.invert_yaxis()
    left.axvline(0.2, color=DIM, linewidth=0.6, linestyle="--")
    left.set_title("spread across sessions (sd / mean); yellow under 0.2", color=PAPER, fontsize=9, loc="left")
    left.grid(axis="x", color="#26262c", linewidth=0.5)
    z = table[s["feature"]].copy()
    med = z.median()
    scale = (z - med).abs().median().replace(0, np.nan)
    dev = ((z - med) / scale).clip(-3, 3).T
    image = right.imshow(dev.to_numpy(dtype=float), cmap="coolwarm", vmin=-3, vmax=3, aspect="auto")
    right.set_yticks(range(len(dev.index)))
    right.set_yticklabels(dev.index)
    right.set_xticks(range(len(dev.columns)))
    right.set_xticklabels([str(c)[:8] for c in dev.columns], rotation=90)
    right.set_title("each session against the median of all (robust z, clipped ±3)", color=PAPER, fontsize=9, loc="left")
    bar = fig.colorbar(image, ax=right, fraction=0.03, pad=0.02)
    bar.ax.tick_params(colors=PAPER, labelsize=7)
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, dpi=110, facecolor=INK, bbox_inches="tight")
    plt.close(fig)
    return path
