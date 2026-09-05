# Motion Fusion: Gyroscope, Camera and Eye, and Where Each One Belongs

This document answers a requirement raised on 5 September 2026, after the gaze tracker
reached 1.62° but still felt unstable when the phone moved. It sets out what was asked,
what the sensors can physically deliver, what was found wrong, and what was built.

## 1. The requirement, restated

> Gaze must land on the correct screen position no matter how the phone is held, tilted
> or moved. The gyroscope, the camera and the eye model should be fused mathematically so
> that the phone's own motion is separated from the eye's motion, in the way an aircraft's
> inertial system separates its own movement from the world. The face should be tracked
> as a dense mesh with priority on the eyeballs, and eye movement mapped to the screen
> layout the way an optical mouse maps surface movement to a cursor.

Three claims are folded into that, and they have different answers.

| Claim | Verdict |
| --- | --- |
| Gaze should be independent of how the phone is held | Already true by construction. Section 3 explains why, and what was actually wrong. |
| The gyroscope should be fused into the gaze estimate | Yes, but not the way an aircraft does it. Section 4 gives the physics, section 5 what was built. |
| Track the eye like an optical mouse over a dense mesh | ARKit already does the mesh part with better sensors than we can reach. The optical mouse part cannot work for gaze. Section 7. |

## 2. What each sensor can see

This is the foundation for everything below, so it is stated bluntly.

- **The gyroscope measures the phone.** Angular velocity of the device, about 100 times a
  second, with low latency and no knowledge of anything outside the phone. It cannot see
  an eye. It cannot tell whether the person is looking at the screen.
- **The accelerometer measures the phone**, linear acceleration plus gravity. Integrated
  once it gives velocity, twice it gives position, and both drift within seconds. It does
  give the phone's tilt relative to gravity reliably, because gravity is a constant.
- **The TrueDepth camera measures the face.** Position and orientation of the head and of
  each eye, from infrared, depth and colour, at 60 Hz, with a latency of at least one
  frame. This is the only sensor that knows where the eyes point.

An aircraft's inertial navigation system works because the aircraft obeys equations of
motion the system can integrate, and the thing being tracked *is* the platform carrying
the sensors. For us, the platform carrying the sensors is the phone, and the thing being
tracked is somebody else's eye. The gyroscope can tell us everything about the phone and
nothing about the eye. That is the boundary of the analogy, and every decision below sits
inside it.

## 3. What was actually wrong: ARKit had motion tracking switched off

The session was configured with `worldAlignment = .camera`. Apple's documentation for that
option states:

