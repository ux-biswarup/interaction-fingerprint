# Phase 1b: A Learned Eye Model

Decided 6 September 2026. Natural, hand-held phone use is the premise of the research and
is not negotiable (`00-PROJECT-CONTEXT.md`). Under that premise the sensing layer has a
measured problem: ARKit reports the eyes' rotation within the head at a fifth to a third of
its true size, with a gain that shifts between distances and postures, and no model on its
outputs gets free-viewing error below about 6 cm (`10-MOTION-FUSION.md` §14). The head
direction and the eye position from ARKit are good. The eye-in-head term is the weak link,
and this document is the plan to replace it.

## 1. What is being replaced, and what is kept

```
gaze = head direction (ARKit, kept)
     + f( eye-in-head rotation )          ← this term
projected from the eye position (ARKit, kept) onto the display (geometry, kept)
```

Everything outside `f` stays. The calibration machinery, the two-distance design, the
standardised and bounded fit, the export of frames, the tap-based ground truth: all of it
applies unchanged to a better eye-in-head estimate. The project is narrower than "build a
gaze tracker". It is "estimate one angle better than ARKit does".

## 2. Two candidates, in order

### 2a. Pupil landmarks (one day, in progress)

Apple's Vision framework returns a pupil point and an eye-opening contour per eye. The
pupil's offset from the centre of the opening, in units of the opening's width, is the
eye-in-head rotation observed directly, and it is head-independent by construction because
the opening moves with the head. This is the participant's "optical mouse" idea in the form
that can work: relative motion of the pupil across a reference that moves with the head,
pinned to absolute positions by the calibration.

It is now computed on every frame (`PupilDetector`), recorded in the calibration file and on
every gaze row (`pupilU`, `pupilV`), and offered to the fitter as its own source. The
question it must answer, measured exactly as the transforms and blend shapes were in
§14: what fraction of the true eye rotation does it report, and how consistent is that
fraction across distances and postures. A fraction near one with a stable gain ends the
problem. A fraction like ARKit's does not, and the plan continues to 2b.

Known limits going in. Vision's landmarks are 2D and detected on the colour image, with no
published accuracy for the pupil point. Landmark-based gaze on phones sits around 3° to 4°
in the literature, which would be a gain over 6 cm but not a solution.

### 2b. A convolutional eye-in-head model (weeks)

**Target.** About 2 cm in free viewing, roughly 3° at reading distance. This is what the
published phone work converges on: iTracker about 2 cm, the open reimplementation of
Google's method 1.8 to 2.0 cm, RGBDGaze 1.9 cm
([sources in 09-GAZE-ACCURACY.md](09-GAZE-ACCURACY.md)). Google's 0.46 cm has never been
reproduced and is not the target.

**Inputs.** Two eye crops per frame, cut from ARKit's camera image using the face mesh's
eye landmarks, plus the head direction and eye position ARKit already gives. The network
estimates the eye-in-head angle only; the geometry does the rest. Predicting the screen
point end to end, as the published models do, would throw away the part of the problem we
have already solved.

**Training data.** GazeCapture, about 1,500 participants and 2.5 million frames, under its
research licence. It is colour only, with no depth or infrared, and its labels are screen
points, so the training target must be derived: the eye-in-head angle from the labelled
screen point minus the head direction the dataset's own face fit provides. Getting that
derivation right is most of the work.

**Personalisation.** The literature is unanimous that the base model is not enough; every
result under 2 cm depends on a per-person step. Ours already exists: the calibration grid
fits `f` on top of whatever the network outputs, and the taps in every session supply more
pairs for free (`10-MOTION-FUSION.md` §10).

**Inference.** A small network over two eye crops is a few million operations a frame. On
the iPhone 15's Neural Engine that runs at 60 Hz without heating the device
(`09-GAZE-ACCURACY.md` §6). Core ML conversion from the training framework is routine.

