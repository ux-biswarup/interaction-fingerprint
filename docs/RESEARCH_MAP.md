# Research map

Where this project sits, what already exists, and the exact line it claims as its own.
Written 6 September 2026 so that a paper or a case study can start from an honest
position rather than an enthusiastic one. Every claim of novelty below is narrow on
purpose. If a reader knows of prior work that crosses one of these lines, the right
response is to move the line, not to argue.

Citations are given as author, venue and year so they can be looked up; figures quoted
from other work are as reported by their authors and should be re-checked against the
original before they appear in anything published.

---

## 1. The landscape in one picture

```text
                       appearance-based gaze estimation
                       (MPIIGaze, GazeCapture, ETH-XGaze, Google 2020)
                                        │
   phone eye tracking as a product ─────┼───── open webcam gaze (WebGazer, OpenFace,
   (Apple ARKit lookAtPoint,            │       MediaPipe Iris, L2CS-Net)
    Apple Eye Tracking accessibility,   │
    Hawkeye, RealEye)                   │
                                        ▼
                     THIS PROJECT: an open iPhone research instrument
                     head pose + learned eye-in-head + physics-fixed calibration,
                     validated against the element people tap
                                        │
        ┌───────────────────────────────┼───────────────────────────────┐
        ▼                               ▼                               ▼
 eye-movement individuality     UX / commerce attention           attentive and adaptive
 and gaze biometrics            analytics                          interfaces, generative UI
 (Henderson & Luke; GazeBase;   (Tobii, iMotions, EyeQuant;        (Vertegaal 2003; gaze-
  Lohr & Komogortsev)            Krajbich; Pieters & Wedel)         contingent displays; LLM
                                                                    generative UI 2024–25)
                                        │
                                        ▼
                     THE FINGERPRINT: observable-only, unit-defined,
                     quality-gated, stable-vs-state, meant as an input
                     layer for an agent that has not been built yet
```

---

## 2. Gaze estimation on phones and webcams

**What exists.**

- *Appearance-based gaze estimation* learns gaze from eye or face images rather than from
  corneal reflections. The line runs from MPIIGaze (Zhang, Sugano, Fritz, Bulling, CVPR
  2015) through MPIIFaceGaze (same authors, CVPRW 2017), RT-GENE (Fischer et al., ECCV
  2018), Gaze360 (Kellnhofer et al., ICCV 2019) and ETH-XGaze (Zhang et al., ECCV 2020).
  This project trains its eye model on MPIIFaceGaze and owes the whole idea to this line.
- *GazeCapture / iTracker* (Krafka et al., CVPR 2016) is the canonical phone dataset: about
  1,450 people, 2.5 million frames, collected by crowdsourcing on iPhones and iPads, with a
  reported error of roughly 1.7 cm on phones without calibration and around 1.3 cm with it.
  It requires a signed research agreement. It remains the right dataset for a phone-domain
  model and this project has not yet used it.
- *Google's smartphone eye tracking* (Valliappan et al., *Nature Communications*, 2020)
  showed that a phone's front camera plus a personalised model reaches accuracy in the
  sub-centimetre to centimetre range, good enough to replicate classic eye-movement
  research findings. It is closed, Android, and the strongest evidence that phone gaze can
  be a research instrument.
- *Apple's own gaze* comes in two forms: ARKit's `lookAtPoint` and per-eye transforms from
  face tracking, which this project measured at about a fifth of the true eye rotation
  (`docs/product/10-MOTION-FUSION.md` §14), and the Eye Tracking accessibility feature in
  iOS 18, which is closed, calibrated, and not exposed to apps as data.
- *Open webcam gaze*: WebGazer (Papoutsakis et al., IJCAI 2016) self-calibrates from clicks
  in the browser and is the closest philosophical relative of this project's
  gaze-before-tap validation; OpenFace (Baltrušaitis et al., FG 2018) gives landmarks and
  gaze vectors; MediaPipe Iris (Google, 2020) gives iris landmarks; L2CS-Net and similar
  give gaze angles from face crops. None runs against the TrueDepth pipeline or feeds a
  SwiftUI area-of-interest model.
- *Commercial webcam and phone attention products*: RealEye, Sticky, Lumen Research,
  Hawkeye Access. Closed, and their validation methods are rarely published in detail.

**What this project adds, precisely.**

- A published measurement that ARKit's eye-in-head signal arrives at a gain of about 0.2
  while its head direction arrives at full strength, and a calibration structure that
  follows from it: gaze = head direction at unit gain plus a fitted correction of the eye
  signal only (`10-MOTION-FUSION.md` §11). We have not seen this decomposition stated for
  ARKit elsewhere; if it has been, the citation belongs here.
