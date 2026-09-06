---
name: fingerprint-data-modeling
description: Design the Interaction Fingerprint dataset: the normalized Codable event schema, SQLite storage with GRDB, JSON export format, versioning, and the aggregate features (dwell, revisits, transitions, hesitation). Use for Models/, Storage/, Fingerprint/ and any schema question. Priority: now.
---
# Data modeling: JSON, SQLite, and the fingerprint schema

## Principle

One normalized event type for both sensor samples and product events. Raw, observable values only.
Aggregated features are computed later from the events and stored separately, never in place of them.

## Event schema (v1)

```json
{
  "schemaVersion": 1,
  "sessionID": "8136AD7E-...",
  "sequence": 1042,
  "timestamp": 1725543210.42,
  "screen": "product_detail",
  "productID": "sku_123",
  "event": "gaze",
  "target": "price",
  "gazeX": 0.61,
  "gazeY": 0.38,
  "isTracked": true,
  "durationMs": null,
  "signals": {
    "eyeBlink_L": 0.03, "eyeBlink_R": 0.04,
    "eyeSquint_L": 0.21, "eyeSquint_R": 0.19,
    "eyeWide_L": 0.10, "eyeWide_R": 0.11,
    "browInnerUp": 0.05, "browOuterUp_L": 0.02, "browOuterUp_R": 0.02
  },
  "head": { "x": 0.01, "y": -0.02, "z": -0.35, "pitch": 0.05, "yaw": -0.02, "roll": 0.00 }
}
```

- `timestamp` is seconds on the device monotonic clock. The session record stores
  `startedAt` (wall clock, ISO 8601) and `startedAtUptime` so analysis can convert.
- Optional fields are `null`, never omitted, so pandas gets a stable column set. Swift's
  synthesised `Codable` omits nil optionals, so `FaceSample` writes its encoder by hand.
- Blend-shape names are the exact `ARFaceAnchor.BlendShapeLocation` raw values, which are
  **not** the Swift case names. `.eyeBlinkLeft` has the raw value `eyeBlink_L`. The setup
  guide lists the Swift names; exports and pandas columns use the raw values. This is
  pinned by a test in `InteractionFingerprintFeatureTests`.
- Add fields only with a `schemaVersion` bump and a note in `Research/schema-changelog.md`.

## Swift types

- `struct FingerprintEvent: Codable, Sendable` in `Models/`. Use an `enum EventKind: String, Codable`.
- `struct Session: Codable` with `id`, `appID`, `appVersion`, `startedAt`, `endedAt`,
  `device` (model, OS, screen size in points and scale), `calibration` (residuals), `notes`.
- Keep types free of SwiftUI and ARKit imports so they compile in tests on macOS.

## SQLite with GRDB

- Dependency: `groue/GRDB.swift` 7.x, declared in `InteractionFingerprintPackage/Package.swift`.
- Tables: `session` (one row per session) and `event` (one row per event, JSON column for
  `signals` and `head`, or flat columns for the nine V0 blend shapes; flat is easier for SQL).
- Write in batches inside one transaction every second. Index `event(sessionID, sequence)`.
- Database file in the app's Application Support directory, excluded from iCloud backup.

## JSON export

- One file per session: `session_<uuid>.json` containing `{ "session": {...}, "events": [...] }`.
- Also write newline-delimited `events_<uuid>.jsonl` for large sessions; pandas reads it with
  `pd.read_json(path, lines=True)`.
- Export to the Documents directory so Files app and Finder can access it. Offer a share sheet.

## Aggregate features (computed in Analysis/, mirrored later in Fingerprint/)

dwell time per target, revisit count per target, gaze transition matrix between targets,
backtracking count (`back` events), attention distribution (share of tracked time per target),
hesitation duration (time between last gaze on an actionable target and the tap), product
comparison count (distinct products viewed before selection). Each feature has a written
definition with units in `docs/product/12-FINGERPRINT-FEATURES.md` before it is coded.

## Related
`interaction-instrumentation`, `python-pandas`, `eye-tracking-concepts`.
