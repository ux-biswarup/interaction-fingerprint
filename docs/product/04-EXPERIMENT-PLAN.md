# Experiment Plan

## Initial domain
E-commerce, because it provides a measurable decision outcome.

Build a fictional shopping experience rather than integrating a real commercial service.

## Prototype
Product images, price, rating, reviews, description and CTA.

Example task:

> Find a product you would consider buying under a specified budget.

## Conditions

### Control
Traditional interaction analytics:
- taps
- scroll
- dwell
- product selection

### Fingerprint
Control signals plus:
- gaze
- attention
- eye signals
- selected facial signals
- interaction patterns

### Adaptive
Fingerprint + agent + predefined interventions.

## Example interventions
- Price attention → explain value
- Repeated product switching → offer comparison
- High review attention → surface relevant verified-buyer concerns

## Metrics
Behavioral: task time, task success, products explored, backtracking, comparisons, selection/conversion.

Self-report: decision difficulty (1–5), confidence (1–5).

Fingerprint: dwell, gaze transitions, attention distribution, revisits, hesitation, selected eye/facial signals.

## Initial study
8–12 participants for exploratory validation. This is not intended to establish population-level statistical claims.

## Central test
> Does the additional signal explain user difficulty or decision behavior better than explicit interaction data alone?


---

## Protocol, decided 6 September 2026: a repeated-measures study of a few people

The 8–12 participant exploratory study above is not available: the researcher is the main
participant, with two or three others if they can be found. The design changes to match.
It becomes a **single-subject repeated-measures study, replicated on two or three people**,
run over ten days with the conditions set on purpose. It cannot establish anything about a
population and does not try to. It can answer three things nobody has asked of this sensor:

1. Which features hold still for one person across days, not just across one afternoon.
2. Which features move when the situation is changed deliberately, and in which direction,
   measured against how much the same feature moves from day to day under a fixed condition.
3. Whether the sensing itself holds across postures, distances and lighting without
   recalibration.

With more than one participant, a fourth: whether the features that hold still within a
person differ between people, which is the definition of a fingerprint.

### Conditions

Four factors, each varied on purpose, one at a time, so a change has one cause.

| Factor | Levels | How it is set |
| --- | --- | --- |
| Task | **browse**: look around, nothing to find. **search**: find the cheapest product rated 4 or more and add it to the basket. | The app reads the prompt from the screen, word for word; recording starts on Begin. |
| Pace | **relaxed**: no clock shown. **hurried**: a visible countdown. | Limits: browse 90 s relaxed, 45 s hurried; search 120 s relaxed, 45 s hurried. Search also ends on the selection. |
| Posture | sitting, lying back, standing | Chosen per day, set in the study block screen. |
| Light | daylight, lamp | Chosen per block, set in the study block screen. |

The right answer to the search task is computed from the catalogue by the app (rating
≥ 4.0, then cheapest: the Lumen Desk Lamp at £74; the cheapest product overall, the kettle
at £46, is rated 3.8 and is the distractor). The app writes a `task_result` event with
correctness, the selection and whether time ran out.

### Schedule

Ten days. Two blocks a day, morning and evening. A block is the four task × pace sessions
in an order that rotates with the day so each session is first, second, third and fourth
equally often over the study. Posture changes by day (cycle sitting, lying back, standing);
light changes by block (daylight in the morning, lamp in the evening, or as the room
allows). Sessions are one to two minutes; a block takes under six minutes; the whole study
is about two hours of a participant's time spread over ten days.

Calibrate once at the start of the study and not again unless the dashboard shows a
session failing the quality gate; if that happens, recalibrate and note the day, because
calibration drift over ten days is itself a finding.

### What the app does

The **Study block** button on the instrument screen opens the plan: participant label
(never a name), posture, light, and the four sessions in today's order with ticks for the
ones already done. Starting one shows the prompt, begins recording on Begin, runs the
countdown when hurried, ends by itself at the limit or on the selection, stores the
condition in the session record, and returns to the plan for the next. The desk receives
everything live and the recordings land in `Data/` by themselves (`13-DESK-LINK.md`).

### What the analysis does

`Analysis/fingerprint_report.py` adds, when conditioned sessions exist: `fingerprints_by_condition.csv`;
the standardised difference between the levels of each factor for every feature (`d`, the
second level minus the first in units of the within-level spread), drawn in
`figures/effects.png` beside the day-to-day spread of the same feature under a fixed
condition, which is the bar an effect has to clear; and search-task outcomes by pace and
participant. Only sessions passing the quality gate of `12-FINGERPRINT-FEATURES.md` §10
count.

### Reading the result

- A feature with low day-to-day spread and no factor effect is a **trait candidate** for
  that person. Between participants, the test is whether those features differ.
- A feature that moves with pace or task by more than it moves between days is a **state
  feature**. Whether the state is anything more than "hurried" is a Phase 5 question.
- A feature that moves with posture or light is a **sensing artefact** until shown
  otherwise, and goes to the sensing backlog, not the fingerprint.
- Task success by pace is the behavioural anchor: if hurry does not cost accuracy or time,
  the manipulation did not take.

### Participants

Two or three people known to the researcher. Each: one calibration, the wink test, and as
many blocks as they will give, two a day for a few days being enough for the within-person
questions. Consent covers exactly what is stored (no images, observable signals and screen
coordinates only, labelled by a code, kept on the researcher's machines, never leaving the
local network), and the desk switch is shown to them. The control condition of the original
plan, analytics without gaze, is realised in analysis by dropping the gaze features, not by
a separate arm.

### What this design cannot say

Anything about people in general. Anything about emotion or intent. Whether a fingerprint
would generalise to another app or another phone. It says what one to four specific people's
observable behaviour does across days and conditions on one phone, measured honestly.
