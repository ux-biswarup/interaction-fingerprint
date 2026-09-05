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

## 3. Milestones

1. **Pupil landmark result.** One recalibration and one session on the pupil build; the
   gain table from §14 extended with the new source. Decides whether 2b starts.
2. **Data pipeline.** GazeCapture licence, download, derivation of eye-in-head labels,
   eye-crop extraction matching what the phone will produce. Validate the label derivation
   on our own calibration frames, where the truth is known.
3. **Model.** Train a small network; hold out participants, not frames. Report eye-in-head
   error in degrees on held-out people before any personalisation.
4. **On-device.** Core ML conversion, crop extraction from ARKit frames, 60 Hz timing on the
   iPhone 15, a fourth gaze source in the fitter.
5. **Judgement.** Recalibrate, record sessions, gaze-before-tap. Go or no-go against 2 cm.

## 4. What would stop it

If the pupil landmarks turn out to carry the eye rotation at near full gain, 2b is not
needed and this document records why it was not built. If GazeCapture's face fit is too
coarse to derive a clean eye-in-head label, the network would have to predict the screen
point end to end after all, and the plan is revised. Either outcome is written down.