- An open, tested, end-to-end iPhone instrument: ARKit head pose, Vision pupil landmarks
  and a Core ML eye-in-head network on the same frame, all recorded, so a session can be
  re-mapped with a better model later.
- Validation against the *element* a person taps rather than the fingertip, with the
  finding that the fingertip overstated error by about a factor of two on wide elements
  (`11-LEARNED-EYE-MODEL.md` §3). WebGazer's click-calibration assumes gaze at the cursor;
  on a phone with rows and labels that assumption is measurably wrong.

**What it does not claim.** That the eye model is better than iTracker or Google's; it was
trained on 15 laptop users and tuned on one phone user. That 22 pt on a grid or 28 pt to
an element generalises to other people or phones. Both are one person's numbers until
Phase 4 says otherwise.

---

## 3. Eye-movement individuality and behavioural biometrics

**What exists.**

- *Eye movements are individual and stable.* Henderson and Luke (*Psychonomic Bulletin &
  Review*, 2014) showed that fixation duration distributions are stable within a person
  across tasks and sessions; later work (Carter & Luke, 2020, review) treats eye-movement
  parameters as trait-like. This project's first finding, fixation duration and rate within
  10% across sessions for one person, is a replication of that literature on a phone, not
  a discovery.
- *Gaze biometrics*: Holland and Komogortsev (2011 onwards) and the GazeBase dataset
  (Griffith et al., *Scientific Data*, 2021), with deep models such as Eye Know You Too
  (Lohr & Komogortsev, *IEEE TIFS*, 2022) identifying people from eye movements alone.
  This is the field that owns the word "biometric", and it uses research-grade trackers at
  1000 Hz.
- *Touch and motion biometrics*: Touchalytics (Frank et al., *IEEE TIFS*, 2013) on
  swipe dynamics; keystroke dynamics going back to the 1980s; gait and grip from inertial
  sensors. Press duration, contact size and scroll rhythm as recorded here belong to this
  line.

**What this project adds, precisely.**

- The *combination* on one device, one clock and one event stream of gaze, face
  coefficients, head, device motion and touch, with the explicit question of which layer
  is trait-like and which is state-like for the same person under manipulated conditions.
  Each layer has been studied; their joint stability on a phone in natural use has not,
  to our knowledge.
- The observation, from one person, that the eye's rhythm is the stable layer and the hands
  and head the variable one. A hypothesis for Phase 4, not a result.

**What it does not claim.** Identification. The project does not attempt to identify a
person from their fingerprint, does not use research-grade sampling rates, and should not
be cited as a biometric identification system. The word "fingerprint" is used in the sense
of a characteristic pattern, and the README says so.

---

## 4. Attention analytics in UX research and commerce

**What exists.**

- *Lab eye tracking for UX* is mature: Tobii Pro, iMotions, EyeLink; metrics such as dwell,
  time to first fixation, revisits and transition matrices are standard (Holmqvist et al.,
  *Eye Tracking: A Comprehensive Guide to Methods and Measures*, 2011). Every feature in
  `12-FINGERPRINT-FEATURES.md` has a name in that book.
- *Attention and choice*: the attentional drift-diffusion model (Krajbich, Armel & Rangel,
  *Nature Neuroscience*, 2010) shows that fixations causally shape value comparison; Pieters
  and Wedel's work on attention to advertising and packaging; Shimojo's gaze cascade. This
  is the theoretical reason to expect revisits and hesitation to carry information about a
  decision.
- *Webcam attention analytics at scale* (EyeQuant, RealEye) sell heatmaps and attention
  scores; predictive saliency models (DeepGaze) estimate where people will look without a
  camera at all.

**What this project adds, precisely.**

- Instrumentation where areas of interest are *declared in the interface code* (SwiftUI
  modifiers) and every gaze sample is attributed on the device, with the raw coordinate
  kept, so the semantic and geometric levels can be reconciled after the fact. Lab tools
  draw AOIs on recordings; here the app knows what is on screen.
- The explicit pairing of each tap with the element's frame and the eyes' relation to it
  (first look, hesitation, on-element or not), which turns every tap into a small
  validation of the gaze and a behavioural measurement at once.
- A quality gate defined from the data (share of tracked time in fixations) rather than
  from vendor accuracy claims, and the demonstration that without it the stability analysis
  is dominated by bad sessions.

**What it does not claim.** Any relation between the fingerprint and purchase, preference,
confusion or friction. H2 in the thesis is a hypothesis with no evidence yet.

