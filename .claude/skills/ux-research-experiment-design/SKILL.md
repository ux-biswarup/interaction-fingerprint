---
name: ux-research-experiment-design
description: Design a credible small user study for the Interaction Fingerprint: hypotheses, tasks, conditions, counterbalancing, consent, pilot protocol, and what to log. Use when writing anything in Research/ or planning a study session. Priority: next.
---
# UX research and experiment design

## Protocol document (`Research/protocol.md`)

1. Research question and one primary hypothesis (see `experimental-thinking`).
2. Participants: who, how many, inclusion criteria (Face ID device compatible, no eye conditions
   that affect tracking, consent to camera-based tracking). Target n = 8 to 12 for the pilot.
3. Conditions: **control** (static product UI) and **fingerprint-driven** (adaptive). In V0 there
   is only control; the study is observational to build the dataset. Say so.
4. Tasks: concrete and repeatable. "Find a laptop under 1000 euro with at least 16 GB RAM and add
   it to the cart." Three to five tasks, each 30 to 90 seconds.
5. Design: within-subject, counterbalanced task order (Latin square). Record the order.
6. Measures: primary outcome, secondary outcomes, and the raw signals captured. Each with unit
   and the exact computation in `Analysis/fingerprint/features.py`.
7. Procedure with timings: consent, calibration, practice task, tasks, short interview, debrief.
8. Data handling: session UUID only, storage location, deletion on request, retention period.

## Consent and ethics

- Written consent explaining camera use, that no video is stored, what numeric signals are
  stored, and the right to withdraw. Template in `Research/consent.md`.
- If affiliated with an institution or company, check whether ethics or works-council approval is
  required before recruiting.

## Session checklist (`Research/session-checklist.md`)

phone charged and on Do Not Disturb, same lighting, phone on a stand or held at a marked
distance, calibration residual below the threshold, practice task done, timer started,
observer notes taken with timestamps, export verified before the participant leaves.

## Observer notes

Note timestamps (wall clock) of anything unusual: participant looked away, adjusted glasses,
asked a question. These become annotation events during analysis.

## Avoiding the usual traps

- Demand effects: do not tell participants which condition is "smart".
- Novelty: include a practice task so first-exposure effects are not measured.
- Layout confound: control and treatment must differ only in the manipulated element.
- Learning: counterbalance and test for order effects.

## Related
`basic-statistics`, `eye-tracking-concepts`, `privacy-responsible-ai`.
