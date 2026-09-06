# Interaction Fingerprint

**Open-source iPhone eye tracking and interaction research kit.** An iOS app records where a person looks, how their eyes and brows move, how they hold the phone and what they tap and scroll, using the TrueDepth camera through ARKit. A Python toolkit turns each session into an *Interaction Fingerprint*: a set of defined, unit-bearing features of observable behaviour. A desk dashboard on your Mac shows it live and keeps the record. No images are ever stored, and nothing is ever labelled as an emotion.

Built and documented in the open as a research project by [Biswarup Mondal](https://github.com/ux-biswarup). Everything here, including the dead ends, is written down.

---

## What you get from this repository

| If you are | You get |
| --- | --- |
| A UX researcher | A working iPhone gaze and interaction recorder you can calibrate in two minutes, with a live dashboard and honest accuracy figures measured against what people actually tap. |
| An iOS developer | A Swift 6 / SwiftUI / ARKit codebase that shows how to get *usable* gaze out of a phone: coordinate frames, calibration, a Core ML eye model, a local-network streaming link, all tested. |
| A data scientist | A pandas pipeline from raw event stream to fixations, dwell, transitions, hesitation and cross-session stability, with every feature defined before it was coded. |
| Someone deciding whether phone eye tracking is good enough for their study | The numbers, the method that produced them, and what did not work. See [How accurate is it](#how-accurate-is-iphone-gaze-tracking). |

## What is an Interaction Fingerprint?

A structured description of how one person interacts with a screen over time, built only from things a phone can observe:

- **Explicit:** taps, scrolls, back, selections, and how each tap was made (press duration, contact size).
- **Behavioural:** dwell per area of interest, revisits, gaze transitions, time from first look to tap, hesitation, list switching, time to decision.
- **Perceptive:** gaze position at 60 Hz, fixations and saccades, blink rate, nine eye and brow blend-shape coefficients, head pose, viewing distance.
- **Contextual:** screen, product, task, study condition, phone tilt and motion, ambient light.

The rule that governs the whole project: **record `eyeSquint_L = 0.42`, never `confused = true`.** Observations are stored; interpretations, if any, are derived separately and labelled as such. The research question is whether such a fingerprint carries information that click-and-scroll analytics miss, and whether it is stable enough within a person, and different enough between people, to deserve the name. See [01-RESEARCH-THESIS.md](docs/product/01-RESEARCH-THESIS.md) and [02-INTERACTION-FINGERPRINT.md](docs/product/02-INTERACTION-FINGERPRINT.md).

## How accurate is iPhone gaze tracking?

This is the question most visitors arrive with, so here is the answer we measured, on an iPhone 15 held in the hand at 30–40 cm.

| Gaze source | Calibration grid, held out | Free viewing, gaze to the tapped element |
| --- | --- | --- |
| ARKit's own eye transforms (`lookAtPoint`) | 79–120 pt | 256 pt |
| Pupil landmarks from Apple Vision | 41–62 pt | 60 pt |
| **Learned eye model** (this repo, Core ML) | **22 pt (0.6°)** | **28 pt median, 4.6 mm** |

1 pt is 0.166 mm on this display. ARKit reports the eyes' rotation within the head at about a fifth of its true size, which is why raw `lookAtPoint` gaze is poor for screen work. A small convolutional network trained on the public [MPIIFaceGaze](https://www.mpi-inf.mpg.de/departments/computer-vision-and-machine-learning/research/gaze-based-human-computer-interaction/its-written-all-over-your-face-full-face-appearance-based-gaze-estimation) dataset and run on the phone's own eye crops recovers it at full gain, and after a two-minute calibration puts the gaze on the element a person is about to tap in most cases. The full story, including the rotated camera frame, the mirrored image, why the calibration grid over-promises, and what "gaze-before-tap" measures, is in [09-GAZE-ACCURACY.md](docs/product/09-GAZE-ACCURACY.md), [10-MOTION-FUSION.md](docs/product/10-MOTION-FUSION.md) and [11-LEARNED-EYE-MODEL.md](docs/product/11-LEARNED-EYE-MODEL.md).

## What we have found so far

With one person recorded across a day, seven trustworthy sessions ([12-FINGERPRINT-FEATURES.md §10](docs/product/12-FINGERPRINT-FEATURES.md)):

- **The eye's rhythm is the stable part.** Fixation duration (median 184 ms) and fixation rate (168 per minute) vary by about 10% between sessions a day and two calibrations apart.
- **The hands and the head are the state part.** Press duration, scroll rhythm, list switching, blink rate and head movement vary by a third to two thirds for the same person on the same task.
- **The fingertip is not ground truth.** People look at a row's label and tap its right end; measuring gaze against the tapped element rather than the fingertip halved the apparent error. This matters for anyone validating gaze with taps.
- **A quality gate matters more than any threshold.** A session with under 40% of tracked time in fixations was recorded through a bad calibration and describes the calibration, not the person.

These are observations about one person. What holds across people is the open question, and the next phase is designed to ask it honestly: a ten-day repeated-measures study with task, pace, posture and light set on purpose, replicated on a few participants ([04-EXPERIMENT-PLAN.md](docs/product/04-EXPERIMENT-PLAN.md)).

## What is in the box

```text
InteractionFingerprintPackage/   Swift package: all app code, 97 unit tests
  Tracking/      ARKit face session, display frame, calibration, gaze model, motion gate,
                 Vision pupil landmarks, Core ML eye model (EyeInHead.mlmodelc)
  Instrumentation/ event recorder, touch observer, areas of interest, desk link (Bonjour + WebSocket)
  Shop/          the study stimulus, a small product catalogue with instrumented areas
  Views/         instrument screen, calibration, camera mirror, study block, recording chrome
  Models/        the event schema (Codable), session record, study conditions
Analysis/                        Python: 36 tests
  fingerprint/   load, geometry, gaze model replay, features, figures, stability, conditions
  eyemodel/      MPIIFaceGaze reader, EyeInHeadNet, training, evaluation, Core ML export
  dashboard/     the desk: receives sessions from the phone, serves the live dashboard
docs/product/                    the research record, numbered 00–13
Data/                            recordings, never committed
```

## Quick start

You need a Mac with Xcode 26 and an iPhone with Face ID; ARKit face tracking does not run in the Simulator.

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your development team. Open `InteractionFingerprint.xcworkspace`, select the phone, run. Details: [docs/DEVICE_INSTALL.md](docs/DEVICE_INSTALL.md).
2. On the phone: check eye labels (a wink test), calibrate (twelve targets at two distances, about two minutes), record a session in the shop or start a study block.
3. On the Mac, start the desk. The phone finds it on your Wi-Fi by itself, streams every session live and uploads anything recorded while away. Recordings land in `Data/` as the same files the app exports.

```bash
pip3 install --user -r Analysis/requirements.txt
python3 Analysis/dashboard/server.py --open        # dashboard at http://localhost:8765
```

4. Analyse:

```bash
python3 Analysis/evaluate_gaze.py Data/calibration_<t>.json Data/session_<id>.jsonl   # judge a calibration against taps
python3 Analysis/fingerprint_session.py Data/session_<id>.jsonl                       # one session's fingerprint
python3 Analysis/fingerprint_report.py                                                # cards, cross-session table, stability, condition effects
```

Feature definitions with units: [12-FINGERPRINT-FEATURES.md](docs/product/12-FINGERPRINT-FEATURES.md). Data schema: [05-DATA-SCHEMA.md](docs/product/05-DATA-SCHEMA.md). The desk and its protocol: [13-DESK-LINK.md](docs/product/13-DESK-LINK.md).

## How it works, briefly

- **Sensing.** ARKit's face anchor gives head pose at full strength and eye rotation at a fifth of its size. The app records both, plus Vision's pupil landmarks and the learned model's estimate, on every frame, so any session can be re-mapped offline with a better model later. Gaze on screen is head direction plus a calibrated correction of the eye-in-head signal; the calibration fits only the correction, and refuses fits whose gain is not positive.
- **Instrumentation.** Every gaze sample is attributed on the phone to a semantic area of interest declared in SwiftUI, and the raw coordinate is kept too. Taps carry the frame of the element they hit. A motion gate flags frames where the phone moved more than the tracker's accuracy.
- **Features.** Dispersion-threshold fixations with loose thresholds suited to the sensor; dwell and revisits from fixations rather than per-sample attribution, which flickers at borders; hesitation as the gap between the last fixation on an element and the tap on it.
- **Study.** Conditions (task, pace, posture, light) are set in the app and stored in the session; effects are measured against the day-to-day spread of the same feature under a fixed condition.

## Privacy

The camera image is processed on the device by ARKit and never leaves it. The app stores numbers: coordinates, angles, coefficients, timings. No video, no photographs, no face mesh. Recordings stay in `Data/` on the researcher's machines; the desk link works only on the local network. Participants are labelled by a code. The project's principles are in [06-RESEARCH-PRINCIPLES.md](docs/product/06-RESEARCH-PRINCIPLES.md). Before this app is given to anyone outside the research team it needs a consent flow, a privacy notice and, in Europe, a data protection assessment; that work is listed, not done.

## Status and roadmap

Phases 0–3 are complete: the sensing gate passed against 2 cm, the instrumentation gate passed, and a session yields a meaningful fingerprint with a live dashboard. Phase 4, the repeated-measures study, is built into the app and ready to run. Phases 5–7 (modelling, an adaptive prototype, an agent that decides whether to intervene) come after there is data from more than one person. The living plan with dates and evidence: [07-ROADMAP.md](docs/product/07-ROADMAP.md).

## Citing and licences

Code is MIT ([LICENSE](LICENSE)). The bundled eye model was trained on MPIIFaceGaze, which is CC BY-NC-SA 4.0: research use only, and any publication should cite Zhang, Sugano, Fritz and Bulling, *It's Written All Over Your Face*, CVPRW 2017. If you use this repository in research, cite it as:

> Mondal, B. (2026). *Interaction Fingerprint: an open iPhone gaze and interaction research kit.* https://github.com/ux-biswarup/interaction-fingerprint

## Keywords

iPhone eye tracking, ARKit gaze tracking accuracy, TrueDepth gaze estimation, appearance-based gaze estimation on mobile, Core ML eye model, MPIIFaceGaze, gaze calibration iOS, fixation detection I-DT, areas of interest SwiftUI, behavioural biometrics UX research, interaction analytics beyond clicks, gaze-before-tap validation, open-source eye tracking iOS, perceptive interfaces, adaptive generative UI research.
