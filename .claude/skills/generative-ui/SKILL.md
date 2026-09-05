---
name: generative-ui
description: Dynamically generate or adapt the UI in response to an agent decision, within safe, enumerated bounds. Use only after the agent's decisions have measurable value. Covers component palettes, constraints, and evaluation. Priority: later.
---
# Generative UI (later stage)

**Gate:** agent decisions exist, are logged, and have shown an effect versus control.

## Constrained generation, not free-form

- Define a **palette** of adaptable components: emphasis level of an element, order of a list,
  presence of a comparison card, amount of detail shown. Each has a finite set of states.
- The generator (rule-based first, model-based later) outputs a declarative layout spec in JSON.
  SwiftUI renders it. The spec is validated against a schema before rendering.
- Every generated layout is logged as a `ui_variant` event with its full spec, so gaze AOIs can
  be reconstructed and the analysis knows exactly what the participant saw.
- Layout must stay stable for the duration of a fixation. Change between tasks or on explicit
  moments (screen transition), never mid-scroll.

## Keep AOIs measurable

Generated layouts must still assign stable `target` identifiers so dwell and revisits remain
comparable across variants. New identifiers require a schema changelog entry.

## Evaluation

Compare each variant against the static control on the pre-registered outcome. Generated UI is
a treatment like any other; see `ux-research-experiment-design` and `basic-statistics`.

## If using an LLM to propose layouts

Use the latest Claude model via the Claude API with a strict JSON schema for the layout spec,
low temperature, and offline generation of a fixed variant set that is then reviewed. Never
generate live in front of a participant in the first study. Log prompts and outputs.

## Related
`agent-design`, `llm-ai-evaluation`, `swift-swiftui`.