**Evaluation.** Gaze-before-tap error in free viewing, hand-held, on sessions recorded with
the study stimulus. Never the grid alone. The grid is a check; the taps are the judge.

**Privacy.** A learned model needs eye images to be trained and personalised, and the
research principles forbid retaining raw video (`06-RESEARCH-PRINCIPLES.md`). The line to
hold: eye crops may be processed on device for inference; if any are stored for
fine-tuning they are small, local, consented separately, never committed, and deleted after
the model is fitted. The exported dataset stays what it is: numbers, not pictures.

## 2c. Result of the pupil landmark experiment, 6 September 2026

One calibration and one 16-tap session on the build with `PupilDetector`. The fitter chose
the pupil source on its own. Measured with the same gain table as `10-MOTION-FUSION.md` §14:

| Readout | Horizontal gain (near / far) | Horizontal r | Vertical gain | Vertical r |
| --- | --- | --- | --- | --- |
| ARKit eye transforms | 0.21 / 0.27 | 0.50 / 0.86 | 0.24 / 0.22 | 0.30 / 0.82 |
| ARKit eye-direction blend shapes | 0.33 / 0.45 | 0.53 / 0.87 | 0.39 / 0.36 | 0.28 / 0.82 |
| **Vision pupil landmarks** | **0.38 / 0.37** | **0.90 / 0.85** | 0.03 / 0.05 | 0.78 / 0.72 |

Judged against the taps, fitting on the calibration and replaying on the session:

| Eye-in-head input | Grid CV | Gaze-before-tap | On the display |
| --- | --- | --- | --- |
| Pupil landmarks (shipped) | 90 pt | **199 pt** | 87% |
| ARKit transforms | 168 pt | 281 pt | 91% |
| Blend shapes | 161 pt | 263 pt | 92% |
| Pupil horizontal, blend shapes vertical | 153 pt | 217 pt | 95% |
| All six readouts, ridge | 91 to 103 pt | 193 to 221 pt | 88 to 90% |

Three conclusions. The pupil landmarks are the best horizontal readout available, with the
most consistent gain across distances, and they are close to blind vertically, because the
pupil barely moves against an opening whose height is set by the eyelids. Fusing readouts
does not help beyond the noise of sixteen taps. And 199 points is 3.3 cm, about 5°: better
than anything before it in free viewing, and not the 2 cm the study needs. The pupil source
stays as the shipped estimate. Milestone 2 starts.

A complication for milestone 2, found while planning it: GazeCapture has no head pose. Its
labels are screen points and face boxes. Deriving an eye-in-head label therefore needs a
head pose estimated from each frame by a separate face-mesh fitter, run over the dataset
once, offline. If that estimate is too coarse, the fallback is the published approach: train
the network end to end on the screen point and treat its output as one more gaze source for
the calibration to correct, which keeps everything else in this plan intact.

## 2d. Which dataset, decided 6 September 2026

GazeCapture is requested by form and takes time. The alternatives were checked directly,
by fetching their pages and probing their download links, not from memory:

| Dataset | Access | Size | What it labels | Verdict |
| --- | --- | --- | --- | --- |
| **MPIIFaceGaze** (MPI-INF) | **Direct download, no form**, CC BY-NC-SA 4.0, cite Zhang et al. CVPRW 2017 | 940 MB, 15 people, ~45k frames | 2D and **3D gaze target, 6D head pose**, face centre, six landmarks, camera intrinsics, screen pose | **Primary.** The only one whose labels give the eye-in-head angle directly, which is exactly this project's model structure. Laptop webcams, not phones. |
| MPIIGaze (same group) | Direct, 2.1 GB | 15 people, 213k eye patches | Normalised eye images with gaze and head angles | Second, once the pipeline runs. |
| TabletGaze (Rice) | Direct link on the project page | 51 people, 816 videos, tablet front camera, four postures | 35 screen points; no head pose, no face boxes | Domain check later: closest to hand-held use, but every label this model needs would have to be estimated first. |
| GazeCapture (MIT) | Request form, research licence | 1,474 people, 2.5M frames, phones | Screen points, face and eye boxes; no head pose | Still worth requesting for scale and the phone domain. |
| Hugging Face hub | Searched the hub API for "gaze" | | One unofficial Gaze360 mirror; the rest unrelated | Not used. Re-hosted copies of licensed datasets carry a licence risk this research should not take. |
| Kaggle | Searched | | No smartphone gaze dataset with the labels needed | Not used. |

