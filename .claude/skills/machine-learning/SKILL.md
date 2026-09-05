---
name: machine-learning
description: Find patterns in Interaction Fingerprints and test whether they predict friction or abandonment: feature tables, leakage-free cross-validation grouped by participant, baselines, interpretable models first. Use only after a labeled dataset exists. Priority: next.
---
# Machine learning on fingerprints

## Precondition

A dataset of at least a few dozen sessions with a **behavioral label** that was defined before
collection: task abandoned, task failed, backtracked more than N times, self-reported difficulty.
No label, no model. Do not invent labels from the same gaze features you train on.

## Workflow

1. Build a tidy feature table: one row per (session, task), columns from
   `Analysis/fingerprint/features.py`. Save to `Data/derived/features.parquet`.
2. Baseline first: majority class, then logistic regression on two or three hand-picked features
   (dwell on price, revisit count, hesitation). Report balanced accuracy and AUROC with CIs.
3. Cross-validate with `GroupKFold` grouped by **participant**. A participant in both train and
   test leaks identity.
4. Only then try gradient boosting or small tree ensembles. If they do not beat the two-feature
   logistic model by a meaningful margin, keep the simple model.
5. Interpret: coefficients, permutation importance, partial dependence. The goal is to learn
   which observable behaviors carry signal, not to ship a black box.
6. Write results in `Research/findings.md` with n, features used, CV scheme, and the
   confidence intervals.

## Pitfalls specific to this data

- Sessions differ in length. Use rates and shares, not counts.
- Tracking loss correlates with head movement, which correlates with frustration. Include
  tracking-loss share as a feature and as a covariate; check whether "the model" is only
  learning tracking loss.
- Tiny n: expect wide CIs. Report them. Prefer leave-one-participant-out CV.
- Class imbalance: abandonments are rare. Use stratified splits and report per-class recall.

## Tools

`scikit-learn` (`LogisticRegression`, `GroupKFold`, `permutation_importance`), `shap` optionally.
Keep notebooks reproducible: fixed seeds, `requirements.txt` pinned.

## Related
`basic-statistics`, `time-series-analysis`, `python-pandas`, `experimental-thinking`.
