# Interaction Fingerprint Model

## Definition
A structured representation of how a person interacts with a digital experience over time.

## Signal classes

### 1. Explicit
tap, click, scroll, search, back, add-to-cart, purchase, select, submit

### 2. Behavioral
dwell time, revisit count, backtracking, repeated comparison, navigation loops, hesitation, task completion time

### 3. Perceptive
gaze position, gaze transitions, blink, eye squint, eye openness, eyebrow movement, head position/rotation

### 4. Contextual
screen, product ID, UI area, task, session stage, previous actions

## Pipeline

`RAW SIGNAL → EVENT → FEATURE → PATTERN → INFERENCE → INTERVENTION`

Example:

```text
eyeSquint = 0.42
+ gaze dwell = 3.8s
+ price revisit = 2
+ no CTA
        ↓
possible decision friction
        ↓
agent evaluates intervention
        ↓
generate comparison/value explanation
```

## Core rule
Never store `confused=true` as if confusion were directly measured.

Store raw observations and derive interpretations separately.
