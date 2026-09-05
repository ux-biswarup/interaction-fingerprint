---
name: basic-statistics
description: Compare control versus fingerprint-driven conditions with appropriate statistics: effect sizes, confidence intervals, paired versus independent tests, multiple comparisons, and power for small user studies. Use when interpreting any numeric result from Analysis/. Priority: next.
---
# Basic statistics for the user study

## What we compare

Control experience versus fingerprint-driven experience, on outcomes defined **before** the
study in `Research/protocol.md`: task completion time, error or backtrack count, dwell on
key elements, self-reported effort. Each outcome has one pre-registered primary test.

## Defaults for this project

- Report **effect size with a 95% confidence interval** first, p-value second. Cohen's d for
  means, Cliff's delta for skewed durations, risk difference for completion rates.
- Durations (dwell, hesitation, completion time) are right-skewed. Use medians, log-transform,
  or non-parametric tests (Mann-Whitney U, Wilcoxon signed-rank). Plot the distribution first.
- Within-subject (each participant does both conditions, counterbalanced order) is far more
  powerful for small n. Use paired tests and check for order effects.
- Many gaze features per participant means many comparisons. Pre-register one primary outcome;
  treat the rest as exploratory and apply Benjamini-Hochberg if reporting them.
- Bootstrap CIs (`numpy` resampling, 10,000 draws) are fine and easy to explain.
- Power: with n = 12 within-subject you can detect roughly d = 0.9 at 80% power. Say this in the
  protocol. Do not claim to detect small effects with a pilot.

## Unit of analysis

The participant, not the gaze sample. Sixty samples per second are not independent observations.
Aggregate to one value per participant per condition before testing.

## Reporting template (put in `Research/findings.md`)

```text
Outcome: median task time
Control: 41.2 s (IQR 33 to 55), n = 12
Fingerprint: 36.8 s (IQR 30 to 47), n = 12
Paired difference: -4.1 s, 95% CI [-9.0, 0.6], Wilcoxon p = 0.08
Interpretation: direction consistent with hypothesis; CI includes zero; not conclusive at this n.
```

## Python

`scipy.stats` (`wilcoxon`, `mannwhitneyu`, `ttest_rel`), `statsmodels` for mixed models if
sessions are nested in participants, `pingouin` for effect sizes with CIs.

## Related
`ux-research-experiment-design`, `python-pandas`, `experimental-thinking`.
