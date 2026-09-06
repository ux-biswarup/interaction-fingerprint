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
to 1.5 s. **Gate passed** for the instrumentation. A third recording then exposed a fault in
the calibration's prediction rule, and the exported calibration frames exposed two deeper
ones: ARKit's camera axes were rotated relative to the geometry, and the eye signal arrives
at a fifth of its true size on top of a full-strength head direction. The model is now
head plus corrected eye-in-head on corrected axes, and gaze-before-tap error in free viewing
is the figure that judges it; see `10-MOTION-FUSION.md` sections 9, 11 and 12. **Sensing
accuracy in free viewing is currently 4° to 6° and is the open problem of Phase 1.** Natural
hand-held use is the premise and stays; the fix is a better eye-in-head estimate, Phase 1b in
`11-LEARNED-EYE-MODEL.md`. Status, 6 September 2026: pupil landmarks tried and kept as the
shipped source (199 pt against taps, best so far, not enough); a learned eye model trained on
MPIIFaceGaze reaches correlation 0.97 and gain 0.96 horizontally on a person it never saw,
against ARKit's gain of 0.2, and runs on the phone as the shipped gaze source since its
second calibration that morning: 22 pt held out on the grid, and in free viewing **28 pt
median from the gaze to the element that was tapped**, 4.6 mm, with 6 of 11 taps looked at
directly. The fingertip distance on the same taps is 168 pt, because the eyes rest on a
row's label while the finger lands at its right end; taps now carry the element's frame so
the metric measures what it claims to. **Phase 1b sensing gate passed against 2 cm.** Open
residues, tracked in `11-LEARNED-EYE-MODEL.md` §3: a 30–50 pt upward offset on a third of
taps, and a leftward lean at the near end of the calibrated range.

### Next steps, decided 6 September 2026

1. **Phase 3, the fingerprint, starts now.** Everything before this made the numbers
   trustworthy; nothing yet turns a session into features. First deliverable: a Python pass
   over one session producing fixations and saccades, dwell and revisits per area of
   interest, time from first look to tap, scroll rhythm, tap character, and blend-shape
   summaries per screen described only as what they are. The two shopping sessions recorded
   on the same calibration on 6 September are the first comparison.
2. **More sessions from the researcher at different distances and postures**, sitting, lying
   back, phone further away, without recalibrating. The two open residues, the upward offset
   and the leftward lean, need data, not code. If the lean follows distance it is a head-pose
   residue and head-pose normalisation of the eye crops goes on the list; if not, it is how
   this person looks, and becomes a feature rather than a bug.
3. **No change to the model itself yet.** It passed with margin. Head-pose normalisation
   costs a retraining cycle and a new bundle and there is no evidence it would change a
   decision. The GazeCapture request stays open in case phone-domain data is ever needed.
4. **Before Phase 4 participants:** the calibration has only ever seen one face and must
   survive a stranger; and the header region needs an area of interest, since a tap outside
   any registered area is currently labelled a list item by default (the missing frame now
   flags it).

## Phase 3 — Fingerprint
Normalize events, derive features, summarize sessions, visualize fingerprints.

**Exit:** a session has a meaningful fingerprint.

Status, 6 September 2026: first pass built and run on the two same-calibration sessions,
`Analysis/fingerprint_session.py`; definitions with units in `12-FINGERPRINT-FEATURES.md`,
which also records what the first two fingerprints look like and the two instrumentation
gaps they exposed (off-area gaze rows carried no screen; per-sample area attribution
flickers at borders and inflates revisits fivefold). Visualisation: the desk dashboard
(`13-DESK-LINK.md`) shows a session live, the gaze on the screen layout with fixations and
taps, dwell bars, the transition matrix and the fingerprint numbers, and compares sessions
side by side; recordings now reach `Data/` without anyone copying files.

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
