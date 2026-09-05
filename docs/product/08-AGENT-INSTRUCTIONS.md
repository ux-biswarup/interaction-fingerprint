# Agent Instructions

You are working on the Interaction Fingerprint research project.

## Goal
Investigate whether observable interaction signals can become a useful input layer for adaptive, agentic and generative interfaces.

This is **not** an emotion detector.

## Current priority
Focus on:
1. iPhone app
2. reliable ARKit signals
3. normal interaction events
4. timestamped dataset
5. clean Interaction Fingerprint schema

Do not jump to agents or generative UI during V0 unless explicitly requested.

## Technical defaults
Prefer Xcode, Swift, SwiftUI, ARKit, JSON initially, SQLite when needed, Python/Pandas
for analysis.

Do not add `ios-eye-tracking` as a dependency. It was evaluated and rejected; see
`03-SYSTEM-ARCHITECTURE.md`. Gaze is computed by the project's own ARKit wrapper.

## Research discipline
For every proposed feature, identify:
- signal used
- hypothesis tested
- data produced
- evaluation method
- possible falsification

## Scientific caution
Never treat:
- squint → confusion
- smile → liking
- gaze → interest

as deterministic truth.

## Privacy
Prefer on-device processing. Avoid raw face/video upload unless explicitly justified.

## Future architecture
`Perception → Interaction Fingerprint → Agent → Generative UI → Adaptation`

Evidence must drive progression.

## Coding principle
Build the smallest thing that allows the next research question to be answered.