MPIIFaceGaze was downloaded to a folder outside the repository the same day: 37,667 frames
from 15 people, 1,500 to 2,900 each, at 38 to 68 cm from the camera. The derived labels
behave physically: the eyes' rotation within the head correlates at −0.72 and −0.83 with the
head's direction, which is a person turning their head while keeping their eyes on the
screen, and it is the sign a flipped head axis could not produce. Its reader
(`Analysis/eyemodel/mpiifacegaze.py`) derives the label from the face centre, the 3D target
and the head rotation, and the training entry point holds out participants by name.

## 3. Milestones

1. **Pupil landmark result.** Done, §2c above. 2b starts.
2. **Data pipeline.** In progress, 6 September 2026. Written and tested against a synthetic
   subject folder: the GazeCapture reader (`Analysis/eyemodel/gazecapture.py`), square padded
   eye crops, and the direction-ratio label in the display frame. The dataset itself has to
   be requested by a named researcher at http://gazecapture.csail.mit.edu/download.php under
   its research-only licence, which also requires citing Krafka et al., CVPR 2016, in any
   publication. **Waiting on that request.** Remaining once it arrives: the head-pose
   estimate per frame, since the dataset has none, and validation of the label derivation
   on our own calibration frames, where the truth is known.
3. **Model.** First real result, 6 September 2026, on this Mac's Metal backend. A two-branch
   network of 195,000 parameters over two 64-pixel grey eye crops plus the head direction,
   trained three epochs on 14 people, judged on the fifteenth, whom it never saw:

   | | Horizontal | Vertical |
   | --- | --- | --- |
   | Correlation with the true eye-in-head angle | **0.966** | 0.806 |
   | Gain (slope of prediction against truth) | **0.96** | 0.76 |
   | Error, degrees | 6.79° overall | |
   | After a per-person linear correction fitted on half that person's frames | 5.72° | |
   | Constant prediction, what "learned nothing" looks like | 17.0° | |

   Set beside the on-device readouts in §2c: ARKit's transforms report the eye at a gain of
   about 0.2, the pupil landmarks at 0.37 horizontally and near zero vertically. The network
   reports it at 0.96 horizontally after three epochs. Vertical is the weaker axis, as it was
   for every readout; eyelids hide more of the vertical rotation than the horizontal. The
   absolute degree figures are large because the dataset's eye-in-head range is large, about
   15° of spread on a laptop at half a metre; on the phone the range is a third of that, and
   what carries over is the correlation and gain, not the degrees. A 20-epoch run with crop
   jitter, brightness and contrast variation, a cosine learning-rate schedule and three people
   held out followed the same day. Best held-out loss at epoch 16 of 20, 7.09° over the three
   people together; per person, none of whom the network saw:

   | | p12 | p13 | p14 | Three-epoch run, p14 |
   | --- | --- | --- | --- | --- |
   | Horizontal correlation / gain | 0.967 / 0.91 | 0.951 / 0.97 | **0.972 / 0.98** | 0.966 / 0.96 |
   | Vertical correlation / gain | 0.796 / 0.68 | 0.736 / 0.73 | **0.843 / 0.79** | 0.806 / 0.76 |
   | Error, degrees | 5.95° | 8.18° | 7.22° | 6.79° |
   | After a per-person linear correction | 5.92° | 5.70° | **5.23°** | 5.72° |
   | Constant prediction | 21.0° | 14.2° | 17.0° | 17.0° |

   The figure that transfers to the phone is the one after the per-person correction, since
   that is what the on-device calibration fits, and it improved on every axis and every person
   over the three-epoch weights. These are the weights bundled in the app. The known next
   improvement, if it is needed, is head-pose normalisation of the crops, the standard step in
   the MPIIGaze line of work, which cancels head roll and distance before the network sees the
   eye.
