# 12 — Fingerprint features

The Interaction Fingerprint is a set of features derived from one session's event stream.
This document defines each one, with units, before it is coded; `Analysis/fingerprint/
features.py` follows it, and `Analysis/fingerprint_session.py` produces the fingerprint of
a recording. Everything here describes observable behaviour. No feature names an emotion,
an intent or a mental state, and none will: the rule from `02-INTERACTION-FINGERPRINT.md`
and `06-RESEARCH-PRINCIPLES.md` is that observations are stored and interpretations, if
any, are derived separately and labelled as such.

Time is in seconds on the device clock, distances on the screen in points (the iPhone 15
display is 393 × 852 pt; 1 pt ≈ 0.166 mm), rates per minute of tracked time. Every
fingerprint carries the thresholds it was computed with (`params`), so a number can always
be traced to the definition that produced it.

## 1. Inputs

The flattened event frame of `load.load_session`: one row per event, `metrics` and
`signals` flattened into columns. Only gaze rows with `quality == good` enter the gaze
features; rows flagged `blink`, `no_face`, `device_moving` or otherwise are kept for the
blink rate and for the tracked-time denominators only. Gaze coordinates are the screen
position the app computed at the time, under the calibration then in force (`isCalibrated`
on the row). The physical measurement is on the row too, so a session can be re-mapped
later, but the fingerprint is computed from what the app saw.

**Screen attribution.** Sessions recorded before the fix of 6 September 2026 stamped a gaze
row's screen from the area of interest under the gaze, so a row that hit no area carried no
screen either, 29% and 39% of good rows in the first two sessions. `attribute_screens` fills
those from the screen visit containing the row's time. Later recordings carry the screen on
every row.

## 2. Fixations and saccades

**Fixation.** A run of consecutive good gaze samples spanning at least `min_fixation_s`
(0.12 s) whose dispersion, (max x − min x) + (max y − min y) in points, stays at or under
`dispersion_pt` (80 pt), extended for as long as both hold. The I-DT algorithm of Salvucci
and Goldberg (2000), as described in `.claude/skills/eye-tracking-concepts`. The thresholds
are loose because the sensor's free-viewing accuracy is on the order of 30–130 pt
(`11-LEARNED-EYE-MODEL.md` §3). Any gap between consecutive samples longer than `max_gap_s`
(0.10 s), a blink or tracking loss, ends the window: fixations are not bridged across gaps.

A fixation records start, end, duration (s), sample count, centroid (normalised screen
coordinates), dispersion (pt), and the screen, product and area of interest most common
among its samples. A slow drift under about 300 pt/s can pass as a fixation; this is a known
property of dispersion methods and is accepted for now.

Summary: count, fixations per minute of tracked time, mean and median duration (s), share
of tracked time inside fixations.

**Saccade.** The jump between two consecutive fixations on the same screen visit: amplitude
(pt, centroid to centroid) and the gap between them (s). Summary: median amplitude.

## 3. Screens and areas of interest

**Screen visit.** One stay on a screen, from `screen_appear` to the matching
`screen_disappear` (same screen and product); a screen still showing at session end is
closed at the last event. Duration in seconds.

**Tracked time.** Seconds of good gaze, the sum of gaps between consecutive good rows, each
gap capped at `max_gap_s`. All shares and rates use this denominator, never raw sample
counts, so sessions with different tracking-loss rates compare.

**Dwell per area (sampled).** From the app's `area_exit` events, whose `durationMs` is the
time the gaze was attributed to that area on that visit. Per (screen, product, area): total
dwell (s), number of visits, revisits (visits after the first), mean dwell per visit (s), and
**share**, the dwell divided by the tracked time on that screen visit, which is the
attention distribution over the screen's areas.

**Dwell per area (from fixations).** The same quantities computed from fixations: a visit is
a run of consecutive fixations on the same area, dwell is their summed duration. Fixations
that hit no area are labelled `off_area`. The two agree on dwell within a few tenths of a
second but not on visits: the sampled count flickers at area borders under gaze noise and
came out five times higher than the fixation count on the first two sessions (329 against
64, 177 against 45). **The fixation-based revisit count is the one to use**; the sampled one
is kept because it is what the app itself could act on live.

**Transitions.** From consecutive `area_enter` events on the same screen, self-transitions
excluded: a from–to count matrix over areas. **List switches**: the number of consecutive
entries on the list screen whose product differed, the raw material of a comparison count.

