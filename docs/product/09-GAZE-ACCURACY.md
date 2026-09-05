# Gaze Accuracy: What Is Achievable, and What the Research Needs

This document exists because the sensing layer is the foundation of the project. If gaze
is not accurate enough, and we do not know *how* accurate it is, nothing built on top
means anything.

It answers three questions with evidence rather than hope:

1. How accurate is our current tracker, and is that a bug or a ceiling?
2. Could a private on-device gaze model do better?
3. Is the research viable at the accuracy we can actually reach?

## 1. Where we are

Our tracker is geometric. ARKit gives an eye position and a gaze direction derived from
its face model. We cast a ray, intersect it with the plane of the display, and correct the
angle with a per-person calibration.

Published accuracy for exactly this approach is **about 3.18°, or 1.44 cm on screen**
([Accuracy Assessment of ARKit 2 Based Gaze Estimation](https://link.springer.com/chapter/10.1007/978-3-030-49059-1_32)).

On an iPhone 15, 1 cm is about 60 screen points. So the literature says to expect roughly
**87 points of error**. That is not a defect in our implementation. It is the documented
ceiling of the public ARKit gaze signal.

Known limitations of that signal, from the same literature: ARKit's eye data is relative
to the face and does not correct for device movement, head rotation degrades it, and
blinks corrupt it. We now handle all three explicitly.

## 2. Could a learned model do better?

### Apple's own Eye Tracking is not available to us

iOS ships an accessibility Eye Tracking feature that is noticeably good. It has **no public
API**. Apple's developer forums are explicit that there is no supported way to read gaze
position from it, on iOS or visionOS
([Apple Developer Forums](https://developer.apple.com/forums/thread/766870)). We cannot use
it, and we should stop treating it as a benchmark we can match through the public SDK.

### What the research literature achieves

| Approach | Reported error | Note |
| --- | --- | --- |
| ARKit geometric, what we use | 1.44 cm | Public API ceiling |
| iTracker / GazeCapture CNN | ~2 cm | Seminal iPhone work, open |
| RGBDGaze, RGB + TrueDepth CNN | 1.89 cm | 16% better than its own RGB-only baseline of 2.26 cm |
| Google CNN + heavy personalisation | 0.46 cm | Not independently reproduced |
| Open reimplementation of the Google method | 1.79–2.04 cm | Community effort, released weights |

Sources:
[Eye Tracking for Everyone](https://arxiv.org/pdf/1606.05814),
[RGBDGaze](https://dl.acm.org/doi/10.1145/3536221.3556568),
[Accelerating eye movement research via accurate and affordable smartphone eye tracking](https://www.nature.com/articles/s41467-020-18360-5),
[gaze-track open reimplementation](https://dssr2.github.io/gaze-track/).

### The decisive finding

Google reports 0.46 cm, achieved with a convolutional network over eye crops plus a support
vector regression personalisation layer trained on roughly 100 calibration frames. Their
base model before personalisation was 1.92 cm.

The open reimplementation of that same method reaches **1.86–2.04 cm base, and only
1.79–1.87 cm after personalisation**. The community has not reproduced the headline figure.
It appears to depend on a proprietary training set at a scale we cannot match.

**So: adopting an open neural gaze model today would most likely make us worse than the
1.44 cm we already have.** Building and training our own on GazeCapture is a large machine
learning project with a realistic target of about 2 cm, which is still worse than our
current position.

This is the honest answer to "can we build a private on-device model and become very
accurate". We could build one. It would probably not be more accurate. The published
numbers do not support that bet.

## 3. Is the research viable at 1 to 1.5 cm?

Yes, and this is the part that matters most. Two arguments.

### Fixations average down, samples do not

Eye-tracking analysis does not use raw samples. It uses fixations. A fixation of 300 ms at
60 Hz is roughly eighteen samples of the same intended point. The random component of the
error shrinks with the square root of that count, leaving mostly the systematic component,
which is what calibration removes.

The number that matters for our research is therefore fixation accuracy, not per-frame
accuracy, and it is meaningfully better. Every accuracy claim in this project must state
which of the two it means.

### The screen is big enough for the regions we care about

An iPhone 15 display is 6.5 cm by 14.1 cm. The areas of interest in the experiment plan are
product image, price, rating, reviews, description and call to action. On a product page
these stack vertically and are each around 2 cm tall.

With 1 to 1.5 cm of error, vertical separation of stacked regions is workable and
horizontal separation into left and right halves is workable. Distinguishing two adjacent
words is not.

**Design rule for the study interface: no area of interest smaller than 2 cm in the
direction being measured, and no two areas of interest that must be told apart placed
closer than 2 cm.** This is a constraint on the interface design, not a defect in the
sensor. It goes in the experiment plan.

## 4. What we will actually do

In priority order.

### Now: extract everything the geometric approach has left

- **Fit calibration on every captured frame, not on one median per target.** Collapsing a
  burst to a single number throws away roughly thirty samples per target. Google's own
  result shows the personalisation layer needs around a hundred frames to work. We were
  fitting on eighteen numbers.
- **Report accuracy in degrees as well as points**, so our figures are directly comparable
  to the table above and we can tell whether we are at the ceiling or below it.
- **Report fixation accuracy separately from per-sample accuracy**, since the former is
  what the research depends on.
- Already done: angular rather than positional calibration, solving for the true camera
  position, gyroscope gating during device movement, blink gating, fixation-stability
  rejection of bad calibration targets, cross-validated model selection.

### Next: design the study for the accuracy we have

- Size areas of interest to the 2 cm rule above.
- Record the calibration quality with every session and exclude sessions that fail it.
- Report gaze findings at the level of regions and dwell, never at the level of words.

### Later, and only if the evidence demands it

Train an appearance-based model on GazeCapture and personalise it with the calibration
machinery we already have. Realistic target around 2 cm, so this is only worth doing if a
specific research question needs something the geometric approach cannot give. It is not
on the critical path.

## 5. What we are explicitly not claiming

We are not claiming to match Apple's Eye Tracking. It uses a private model we cannot
access. We are not claiming novelty in gaze estimation; everything here is established
method, in line with the Novelty direction stated in `01-RESEARCH-THESIS.md`. The novelty
of this project is the use of combined interaction signals as an input layer for agentic
and generative interfaces.

## 5a. Measured on device, 5 September 2026

> **Read with `10-MOTION-FUSION.md` sections 11 and 12.** The figures in this section are
> held-out error on the calibration grid. Later the same day the exported calibration
> frames showed that ARKit's camera axes were rotated relative to what the geometry
> assumed, that the eye-in-head rotation arrives at about a fifth of its true size, and
> that grid accuracy does not predict free viewing: measured against 43 taps as ground
> truth, the best model structure sits at about 225 points, and the sensor's free-viewing
> floor for this participant is currently 2° to 3°. The grid numbers below stand as what
> they are; they are not the accuracy of the study data.

iPhone 15, iOS 26.5.2, held in the hand, accuracy measured as the offset of each target's
mean gaze on targets held out of the fit.

| Build | Accuracy | Angle |
| --- | --- | --- |
| Three by three grid, fitted on 18 target medians | 98 pt | 2.56° |
| Three by four grid, fitted on every captured frame | **69 pt** | **1.62°** |

A 30% improvement, from two changes: fitting on every frame rather than one median per
target, which took the fit from eighteen numbers to several hundred, and a denser grid
matched to the shape of the display.

### Where that sits against the literature

| Error on screen | Method |
| --- | --- |
| 0.46 cm | Google 2020, never independently reproduced |
| **1.14 cm** | **This project** |
| 1.44 cm | ARKit geometric, published |
| 1.79 cm | Open reimplementation of the Google method |
| 1.89 cm | RGBDGaze, RGB plus TrueDepth neural model |
| 2.00 cm | iTracker / GazeCapture neural model |

We are better than every published open method, including the neural ones, and 20% better
than the published figure for the approach we are using. Only Google's unreproduced result
is ahead. This settles the question of whether to train our own model: there is no open
model to adopt that would not make us worse, and building one has a realistic target of
about 2 cm, which is behind where we already are.

### What this means for the study design

At 11.4 mm, with regions sized at twice the error:

| Direction | Separable regions |
| --- | --- |
| Down the screen | 6 |
| Across the screen | 3 |

Six vertical regions is exactly what a product page needs: image, title, price, rating,
reviews, call to action. **The sensing layer is good enough for the experiment as
planned.** The earlier 2 cm design rule can be relaxed to a 23 mm minimum region size,
measured in the direction being distinguished.

A caution learned the hard way here. Two runs were briefly reported as if they were the same
measurement, and the number appeared to get worse when nothing had. They were different
quantities. The field defines **accuracy** as the offset of the *mean* estimate while the
eyes rest on a target, and **precision** as the scatter around that mean. Judging every
individual 60 Hz frame is a third, stricter thing that no analysis is ever exposed to. All
three are now reported separately and labelled, and the headline is accuracy, because that
is what every published figure means.

### Eye laterality, resolved by measurement

Apple documents `eyeBlinkLeft` as the participant's anatomical left eye. On this device,
verified by a two-sided wink test with a cross-check, **`eyeBlink_L` responds to the
participant's right eye.** The documentation is wrong here, or at least the convention is
mirrored relative to it.

This is not cosmetic. Every `_L` and `_R` channel is affected, and any finding about one
eye against the other would have been silently inverted with nothing in the data to reveal
it. The app now measures the mapping rather than assuming it, refuses a result when the two
winks disagree, stores the verified mapping, and labels the physical eye in the interface.
Exports carry the verified side alongside the raw ARKit key.

**Rule: no session is valid until the eye label check has been run on that participant.**

## 6. The Neural Engine on this device

The test device reports as `iPhone15,4`, which is the base iPhone 15. It runs the A16
Bionic, which includes a **16-core Neural Engine rated at about 17 trillion operations per
second**. So yes, there is substantial dedicated machine learning silicon available, and it
is idle.

What it is genuinely good for here:

- **Running a gaze model at 60 Hz for free.** A small convolutional network over eye crops
  is a few million operations per frame. On the Neural Engine that is nothing, and it costs
  far less battery and heat than running the same thing on the CPU or GPU. The hardware is
  not the obstacle to an appearance-based tracker. The absence of a model that beats 1.44 cm
  is the obstacle, as set out in section 2.
- **Vision framework requests already use it.** Face landmark detection and any future
  pupil localisation run on the Neural Engine automatically.
- **On-device personalisation.** Core ML supports updating a model on device with
  `MLUpdateTask`. Since the entire accuracy story in the literature turns on
  personalisation rather than on the base model, the interesting use of this silicon is
  fitting a small per-participant head on the Neural Engine from calibration data, not
  running a bigger general model.
- **Later phases.** Fixation and saccade classification, and fingerprint feature extraction,
  are both cheap enough to run continuously on device, which keeps raw data local and
  satisfies the privacy principle in `06-RESEARCH-PRINCIPLES.md`.

One constraint worth knowing before Phase 6 and 7 are planned. **Apple Intelligence and the
on-device Foundation Models framework do not run on this phone.** They require an A17 Pro
or newer, meaning iPhone 15 Pro and above. The base iPhone 15 is excluded. When the agent
and generative UI stages arrive, they will need either a newer device or a server-side
model, and that choice should be made deliberately rather than discovered late.

## 6. Sensor roadmap after gaze is stable

Agreed order, to begin once the sensing layer meets its exit criterion:

1. **Touch contact area and duration.** `UITouch` exposes major radius and force, which
   together give a usable proxy for how firmly and deliberately something was pressed.
2. **Scroll velocity and reversals.** Direction changes and deceleration are strong
   behavioural markers of searching versus reading.
3. **Ambient light**, from ARKit's light estimate, as a tracking-quality covariate. Pupil
   size and tracking reliability both depend on it, and it explains variance that would
   otherwise look like participant difference.
4. **Paired Apple Watch heart rate variability.** The strongest arousal signal available on
   this platform, but it needs a companion watchOS app, so it is a separate milestone.

Already in use: the gyroscope and accelerometer, both for rejecting frames captured while
the phone was moving and as a measure of hand steadiness. How they are used, and why the
gate judges displacement in millimetres rather than angular velocity, is set out in
`10-MOTION-FUSION.md`, which also records that ARKit's own device motion tracking had
been switched off and is now on.
