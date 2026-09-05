---
name: experimental-thinking
description: Frame every feature, signal, and analysis in this project as a testable hypothesis. Use whenever deciding what to capture, what to build next, what counts as evidence, or whether a result means anything. Priority: throughout, and before any other skill.
---
# Experimental thinking

The most important skill in this project is not coding. It is deciding what signal we capture,
what hypothesis it tests, what would count as evidence, and what would falsify the idea.

## Before adding any signal, feature, or analysis, answer in writing

1. **Hypothesis.** One sentence. "Users who revisit the price element more than twice are more
   likely to abandon the product page." Not "capture gaze".
2. **Signal.** Which observable measurement tests it? Where does it come from (ARKit blend shape,
   gaze point, tap event, scroll offset)? At what rate?
3. **Evidence.** What result would support the hypothesis? Give a number or a comparison, e.g.
   "dwell on price is at least 30% longer in abandoned sessions than in completed ones".
4. **Falsification.** What result would make us drop the idea? If nothing could, it is not a
   hypothesis and should not be built yet.
5. **Confounds.** What else could produce the same signal? Lighting, device angle, reading speed,
   fatigue, novelty of the UI.
6. **Cost.** What does capturing it cost in privacy, battery, storage, and participant burden?

Record the answers in `Research/hypotheses.md` before writing code. Link commits to the hypothesis.

## Rules that follow from this

- Capture observable signals. Never store interpretations. `eyeSquintLeft = 0.42`, not `confused = true`.
- Prefer one clean signal with a clear hypothesis over ten signals "just in case".
- A baseline is mandatory. Every fingerprint-driven claim is compared against a control condition.
- Define the evaluation function before the intervention exists. If we cannot measure "better",
  do not build the adaptive UI, agent, or generative UI yet.
- Small n is fine for V0 if the protocol is repeatable. Say the n. Never hide it.
- Negative results are results. Write them down in `Research/findings.md`.

## Milestone gate

Do not move from "raw signals" to "fingerprint features" to "adaptive UI" to "agent" until the
previous stage has a working dataset and a measurable evaluation. See section 12 of
`docs/INTERACTION_FINGERPRINT_XCODE_SETUP.md`.

## Related skills
`ux-research-experiment-design`, `basic-statistics`, `privacy-responsible-ai`,
`fingerprint-data-modeling`.
