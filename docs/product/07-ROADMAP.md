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

## Phase 2 — Instrumentation
Taps, scrolls, screen/product IDs, areas of interest, JSON export.

**Exit:** synchronized behavioral + perceptive event stream.

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
