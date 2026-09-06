---
name: praxist
description: PRAXIST: automating hypothesis, experiment, and evaluation loops on top of the fingerprint dataset. Use only after a working dataset and a measurable evaluation function exist. Covers what to automate, what stays manual, and prerequisites. Priority: later.
---
# PRAXIST (later stage)

**Gate from the setup guide, section 12:** do not introduce PRAXIST until there is a working
dataset and a measurable evaluation function. Both must be checked into this repo first:
`Data/derived/features.parquet` reproducible from raw exports, and an evaluation script in
`Analysis/fingerprint/evaluate.py` that returns the primary metric for a given variant.

## What the loop automates

hypothesis proposal from the feature table → experiment specification (which variant, which
outcome, which n) → offline replay or simulation where possible → evaluation with the fixed
metric → written summary appended to `Research/findings.md`.

## What stays manual

recruiting and running participants, consent, any change to the primary outcome, any change to
what signals are captured, and the decision to move to the next milestone. The loop proposes;
a person decides.

## Interfaces the loop depends on

- Stable feature definitions with units (`docs/product/12-FINGERPRINT-FEATURES.md`).
- A CLI entry point: `python -m fingerprint.evaluate --variant <id> --sessions <glob>`.
- Deterministic outputs given the same inputs and seed.
- Every automated run recorded with git SHA, inputs, and outputs.

## Before writing any PRAXIST integration

Write the first three loop iterations by hand in `Research/findings.md`. If the hand-run loop
does not produce useful hypotheses, automation will not either.

## Related
`experimental-thinking`, `llm-ai-evaluation`, `machine-learning`.