4. **On-device.** Done in first form, 6 September 2026. The checkpoint is converted with
   `eyemodel/export_coreml.py`, which refuses to save unless Core ML and PyTorch agree on the
   same inputs to 1e-3, compiled with `coremlcompiler`, and bundled in the package as a 424 KB
   resource. On the phone, `EyeCropper` cuts the two eyes out of the upright camera image
   with exactly the training geometry, using the eye contours the pupil detector already
   has, and `LearnedEyeModel` runs the network beside the landmarks on the same frame. Its
   estimate is recorded on every gaze row (`learnedU`, `learnedV`), carried in the
   calibration frames, and offered to the fitter as `GazeSource.learned`. The bundled weights
   are the epoch-16 checkpoint of the 20-epoch run above. On the iPhone 15 the tracker held
   60 Hz with the model running, and the estimate refreshed 31 times a second, the rate of
   the landmark detector it shares a frame with.

   **First calibration with the learned source, 6 September 2026, 803 frames, 12 targets,
   27–38 cm.** The fitter chose the pupil landmarks at 41 pt held out and rejected the
   learned source at 122 pt. The frames show why, and it is not the network:

   | Readout, eye-in-head against the truth | Horizontal r / gain | Vertical r / gain |
   | --- | --- | --- |
   | ARKit eye transforms | 0.93 / 0.15–0.19 | 0.99 / 0.19–0.26 |
   | Pupil landmarks | 0.89–0.95 / 0.30 | 0.96 / 0.04–0.06 |
   | Learned model, as bundled that morning | **−0.98 / 1.27–1.73** | **0.97 / 0.31–0.39** |

   The learned model carries the strongest horizontal signal of any readout by a wide margin,
   and it carries it with the sign reversed. Within one calibration pass it is very clean:
   in the far pass the estimate is a straight line in the true angle with a residual scatter
   of 0.011 against a span of 0.35. Between the two passes, though, the line's offset moves,
   by 0.06 horizontally and 0.05 vertically in the model's units, and what changed between
   the passes is the head's direction, not the eyes'. Both facts have one cause. ARKit hands
   the front camera's frames over mirrored, the way a selfie preview looks, while the training
   images are the plain camera view. The pupil landmarks prove the mirror independently: they
   move to image-right when the participant looks right, which a camera view cannot do. A
   mirrored eye reads as rotated the other way, hence the sign; and the head direction the
   model is given, which is in the true frame, disagrees with the face it sees, hence an offset
   that moves with head pose. The fitter's correction has no head terms by design (§11 of
   `10-MOTION-FUSION.md`), so an offset that moves with the head cannot be fitted away, and
   the source scored badly despite its correlation.

   The fix is one flip: the crops are now taken from the mirrored-back image
   (`EyeCropGeometry.mirrored`, `PupilDetector`), with the two eyes assigned to the model's
   left and right inputs by their position rather than by Vision's labels, and the learned
   source now has to show a positive gain like every other.

   **Second calibration, same morning, after the flip, 796 frames, 12 targets, 30–42 cm.
   Confirmed.** The fitter chose the learned source, head plus linear, at **22 pt held out**,
   0.60°, worst target 39 pt: the best any calibration on this phone has scored, against 41 pt
   for the pupil landmarks on the same frames and 79 pt for ARKit's transforms.

   | Readout, eye-in-head against the truth | Horizontal r / gain | Vertical r / gain | Grid CV |
   | --- | --- | --- | --- |
   | ARKit eye transforms | 0.76–0.88 / 0.17–0.22 | 0.92–0.99 / 0.16–0.25 | 79 pt |
   | Pupil landmarks | 0.85–0.95 / 0.31–0.35 | 0.95–0.96 / 0.05 | 62 pt |
   | Learned model, un-mirrored | **+0.93–0.96 / 1.50–1.52** | **+0.99 / 1.72–1.87** | **22 pt** |

   Both signs are positive, the gain is the same in the near and far pass to within a few
   per cent, and the vertical axis, the weak one for every readout before, is now the strong
   one at 0.99. The model reports about one and a half to two times the true rotation, which
   the fitter absorbs; the ratio is a property of the crop scale and does not matter as long
   as it is stable, and it was. One residue remains: within a pass, the horizontal residual
   still correlates −0.4 to −0.5 with head direction, over a head range of only 0.06. The
   network's head conditioning transfers imperfectly from a laptop at half a metre to a phone
   at a third. That is the argument for head-pose normalisation of the crops if free viewing
   demands it.

   **Licence note.** The bundled weights were trained on MPIIFaceGaze, which is CC BY-NC-SA
   4.0. This repository is a research prototype; anything derived from it commercially would
   need a model trained on differently licensed data, and any publication cites Zhang,
   Sugano, Fritz and Bulling, CVPRW 2017.
