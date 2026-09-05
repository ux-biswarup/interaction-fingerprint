# Roadmap

## Phase 0 — Setup
Xcode, SwiftUI shell, Git structure, permissions.

## Phase 1 — Sensing
ARKit face tracking, gaze, selected eye/facial signals, timestamps, per-person gaze
calibration.

**Exit:** a reliable 30–60 second recording, where reliable is measured, not assumed:
tracked-frame share above 90%, sample rate near 60 Hz, and a calibration whose mean
residual is small enough that the intended areas of interest can be told apart. Gaze
without a calibration figure attached is not evidence.

Reached 1.62° on device, see `09-GAZE-ACCURACY.md`. Device motion is handled as set out in
`10-MOTION-FUSION.md`: ARKit's inertial tracking is on, the motion gate judges how far the
screen moved under the eyes in millimetres, and how the phone is held is recorded with every
sample.

## Phase 2 — Instrumentation
Taps, scrolls, screen/product IDs, areas of interest, JSON export.

**Exit:** synchronized behavioral + perceptive event stream.

Built. One event stream carries gaze samples and interaction events stamped from a single
monotonic clock. Areas of interest are declared on the views themselves and gaze is
attributed to them on device, while the raw coordinate is kept so a recording can be
re-attributed if the region definitions change. Touch contact radius and press duration,
scroll velocity and direction reversals, and ambient light are all recorded. Sessions export
as JSON and newline-delimited JSON.

First real recording on 5 September 2026: 1,739 events, gapless, 59.9 Hz, 95% of frames
in the trusted envelope. It exposed two defects, both now fixed and covered by tests: the
calibration extrapolated its head-pose and quadratic terms and sent half of the gaze off
the screen, and taps were not recorded at all. See `10-MOTION-FUSION.md` section 9.
Second recording, same day: 20 taps all attributed, 72% of gaze on the display, dwells up
to 1.5 s. **Gate passed.**

## Phase 3 — Fingerprint
Normalize events, derive features, summarize sessions, visualize fingerprints.

**Exit:** a session has a meaningful fingerprint.

## Phase 4 — Exploratory study
Control condition, tasks, 8–12 participants, qualitative + quantitative analysis.

**Exit:** evidence about whether fingerprint signals add useful information.

## Phase 5 — Modeling
Correlation analysis, simple predictive models, compare signal groups, assess false positives.

**Exit:** identify useful and non-useful signal combinations.

## Phase 6 — Adaptive prototype
Predefined interventions, agent interpretation, generated explanations/comparisons.

## Phase 7 — Agentic + generative UI
Agent decides whether to intervene; generative UI chooses presentation.

## Phase 8 — Research artifact
Research report, portfolio case study, public GitHub documentation, public article.

## Phase 9 — Optional academic paper
Only if methodology and evidence justify formal publication.