> When this alignment is active, ARKit performs no device motion tracking. That is,
> world-space positions are effectively always relative to the current position and
> orientation of the device.
> ([ARConfiguration.WorldAlignment.camera](https://developer.apple.com/documentation/arkit/arconfiguration/worldalignment/camera))

So ARKit was never told to use the inertial sensors at all. Every face pose it reported
was relative to wherever the phone happened to be pointing on that frame, with no
knowledge of how the phone had moved since the previous one. The only motion information
the app had was the separate gyroscope readout we added for the gate.

The configuration now uses `.gravity`:

> The coordinate system's y-axis is parallel to gravity, and its origin is the initial
> position of the device. The y-axis matches the direction of gravity as detected by the
> device's motion sensing hardware.
> ([ARConfiguration.WorldAlignment.gravity](https://developer.apple.com/documentation/arkit/arconfiguration/worldalignment-swift.enum/gravity))

Under this setting ARKit fuses the inertial sensors into its own tracking and the camera
transform carries the phone's attitude on every frame. The face anchor is expressed in a
world that stays still while the phone turns. Our pipeline already computed the face pose
relative to the camera by inverting the camera transform, so the per-frame gaze geometry
is unchanged by this switch; what changes is that ARKit's own tracker now works in a frame
where the head is stationary and the phone is the thing moving, which is the truth.

Whether this improves ARKit's face estimate during hand motion is Apple's implementation
detail and not documented. It is the right configuration on principle, it costs nothing,
and its effect is measurable with the precision readout during a gentle shake. That check
is in section 8.

Full six-degree-of-freedom device tracking is also available inside a face session by
setting `isWorldTrackingEnabled`, which runs the rear camera at the same time on A12 and
later devices ([Apple](https://developer.apple.com/documentation/arkit/arfacetrackingconfiguration),
[Brad Gayman](http://www.bradgayman.com/blog/faceWorld/index.html)). It is not enabled.
It doubles camera power draw and heat for a translation signal we do not need, because the
face pose already gives eye position relative to the phone directly.

## 4. Why the gaze is already independent of how the phone is held

Every frame, the camera reports where the eyes are and which way they point, both relative
to the phone. The gaze ray is intersected with the plane of the display, in the phone's
own coordinates. The screen *is* the phone's frame. If the phone tilts ten degrees, the
eye position and the gaze direction both change by exactly the amounts that keep the
intersection on the same physical pixel, provided the person is still looking at that
pixel. There is no separate step where the phone's orientation has to be corrected for,
because nothing in the calculation ever left the phone's frame.

This is also why the calibration is stored as an *angular* correction plus a camera
position, never as an offset on the screen. See `09-GAZE-ACCURACY.md`.

So what does move the dot when the phone moves? Two things, and neither is a coordinate
error.

**The eyes genuinely lag.** When the phone moves, the content moves through the world, and
the eyes have to follow it. Smooth pursuit and corrective saccades have latencies on the
order of a hundred milliseconds. During a brisk reposition the true point of regard on the
screen really does trail the content, and a tracker that reported otherwise would be lying.
Head-mounted eye trackers face the mirror image of this problem, the head moving while the
world stays still, and their fixation detectors explicitly compensate for the
vestibulo-ocular reflex rather than pretending it is not there
([Pupil Labs](https://docs.pupil-labs.com/neon/data-collection/data-streams/)). Our
version is to flag the frames, not to invent a stable gaze that did not exist.

**The tracker degrades under motion blur.** ARKit's face estimate is worse on a frame
captured mid-swing. That is a property of the camera and cannot be recovered from a
gyroscope, which was not looking at the face.

Predicting the dot forward using the gyroscope, the way a headset predicts head pose to
hide latency, was considered and rejected. It assumes the gaze point is fixed in the world
while the phone moves, when in a screen-reading task the gaze point is fixed to the
*content*, which moves with the phone. Predicting in the wrong frame would add error during
exactly the motions it was meant to help with.

## 5. The real defect in the gate: velocity is not displacement

The motion gate flagged a frame when the gyroscope's angular *velocity* exceeded a
threshold. That is the wrong quantity, and it is why the gate felt over-sensitive even
after the thresholds were raised and hysteresis added.

A resting hand trembles at roughly 8 to 12 Hz. Take an oscillation of half a degree
amplitude at 8 Hz: its peak angular velocity is 0.5° × 2π × 8 ≈ 25°/s, which looks like a
deliberate movement to a velocity gate. But over the hundred milliseconds that matter for
the eye, the phone rotates one way and back and its *net* displacement is under a degree,
which at 40 cm moves the screen about 5 mm under the eyes. That is below the tracker's own
accuracy and no threat to a fixation. Velocity is high; displacement is negligible. A
velocity gate cannot tell tremor from a reposition because it is measuring the wrong
thing.

The gate now measures **how far the screen moved under the eyes over the eye's reaction
window**, in millimetres:

```
disturbance = (net rotation over 120 ms) × viewing distance
            + ½ × (smoothed linear acceleration) × (120 ms)²
```

The net rotation is the angle between the phone's attitude now and its attitude 120 ms
ago, taken from Core Motion's fused attitude quaternion. Angle between two orientations
is independent of any axis convention, which matters because Apple's camera frame and Core
Motion's device frame are not the same and getting a sign wrong silently would be worse
than the original problem. The acceleration term covers translation, which rotation alone
cannot see.

| Situation | Net rotation in 120 ms | Disturbance at 40 cm | Verdict |
| --- | --- | --- | --- |
| Steady hand, 0.5° tremor at 8 Hz | ≤ 1° | ≤ 7 mm | steady |
| Slow drift while reading | 1° | 7 mm | steady |
| Deliberate reposition | 10° | 70 mm | moving |
| Sharp knock, one frame | ≈ 0° net | ≈ 0 mm | steady |

Thresholds: flagged as moving above **20 mm**, about twice the measured gaze accuracy of
11 mm, and released below **8 mm**. Between the two the previous verdict holds, so it does
not chatter.

The gyroscope is still read, and its rate is still recorded, but the decision no longer
turns on it. The instrument screen now shows the disturbance in millimetres rather than
radians per second, because millimetres on the screen is the unit the research actually
cares about.

## 6. The dot no longer changes character when the gate fires

The gate previously did three visible things at once: dimmed the dot, switched the
display filter to a heavier setting, and changed the status text. The dimming and the
filter switch made every threshold crossing visible as a change in the dot's behaviour,
and with a gate that fired on tremor that was constant flicker. Both are removed. The dot
draws at one strength and one filter setting whenever a face is tracked and the eyes are
open. The `device_moving` flag stays in the recorded data, where it belongs, and the status
text still says "Hold the phone still".

## 7. The dense mesh and the optical mouse

**ARKit already fits a dense mesh.** The face anchor carries a 1,220-vertex mesh updated
at 60 Hz, and the eye transforms and convergence point are derived from infrared, depth and
colour by Apple's model running on the Neural Engine. That model is what produces the eye
direction we already use. Any pupil tracker we built ourselves would work from the RGB
frame alone, without the infrared illumination or the depth map, on a smaller network, and
would be a strictly worse estimate of the same thing. The Vision framework exposes a single
2D pupil landmark per eye with no published accuracy figure
([Vision](https://github.com/xybp888/iOS-SDKs/blob/master/iPhoneOS13.0.sdk/System/Library/Frameworks/Vision.framework/Headers/VNFaceLandmarks.h));
it is a face-detection convenience, not a gaze sensor.

**An optical mouse cannot work for gaze.** A mouse integrates relative surface motion and
drifts without bound, and that is fine because the person closes the loop: they see the
cursor and correct it. Gaze cannot close that loop. To correct a drifting gaze estimate
you would have to look at it, which moves your gaze. Relative tracking therefore needs an
absolute reference to pin it, and the calibrated geometric estimate *is* that absolute
reference. There is nothing to add underneath it.

**What the idea does contain that is usable.** ARKit reports eight blend shapes that
describe eye direction as expression coefficients: `eyeLookUp`, `eyeLookDown`,
`eyeLookIn`, `eyeLookOut`, for each eye. They are a second readout of gaze from the same
model, and they may carry appearance information, such as eyelid shape, that the eye
transform does not. Whether they help is an empirical question, so they are now:

- recorded in every sample, with the other blend shapes;
- offered to the calibration as optional additional inputs, folded into a horizontal and
  a vertical term, and selected only if cross-validation shows they lower held-out error.

If they are redundant with the eye transform, the ridge penalty and the cross-validation
will leave them out, and nothing is lost. The result is visible in the calibration summary,
which names the winning basis; a model that used them shows `+look`.

## 8. What was built, and what to check on the phone

Built:

1. ARKit world alignment set to `.gravity`, so device motion tracking is on.
2. Motion gate rewritten on net displacement in millimetres over 120 ms, with hysteresis.
3. Dot appearance and filter decoupled from the gate.
4. Phone attitude recorded on every sample: tilt of the screen from vertical and sideways
   roll, both from the gravity vector, plus rotation rate and the disturbance figure. How a
   participant holds the phone is a covariate the analysis did not previously have.
5. Eye-direction blend shapes recorded and offered to the calibration.
6. Eye position readout on the instrument screen, in centimetres.

To check, in this order:

- **Precision during a gentle shake.** Start the tracker, fixate on one point, and rock the
  phone slowly by a few degrees. The dot should wander a little, not jump, and should not
  change brightness. Compare against the previous build if it feels worse.
- **The gate.** Watch the millimetre readout. It should sit in single digits while you hold
  still and read, and cross 20 only when you actually move the phone.
- **Axis check.** With the tracker running, move the phone slowly to your right while
  keeping your head still. The eye `x` readout should change sign consistently and the eye
  `y` readout should not move much. Then move it upward and expect the reverse. If the
  readouts are swapped, the camera frame is rotated relative to what the geometry assumes,
  which the linear calibration has been silently absorbing; report it and it will be fixed
  at the source.
- **Recalibrate**, then look at the summary line. If it says `+look` the eye-direction blend
  shapes were chosen; if not, they were tried and rejected, and both outcomes are fine.

## 9. What the first recording showed

A 24 second session was recorded on 5 September 2026 with the build described above, after
a fresh calibration of 69 points (1.78° at 37 cm). The pipeline itself was sound: 1,739
events, gapless sequence, gaze at 59.9 Hz with no gap above 33 ms, 95% of frames inside
the trusted envelope, 2.6% flagged as `device_moving`, the tilt and disturbance columns
present on every row. Two things were badly wrong, and both had been invisible until there
was a recording to look at.

### Half of the gaze samples were off the screen

| | |
| --- | --- |
| Gaze samples landing on the display | 48% |
| Of the misses, above the top edge | 78% |
| Of the misses, beyond the right edge | 96% |
| Median position of a miss, normalised | x 1.72, y −0.28 |
| Miss rate when the phone was stillest | 61% |
| Miss rate while the phone was turning fastest | 0% |

The last two rows rule out phone motion as the cause. The misses happened while holding
still. The cause was in the fitted model. Its coefficients, in the order
`[1, u, v, u², v², uv, yaw, pitch]`:

```
u:  0.50   0.56  -16.4  -18.5    70.9  -12.5   3.96  -0.21
v:  0.84   0.36  -22.7   -6.5   232.7 -117.2   1.05   2.37
```

The head-pose coefficients were fitted on a head that moved by under two degrees during
calibration, then evaluated on the ten degrees a head and a hand produce in use. Ten
degrees of yaw times 3.96 is 0.7 in the gaze ratio, which at 37 cm is 26 cm off the side
of the screen: x ≈ 1.7. Six degrees of pitch times 2.37 lands 9 cm above the top edge:
y ≈ −0.3. Those are the observed miss positions. The quadratic terms, with coefficients in
the hundreds, do the same the moment gaze leaves the calibrated grid.

**This is also the mechanism behind the dot's sensitivity to phone movement.** Head pose
is measured *relative to the camera*, so turning the phone five degrees changes it by five
degrees instantly, and the pose terms turn that into a jump of several hundred points. The
per-frame jump grew from a median of 13 points when the phone was still to 81 points at a
gentle 0.2 rad/s, exactly as this predicts. The gyroscope was never the cause. It was a
model with no bounds.

Three changes:

1. **Every model input is bounded at prediction time** to the range seen during
   calibration, plus a 15% margin. The linear terms are exempt, because an angular model
   should still be right a little beyond the grid. The curvature, head-pose and eye-shape
   terms are held at the edge, because outside it they are simply unknown.
2. **Head-pose terms are only offered when the head actually moved during calibration**,
   by at least 0.10 rad, about six degrees. Previously 0.03 rad. In practice this means
   they will rarely be offered, which is correct: a term cannot be learned from data that
   does not exercise it.
3. **Every gaze row now carries the raw measurement**: eye position, both gaze angles, head
   pose. The first recording stored only the screen coordinate, so this diagnosis had to be
   reconstructed from the coefficients instead of read from the data. The schema promised
   offline re-mapping; now it can deliver it.

### No taps were recorded

The session contained three product selections and two back-presses, all of which came from
button actions, and zero tap events. The touch observer sits on the window as a gesture
recogniser that never leaves the `.possible` state. When a button's own recogniser fires,
UIKit cancels every other recogniser that has not declared it may recognise simultaneously,
so the observer's `touchesEnded` never arrived. It now declares simultaneous recognition
and treats a cancellation as the end of the touch it was. A UI test presses real buttons
through a real window and checks the exported file, because a unit test of the recorder
could never have found this.

### The second recording

Recorded after recalibrating on the build with the fixes above. Same task, 55 seconds.

| | First | Second |
| --- | --- | --- |
| Gaze samples on the display | 48% | 72% |
| Median per-frame jump | 17.9 pt | 8.5 pt |
| Jump while the phone turned at 0.2 to 0.4 rad/s | 81 pt | 22 pt |
| Taps recorded | 0 | 20, every one attributed to its control |
| Longest dwell on a region | 0.1 s | 1.5 s on the product image |

The sensitivity to phone movement fell by a factor of four with no change to the motion
code, which settles where it came from. The Phase 2 gate is passed: taps, scrolls, screens,
regions and gaze in one gapless stream on one clock.

The remaining misses are all on the detail page and cluster just beyond the top-left
corner, where the back button sits and where every calibration so far has had its worst
target. That is a calibration weakness in the row nearest the camera, not a motion effect,
and it is the next accuracy question. To make it answerable, every accepted calibration now
writes its raw frames to disk beside the sessions.

Two further adjustments from the data: the head-turned envelope now has a separate pitch
limit of 0.60 rad, because 5% of frames were flagged at a pitch of 20° with no yaw, which is
simply a person looking down at a phone; and drags are no longer reported as taps.

### The third recording, and a fault of my own

The next calibration came out at 55 points, 1.38°, the best so far. The recording made
with it put **1% of gaze samples on the display**. Median position: five screens to the
lower left.

Reproducing the app's arithmetic offline from the exported calibration and the recorded raw
measurements gave the recorded values exactly, so the app did what it was told. Undoing the
bound gave a median position near the display. The bounding rule introduced after the first
recording was wrong. It held the quadratic inputs at the calibrated edge while letting the
linear inputs run free, on the theory that the two kinds of term were separately meaningful.
They are not. The vertical gaze ratio spans about 0.05 across the whole display, so its
square is all but collinear with it; the fit had given the pair coefficients of +20 and −25
that cancelled inside the grid, and freezing one of them released the other. In the third
session the phone was also held 3 cm to one side, which pushed the horizontal ratio well
outside anything calibration had seen, and the released term took the estimate with it.

The corrected design, all of it now in place:

1. **Inputs are standardised before fitting**, centred and scaled to unit spread. The
   columns become comparable, the shrinkage penalty means the same thing for each, and a
   coefficient's size says something about its importance. The centre and scale are stored
   with the model.
2. **Every term is evaluated at the same bounded point.** Beyond the calibrated range the
   correction **continues along its slope at the boundary**, so a quadratic turns into a
   straight line where the data ends and an angular model still extrapolates off the
   display the way it should. Covariates are held, not continued.
3. **The simplest model within 8% of the best wins.** Cross-validation on a grid only tests
   a model inside the grid; in use the eyes leave it, and there fewer parameters is safer.
   The quadratic and the covariate terms now have to earn their place by a clear margin.

Stored calibrations from before this change load and run under the new prediction rule,
but they were fitted on raw inputs and should be replaced. **Recalibrate.**

### What the exported frames say about the top row

Refitting the exported calibration offline with every available basis, the top row's
held-out error stays between 115 and 134 points at the far distance under all of them,
while the bottom row sits at 44 to 57. No choice of model fixes it. The uncorrected
vertical bias grows smoothly down the screen, which the linear term handles; what is left
in the top row after correction is worst at the far distance, where the gaze passes
closest to the camera's own axis. This is a property of the sensor near the sensor, not of
the fit. For the study it means regions in the top 15% of the display carry roughly twice
the error of the rest, and any area of interest placed there needs to be sized for it.

## 10. Calibration in a product

The question was raised whether calibration can be skipped: a shipping product cannot ask
every user to walk a grid at two distances.

It cannot be skipped and still measured. The dominant per-person error is the angle between
the eye's optical and visual axis, about five degrees and different for everyone. Uncorrected,
ARKit's gaze is accurate to roughly 3° ([published](09-GAZE-ACCURACY.md)), which is two of
the six regions on a product page. Apple's own Eye Tracking runs a calibration screen on
first use for the same reason, and every commercial eye tracker does.

What a product can do is calibrate **implicitly**. When a person taps a button they were,
with near certainty, looking at it a moment before. Each tap therefore supplies a
(measured gaze angle, true screen position) pair, which is exactly what the calibration
grid supplies, without asking for anything. The fitter already works on whatever pairs it
is given, so implicit calibration is a change to where the pairs come from, not to the
model. A population-average correction can carry the first minute, and the per-person fit
replaces it as taps accumulate. This depends on taps being recorded, which is why the
missing-tap bug above matters beyond the dataset.

For the research phase the explicit calibration stays. It is what produces the accuracy
figure, and gaze without an accuracy figure attached is not evidence. Implicit calibration
is on the roadmap for the adaptive-interface phase, where it belongs.

## 11. What the exported frames revealed about the sensor

With the calibration frames on disk it became possible to ask what ARKit's gaze signal
actually contains, rather than how well a model fits it. Three findings, in order of
consequence.

### The axes were swapped

Across the whole calibration grid, the measured horizontal gaze ratio had a correlation of
**−0.02** with the true horizontal angle, and the measured vertical ratio of **+0.18** with
the true vertical. Yet within a target the frames scattered by only 0.1°. A precise signal
that does not track its own axis is tracking a different one: after removing the head
direction, the measured horizontal component tracked the *vertical* target position at
r = −0.69, and the vertical tracked the horizontal at r = −0.68.

Apple documents this. ARKit's camera frame follows the sensor's native landscape
orientation, and "the x-axis always points along the long axis of the device, even if that
direction is 'down' relative to the user" ([Apple](https://developer.apple.com/documentation/arkit/arconfiguration/worldalignment/camera)).
Every earlier build treated that x as running across the screen. The linear calibration
absorbed the rotation of the *angles* through its cross-terms, which is why anything worked;
the eye *position* entered unrotated, which is why the two-distance geometry never quite
closed, why solved camera offsets came out at 80 to 140 mm, and why holding the phone 3 cm
to one side sent the third recording off the display.

The convention was then chosen from data, not from the documentation. All eight signed axis
mappings were fitted to the exported frames with head terms included:

| Mapping | Held-out accuracy | Worst target |
| --- | --- | --- |
| **display X = camera y, display Y = −camera x** | **49 pt** | **74 pt** |
| display X = camera x, display Y = −camera y | 53 pt | 85 pt |
| the previous convention, X = −camera x, Y = camera y | worse than 100 pt | |
| remaining five | 105 to 133 pt | |

With the winning mapping the fitted eye gains land on the matched axes, 5.4 horizontal and
5.0 vertical, with small cross-terms. `DisplayFrame` now applies this rotation to the face
pose before anything else is computed, so eye position, gaze direction and head angles all
share the screen's own axes.

### ARKit reports the head at full strength and the eyes at a fifth

Regressing the measured gaze ratio on the head direction and the true angle together
explains 81 to 89% of its variance, and the coefficient on the true angle is **0.05 to
0.19** while the head's is near one. Across the whole 14 cm display the measured eye angle
moves by 1° to 3° when the eyes actually rotate through 10° to 20°. The eyes' rotation
within the head is being reported at roughly one fifth of its size; the head's direction is
reported faithfully.

This is why every calibration that reached below 100 points had head-pose terms in it, and
why the covariate-free models sit at 105 to 150 points however the axes are arranged. The
head terms were never leakage. They were the model finding the only way to express a
signal whose two components arrive with different gains. What was wrong was letting the
fitter discover that structure freely, with no bounds, and letting the eye-direction blend
shapes in beside it as a collinear second readout.

The model is now fixed by physics rather than fitted:

```
corrected gaze = head direction + f( measured gaze − head direction )
```

The head direction is the face anchor's forward axis in the display frame, the same units
as the gaze ratios, and it passes through with a gain of exactly one because it is a
direction. Only `f`, the correction of the eye-in-head angle, has free parameters: linear
or quadratic, with or without the solved camera position, standardised, bounded with
linear continuation, and required to have a positive gain on both axes. The eye-direction
blend shapes stay in the recorded data and are no longer offered to the fitter.

### Grid cross-validation does not predict free viewing

Every accuracy figure reported so far was held-out error *on the calibration grid*. The
recordings carry 43 taps, and a person looks at what they are about to tap, so the median
distance between the tap and the gaze in the half-second before it is a ground truth for
free viewing that the grid never sees. Fitting on the exported calibration and scoring
every model structure that way:

| Model | Grid CV | Gaze-before-tap, session 2 | session 3 | On the display |
| --- | --- | --- | --- | --- |
| Head + eye-in-head, corrected axes, linear | 124 pt | **223 pt** | **228 pt** | 73 to 87% |
| Free head terms, corrected axes (best on the grid) | 83 pt | 377 pt | 498 pt | 40 to 52% |
| No head term, any axes | 116 to 153 pt | 708 pt and worse | | under 20% |
| What the app recorded at the time | | 310 pt | 5,106 pt | 72% / 1% |

The structure that scores worst on the grid among the three is the one that works in the
world, and it transfers unchanged from one day's calibration to a session recorded with a
different one. The grid is a necessary check and a poor judge. From here, gaze-before-tap
error is the figure that decides between models, and the accuracy number on the calibration
screen is understood as what it is: performance on the grid, under the grid's conditions.

Calibrating from the taps themselves, leaving one tap out, reaches a median of **164 pt**.
Better than the grid transfer, and the mechanism the product path in section 10 depends on,
but it says the free-viewing floor of this sensor for this participant is currently around
4° to 6° (164 pt is 2.7 cm, 225 pt is 3.7 cm, at about 35 cm), not the 1.4° the grid
reports, and worse than the published 3.18° for ARKit gaze.

## 12. Seeing what the system sees

The instrument screen now has a Screen / Camera switch while the tracker runs. Camera shows
the front camera's image with the tracked face mesh, the head's forward axis in cyan and
each eye's line of sight to ARKit's convergence point in yellow, with the gaze dot drawn
over it exactly as on the plain screen. The two components of the model are the two colours:
when the dot is wrong, the picture says whether the head line or the eye lines were wrong,
which is the question that decides what to fix. Nothing on that screen is recorded.

## 13. What this does not claim

It does not claim the gyroscope makes gaze more accurate. It cannot; it never sees the eye.
It claims that the phone's motion is now measured in the quantity and units that matter,
that ARKit is now configured to know about that motion at all, and that the data now
records how the phone was held. Accuracy remains governed by the camera and the
calibration, as set out in `09-GAZE-ACCURACY.md`.

## Sources

- [ARConfiguration.WorldAlignment.camera](https://developer.apple.com/documentation/arkit/arconfiguration/worldalignment/camera), Apple
- [ARConfiguration.WorldAlignment.gravity](https://developer.apple.com/documentation/arkit/arconfiguration/worldalignment-swift.enum/gravity), Apple
- [ARFaceTrackingConfiguration](https://developer.apple.com/documentation/arkit/arfacetrackingconfiguration), Apple, on `isWorldTrackingEnabled`
- [AR World Tracking in an ARFaceTrackingConfiguration Session](http://www.bradgayman.com/blog/faceWorld/index.html), Brad Gayman
- [Neon data streams](https://docs.pupil-labs.com/neon/data-collection/data-streams/), Pupil Labs, on IMU fusion and vestibulo-ocular compensation in fixation detection
- [Apple ARCamera parameters](https://medium.com/@vitali.usau/apple-arcamera-camera-parameters-explanation-for-3d-reconstruction-pipeline-7b3937dab3b9), on the landscape-native sensor frame
- [VNFaceLandmarks.h](https://github.com/xybp888/iOS-SDKs/blob/master/iPhoneOS13.0.sdk/System/Library/Frameworks/Vision.framework/Headers/VNFaceLandmarks.h), Vision pupil landmarks
- [Motion-to-photon latency in mobile AR and VR](https://medium.com/@DAQRI/motion-to-photon-latency-in-mobile-ar-and-vr-99f82c480926), on why headsets predict pose and why that assumption does not transfer here