5. **Judgement.** Recalibrate, record sessions, gaze-before-tap. Go or no-go against 2 cm.
   First data point, 6 September 2026, before the mirror fix: on the session recorded with
   that calibration, replaying each source's head-plus-linear model gives a gaze-before-tap
   error of 185 pt for the pupil landmarks and 260 pt for the still-mirrored learned source,
   against 450 pt for ARKit's transforms; 13 taps.

   **Second data point, after the fix, 72 s of shopping at 29–32 cm, 15 taps, 97% of gaze on
   the display.** Gaze-before-tap as recorded: **133 pt**, 2.2 cm, about 4° at that distance;
   the pupil landmarks replayed on the same rows give 172 pt, ARKit's transforms 235 pt. Best
   free-viewing figure so far, from 199 pt, and still short of 2 cm. But the per-tap table
   says the remaining error is not what the number suggests:

   - Within each pre-tap window the gaze is still to 16 pt horizontally and 11 pt
     vertically. The error is systematic, not scatter.
   - It grows with where the finger landed: horizontally by −189 pt per unit of screen
     width, so a tap at the right edge of a list row has its gaze 150–180 pt to the left of
     it, while the five taps on the small back button, where finger and eye have to agree,
     err by 40–58 pt. On a list row the finger lands wherever is convenient, at the right,
     and the eyes rest on the product name, which starts at 0.32 of the width; the recorded
     gaze for those taps sits at 0.28–0.43. The fingertip is not the ground truth on a wide
     element, and the metric has been over-stating the error by that much since the first
     session.
   - Vertically there is a constant −50 pt: the gaze rests above the fingertip on every tap,
     including the back button. Part of this is the well-known touch offset, the contact patch
     landing below the point the finger appears to cover; part may be the head-conditioning
     residue above, since the session was at the near edge of the calibrated range and with a
     slightly different head direction.

   Taps now record the tapped element's frame (`targetMinX` to `targetMaxY`, see
   `05-DATA-SCHEMA.md`) and the evaluation reports the distance from gaze to that frame, zero
   inside it, beside the fingertip distance. The next session gives the honest figure. If it
   comes in under 2 cm on the frame metric, the go decision is made on the model as it is; if
   the vertical offset persists across sessions, head-pose normalisation of the crops follows.

## 4. What would stop it

If the pupil landmarks turn out to carry the eye rotation at near full gain, 2b is not
needed and this document records why it was not built. If GazeCapture's face fit is too
coarse to derive a clean eye-in-head label, the network would have to predict the screen
point end to end after all, and the plan is revised. Either outcome is written down.
