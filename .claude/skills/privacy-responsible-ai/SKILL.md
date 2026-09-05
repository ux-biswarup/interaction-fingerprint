---
name: privacy-responsible-ai
description: Define what the project may and may not infer about users from face and gaze data, and enforce it in code, schema, study materials, and language. Use throughout: any new signal, feature name, model, or UI copy passes through this. Priority: throughout.
---
# Privacy and responsible AI

## Non-negotiables

- **Observable, not inferred.** The dataset and the code store measurements (`eyeSquintLeft`,
  `dwellMs`, `revisitCount`). No field, variable, or label may name an emotion, intent, or trait
  (`confused`, `frustrated`, `interested`, `attention_span`). Reject such names in review.
- **No biometrics for identity.** Face geometry, mesh vertices, or anything that could identify
  a person is never stored. Blend shapes and gaze points are fine; the face mesh is not.
- **No images or video.** Ever. Not even for debugging. Use the on-screen gaze dot instead.
- **Session UUIDs only.** The link between a UUID and a participant lives outside the repo, on
  paper or in an encrypted file, and is destroyed after the study.
- **Local by default.** V0 data does not leave the device except by manual export by the
  researcher. No analytics SDKs.
- **Deletable.** A participant can delete their session from the app; the researcher deletes
  exports on request. Log deletions.

## What we may infer, and how we say it

We may compute behavioral aggregates (dwell, revisits, hesitation, backtracking) and test whether
they predict behavioral outcomes (abandonment, errors). We describe results as
"participants who revisited the price more often abandoned more often", never
"the system detects confusion".

## Apple platform rules that apply

ARKit face data may be used only for the app's core feature, not for advertising or profiling,
and not shared with third parties. A privacy policy is required for distribution. Keep it in
`Research/privacy-notice.md`.

## Review checklist for any change

- New signal: is it in `Research/hypotheses.md` with a hypothesis? Is it observable?
- New field or feature: does the name describe a measurement? Units documented?
- New model or agent: can its decision be explained as a behavior, not a state?
- New UI copy: does it avoid telling users what they feel?
- Data path: does anything leave the device or land in git?

## Related
`ios-camera-privacy`, `experimental-thinking`, `agent-design`.
