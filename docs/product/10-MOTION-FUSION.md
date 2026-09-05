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

## 9. What this does not claim

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