## 4. Taps

Per tap: screen, area, product, position; **press** (`durationMs`, ms) and **contact
radius** (pt) from the touch hardware; and three relations to the eyes:

- **Element distance** (pt): the median gaze position over the pre-tap window, from
  `pre_tap_window_s` = 0.6 s to 0.1 s before the tap, measured to the tapped element's frame,
  zero when inside it. This is the gaze-accuracy measure of `11-LEARNED-EYE-MODEL.md`; a
  finger lands anywhere on a wide row while the eyes rest on its label, so distance to the
  fingertip is not used. NaN when the tap carried no frame (taps outside any registered area).
- **First look** (s): time from the start of the first fixation inside the element's frame,
  on that screen visit, to the tap.
- **Hesitation** (s): time from the end of the last fixation inside the element to the tap;
  zero if the eyes were still on it. Both NaN when no fixation landed on the element.

Summary: count, median press (ms), median contact radius (pt), median element distance
(pt), **looked-at share** (taps whose pre-tap gaze was inside the element, over taps with a
frame), median first look (s), median hesitation (s).

## 5. Scrolling

Per screen visit from the `scroll` rows: **bursts**, runs of scroll rows closer than
`scroll_burst_gap_s` (0.30 s); **travel** (pt), the sum of absolute offset changes;
**reversals**, from the app's running count; **peak speed** (pt/s); seconds spent scrolling.

## 6. Face, head and holding

Over all good gaze rows and per screen kind: tracked time (s); **blink rate**, onsets of
the app's `blink` quality per minute of tracked time; eyes-open share; on-display share of
gaze; viewing distance (cm); standard deviation of head yaw and pitch (°); phone tilt from
vertical (°) and the median motion-gate disturbance (mm) as covariates of how the phone was
held. For each of the nine expression blend shapes (`eyeBlink`, `eyeSquint`, `eyeWide` left
and right, `browInnerUp`, `browOuterUp` left and right): median and 90th percentile of the
raw coefficient. These are numbers about the face. They are reported so that they can be
tested for information in Phase 4 and 5, not because any meaning is assumed.

## 7. Navigation

Session length (s); distinct products viewed (`product_viewed`, which the app fires only
after a detail screen has been up long enough to count) and total views; selections
(`product_selected`); products viewed before the first selection; time to first selection
(s); backs; list switches (§3); taps.

## 8. Output

`Data/derived/fingerprint_<sessionID>.json`: the session identity and device, `params`, the
summaries above, and the full fixation, area, tap and scroll tables so that nothing has to
be recomputed to drill in. `flatten()` reduces a fingerprint to one row of scalars for
comparing sessions and, later, participants. `Data/` is never committed.

## 9. The first two fingerprints, 6 September 2026

Two shopping sessions by the researcher on the same calibration (learned source, 22 pt),
72 s and 47 s. Same person, same day, same phone: a first look at what is stable and what
moves.

| | Session 1 (72 s) | Session 2 (47 s) |
| --- | --- | --- |
| Fixations per minute / median duration | 184 / 217 ms | 179 / 184 ms |
| Share of tracked time in fixations | 79% | 68% |
| Saccade median amplitude | 50 pt | 51 pt |
| Taps / median press / contact radius | 15 / 131 ms / 24 pt | 12 / 190 ms / 24 pt |
| Looked at the element before tapping | no frames recorded | 45% of 11 |
| First look before tap / hesitation | | 1.1 s / 0 s |
| Products viewed / selected / backs | 4 / 4 / 5 | 3 / 3 / 4 |
| Time to first selection | 15.5 s | 10.0 s |
| List switches | 47 | 40 |
| Scroll bursts / travel / reversals | 25 / 3320 pt / 30 | 18 / 3194 pt / 46 |
| Blink rate | 8.4 /min | 6.3 /min |
| Head yaw / pitch sd | 0.6° / 1.1° | 1.7° / 4.9° |
| Revisits, sampled vs from fixations | 329 vs 64 | 177 vs 45 |
| Dwell by area, detail screens | description 10.2 s, title 8.6, image 7.3, reviews 3.9, price 3.7, rating 3.4 | title 4.2, description 4.1, cta 3.1, image 2.3, price 2.2 |

What stands out, as observations only:

