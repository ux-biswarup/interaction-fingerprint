# Interaction Fingerprint — Project Context

## What we are building
A design-research project exploring whether interfaces can understand users through more than explicit actions.

The iPhone/TrueDepth prototype captures observable signals such as gaze, attention, eye movement and selected facial movement, combines them with normal UI behavior, and represents the result as an **Interaction Fingerprint**.

Long-term hypothesis:

> Perception + Agentic reasoning + Generative UI can create interfaces that adapt to the user's interaction state rather than only responding to explicit commands.

## Important framing
This is **not an emotion-recognition project**.

Separate:
- observable signal
- behavioral pattern
- inferred state
- product action

Example: `eye squint = 0.4` is an observation; `possible friction` is an inference; `show a simpler comparison` is a product response.

Never present an inferred emotion as fact.

## Current state
Repository: `interaction-fingerprint`
Platform: iPhone with supported TrueDepth hardware
Phase: V0 sensing and instrumentation

Immediate goal:

`iPhone → ARKit → signals → timestamped events → Interaction Fingerprint dataset`

Do not build the agent or generative UI until sensing and measurement work reliably.
