---
name: llm-ai-evaluation
description: Measure whether agent or LLM decisions in this project are actually useful: offline replay evaluation, decision-quality metrics, human review rubrics, and guarding against evaluating on the data that trained the thresholds. Priority: later.
---
# LLM / AI evaluation (later stage)

## Evaluate decisions, not vibes

A decision is good if it leads to a better pre-registered outcome than no decision would have,
for that participant, at that moment. Because we cannot observe the counterfactual, we use:

1. **Offline replay.** Feed recorded sessions through the agent and record where it would have
   intervened. Ask: would the intervention have been appropriate given what happened next
   (abandonment, backtrack, long hesitation)? Compute precision and recall of "friction moments".
2. **Controlled study.** Agent on versus agent off, same tasks, within-subject. Primary outcome
   from the protocol. This is the only evaluation that counts as evidence.
3. **Human review.** Two reviewers rate a random sample of decisions with a written rubric
   (`Research/decision-rubric.md`): appropriate, harmless but unnecessary, harmful. Report
   agreement (Cohen's kappa).

## Metrics to keep

intervention rate per minute, precision on friction moments, time-to-intervention after the
first friction signal, harm rate from the rubric, and the primary study outcome. Track them per
model or rule-set version in `Research/eval-log.md`.

## Leakage rules

- Thresholds tuned on sessions A must be evaluated on sessions B from different participants.
- The rubric is written before reviewers see agent outputs.
- Any LLM prompt used for judging is versioned in the repo and evaluated against the human
  ratings before being trusted as a judge.

## Related
`agent-design`, `basic-statistics`, `experimental-thinking`.