- Fixation rate, saccade amplitude and contact radius are near-identical across the two
  sessions; scroll travel per product is too. These are candidates for the stable part of
  a fingerprint.
- Press duration, time to first selection, reversals and head movement differ by 30–50%.
  These are candidates for the state-dependent part, or for noise; two sessions cannot say.
- The gaze transition matrix on detail screens is dominated by title ↔ image and title ↔
  price ↔ rating ↔ reviews, with the CTA entered almost only from the description. Whether
  that is this person or this layout is a Phase 4 question.
- The instrumentation gaps found: gaze rows off any area carried no screen (fixed on device
  the same day, repaired in analysis for older sessions); per-sample area attribution
  inflates revisits fivefold (fixation-based count adopted); one tap landed outside any
  registered area (the header needs an area of interest).

## 10. Eleven sessions of one person: what holds still

`Analysis/fingerprint_report.py` draws every session's fingerprint card (both scan paths,
dwell bars, the transition graph, the headline numbers), writes `Data/derived/fingerprints.csv`
with one row of scalar features per session, counts turned into per-minute rates, and
measures the within-person spread of each feature over the sessions whose gaze can be
trusted. Trust is decided by the data: a session in which under 40% of tracked time falls
into fixations was recorded with a calibration that put the gaze off the screen, and its
gaze features describe the calibration, not the person. Four of the eleven sessions of
6 September 2026 fail that test, all of them from the morning's bad calibrations; three
more are too short or have too few taps. Seven remain, 22 to 86 seconds each.

Spread as coefficient of variation, standard deviation over mean, over those seven:

| Feature | Median | CV | Reading |
| --- | --- | --- | --- |
| Fixation median duration | 184 ms | 0.09 | **Stable.** 167–217 ms across seven sessions, two calibrations, a day apart. |
| Fixations per minute | 168 | 0.11 | **Stable.** 130–184. |
| Viewing distance | 33 cm | 0.10 | Stable, though that is the arm, not the eyes. |
| Share of tracked time in fixations | 0.68 | 0.19 | Borderline; it is also the quality measure. |
| Tap press duration | 106 ms | 0.31 | Moves: 81–190 ms. |
| List switches per minute | 60 | 0.32 | Moves. |
| Scroll bursts, travel, reversals per minute | | 0.35–0.48 | Move. |
| Blink rate | 8.4 /min | 0.46 | Moves: 3.9–15.7. |
| Saccade median amplitude | 72 pt | 0.37 | Moves; it also depends on the layout of the screen in view. |
| Time to first selection | 8.3 s | 0.50 | Moves. |
| Head yaw sd | 1.4° | 0.64 | Moves: how still the head is held varies more than anything about the eyes. |
| Contact radius | 24.2 pt | 0.00 | Uninformative: the hardware reports one of two values. |

Read as observations, with one person and seven short sessions:

- **The eye's rhythm is the stable part.** How long a fixation lasts and how many there
  are per minute barely move between sessions, while everything about the hands, the
  scrolling, the blinking and the head moves by a third to two thirds. If a fingerprint
  has a trait component, this is where to look first, and it is the component the phone
  measures best.
- **The state-like part is the hands and the head.** Press duration, scroll rhythm, list
  switching and head movement vary session to session for the same person on the same
  task. Whether that variation carries information about the session, tiredness, hurry,
  interest, or is noise, is exactly the Phase 4 and 5 question, and it cannot be asked
  of one person.
- **Contact radius is not a feature on this hardware.** It quantises to two values.
- **The quality filter matters more than any threshold in this document.** Without it the
  fixation rate's CV is 0.7, driven entirely by sessions where the gaze was off the screen.
  Every cross-session comparison must apply it, and every session must report its share.

The figure is `Data/derived/figures/stability.png`; the dashboard (`13-DESK-LINK.md`) shows
the same fingerprint live and lets two sessions be compared.

## 11. Phase 3 exit

The roadmap's exit is "a session has a meaningful fingerprint". A session now yields a
document of defined features with units and their thresholds, a one-page card a reader can
take in, a place in a cross-session table, and a live view while it records. The two
sessions in §9 and the seven in §10 read as descriptions of a person using a phone rather
than as sensor output. Exit met, 6 September 2026. What Phase 3 does not claim: that any
feature distinguishes people, or that any feature means anything about state. Those are
Phases 4 and 5, and they need participants.