---

## 5. Attentive, adaptive and generative interfaces

**What exists.**

- *Attentive user interfaces* (Vertegaal, *CACM*, 2003) and gaze-contingent displays
  (Duchowski, 2007) established interfaces that respond to where a person looks. Gaze
  input for interaction on phones was surveyed by Khamis, Alt and Bulling (MobileHCI 2018),
  and EyeMU (Kong et al., CHI 2021) combined gaze and motion gestures on a phone.
- *Affective computing* (Picard, 1997 onwards) infers emotional state from physiological
  and facial signals. This project is deliberately not in that tradition and records
  blend-shape coefficients only as numbers, never as affect labels.
- *Generative UI* with large language models, in which an agent composes the interface at
  runtime from components (Vercel's AI SDK generative UI, 2024; Google's generative UI
  research, 2025; assorted "agentic UI" frameworks), takes its input from text and
  explicit events. Perceptive input to such an agent, gaze and hesitation in particular,
  is discussed but, to our knowledge, not instrumented and validated in the open.

**What this project adds, precisely.**

- The framing of the fingerprint as a candidate *input layer* for an agent that decides
  whether and how to adapt a generative interface, with the discipline that the layer must
  be measured, quality-gated and shown to carry information before any agent is built.
  The agent does not exist yet; the roadmap places it after cross-person evidence.
- The principle, held throughout the code and data, that the sensing layer records
  observations and never interpretations, so that whatever the agent later infers is
  visibly a separate step that can be audited or switched off.

**What it does not claim.** That adaptation helps. H3 and H4 are untested, and the project's
own thesis document says a negative result is a valid outcome.

---

## 6. The novelty boundary, stated once

Inside the line, what this project can claim as its own contribution as of September 2026:

1. An open, documented, tested iPhone instrument that turns TrueDepth face tracking into
   screen gaze accurate enough to tell which element a person is looking at, with the
   physics of the calibration made explicit (head at unit gain, eye corrected).
2. The measurement that ARKit under-reports eye rotation by about five times, and the
   method that recovers it on device with a small learned model.
3. Validation of phone gaze against tapped *elements*, and the finding that fingertip
   validation overstates error on real interfaces.
4. A multi-layer, unit-defined, quality-gated fingerprint computed from one event stream,
   with the stable-versus-state question posed and a first single-person answer.
5. A repeated-measures protocol that measures condition effects against day-to-day spread,
   and the tooling to run it with no manual data handling.
6. The observable-only discipline as an engineering constraint rather than a slogan, and
   the placement of the agent after the evidence.

Outside the line, what is prior art and is used, not claimed: appearance-based gaze
estimation, phone eye tracking, eye-movement individuality, touch biometrics, AOI metrics,
attention-and-choice theory, attentive interfaces, generative UI.

Not yet earned, and to be said plainly whenever the project is described: anything about
people in general; anything about emotion, intent, preference or friction; identification
of individuals; benefit from adaptation.

---

## 7. Open-source and dataset references for the record

| Resource | What it is | Relation to this project |
| --- | --- | --- |
| MPIIGaze / MPIIFaceGaze (MPI Informatics) | Laptop webcam gaze datasets, 15 people, with head pose | Training data for the bundled eye model; CC BY-NC-SA 4.0 |
| GazeCapture / iTracker (MIT CSAIL) | Phone and tablet gaze dataset, ~1,450 people | The right phone-domain dataset; request pending; not yet used |
| ETH-XGaze, Gaze360, RT-GENE, EVE | Large gaze datasets with wide head pose | Candidates for head-pose robustness if Phase 4 shows drift |
| GazeBase (Texas State) | High-rate eye-movement biometrics dataset | Reference for what "gaze biometrics" means; not comparable hardware |
| WebGazer (Brown) | Browser webcam gaze with click self-calibration | Closest relative of gaze-before-tap; browser, not phone |
| OpenFace, MediaPipe Iris, L2CS-Net | Open landmark and gaze models | Alternatives to Vision landmarks and to the bundled model |
| Apple ARKit face tracking, Vision framework | The sensing substrate | Used as is; its limits measured and documented |
| Holmqvist et al. 2011; Salvucci & Goldberg 2000 | Eye-tracking measures; I-DT fixation detection | Feature definitions and the fixation algorithm |

---

## 8. How to keep this map honest

When a result is written up, each claim in §6 should be checked against this list again,
and against a fresh search, because the generative-UI corner of the map moves monthly.
When prior work is found that crosses a line, edit §6 and note the date. The map is part
of the research record, and a corrected map is worth more than a flattering one.
