---
name: data-visualization
description: Visualize fingerprints and research findings: gaze heatmaps and scan paths over screen mockups, per-session timelines, AOI dwell comparisons, and effect-size plots with confidence intervals. Use for any chart in Analysis/ or in a write-up. Priority: next.
---
# Data visualization for fingerprints

If a `dataviz` skill is available in the session, load it too for color and form rules. This
file covers what is specific to this project.

## Core plots, in order of usefulness

1. **Session timeline.** x = time; colored bands for the gaze `target`; lines for the nine blend
   shapes (normalized 0 to 1) on a second axis; vertical markers for `tap`, `scroll`, `back`,
   `screen_appear`. One figure per session, saved to `Data/derived/plots/<session>.png`. This is
   the first thing to look at for every session and catches data problems immediately.
2. **Scan path over a screen mockup.** Draw the AOI rectangles of the screen (from the AOI
   registry export), then fixations as circles sized by duration and connected in order.
   Use a wireframe, not a screenshot with real product content, so it can be shared.
3. **Gaze heatmap.** 2D histogram or KDE of gaze points over the same wireframe. Report the
   tracking-loss share in the caption.
4. **Dwell per AOI, control versus treatment.** Paired dot plot: one line per participant
   connecting the two conditions. Shows direction and consistency better than bars.
5. **Effect sizes.** Forest plot of the primary and secondary outcomes with 95% CIs, zero line
   marked. This is the figure for the write-up.
6. **Event-locked averages.** Mean blend shape from -2 s to +2 s around taps with a CI band.

## Rules

- Every figure states n, session or participant count, and tracking-loss handling in the caption.
- Coordinates: gaze is normalized 0 to 1 with origin top-left. Flip y for matplotlib
  (`ax.invert_yaxis()`) so plots match the screen.
- Use one colorblind-safe palette for AOIs across all plots, defined once in
  `Analysis/fingerprint/plotting.py`.
- Never plot on top of participant-identifying content.
- Save figures as both PNG (for docs) and SVG (for editing). Do not commit under `Data/`;
  copy chosen figures into `Research/figures/` explicitly.

## Tools

matplotlib for static figures, seaborn optional, plotly for interactive timeline exploration in
notebooks. Keep plotting functions in `plotting.py` and call them from notebooks.

## Related
`python-pandas`, `eye-tracking-concepts`, `basic-statistics`.
