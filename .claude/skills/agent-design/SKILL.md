---
name: agent-design
description: Design the agent that reads fingerprint features and decides whether and when to intervene in the UI. Use only after fingerprint features have demonstrated predictive value in a study. Covers decision policy, thresholds, safety, and logging of decisions. Priority: later.
---
# Agent design (later stage)

**Gate:** do not start until `Research/findings.md` shows a fingerprint feature with a
confidence interval that excludes zero for predicting friction, and an evaluation function exists.

## Shape of the agent

- Input: a rolling window of fingerprint features (dwell, revisits, hesitation, tracking-loss
  share) plus the current screen and task state. Never raw camera data.
- Output: one decision from a small, enumerated set: `none`, `highlight_target`,
  `show_comparison`, `simplify_screen`, `offer_help`. Each mapped to a concrete UI change.
- Policy: start with **rules with thresholds** derived from the study data. A learned policy
  comes only after rules have been evaluated.
- Cadence: decide at most once every N seconds and never during a saccade or scroll.

## Log every decision as an event

`agent_decision` with the features it saw, the rule that fired, the action, and the timestamp.
Also log `agent_suppressed` when a rule fired but a cooldown or safety check blocked it.
Without this the study cannot attribute outcomes to decisions.

## Safety and honesty

- Interventions must be explainable to the participant in one sentence.
- No inference of emotion or intent is stored or displayed. The agent reacts to behaviors
  ("you revisited the price three times") not states ("you seem confused").
- Always keep a control arm with the agent disabled.
- Define the failure mode: a wrong intervention costs the participant time. Measure it.

## Where it lives

`InteractionFingerprintPackage/Sources/InteractionFingerprintFeature/Agent/` as pure Swift,
testable with recorded sessions replayed offline. Replay-based tests are the primary test suite.

## Related
`generative-ui`, `llm-ai-evaluation`, `experimental-thinking`, `privacy-responsible-ai`.
