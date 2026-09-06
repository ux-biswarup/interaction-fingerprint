# 13 — The desk: live dashboard and automatic transfer

The phone records; the Mac watches and keeps. This document describes the link between
them, decided and built 6 September 2026, so that a recording can be watched as it happens
on the desktop and so that no file ever has to be copied off the phone by hand.

## 1. What it does

- **Live.** While a session records, the phone streams every event to the Mac four times a
  second. The dashboard at `http://localhost:8765` shows the gaze on a drawing of the screen
  with the areas of interest, the fixations found so far, the taps and the elements they
  hit, the face readouts, and the fingerprint of the session so far, recomputed every two
  seconds from the same code that produces the final one (`12-FINGERPRINT-FEATURES.md`).
- **Kept.** The desk writes what arrives into `Data/` in exactly the files the app itself
  exports: `session_<id>.jsonl` line by line as events come in, `session_<id>.json` when the
  session ends, `calibration_<t>.json` when a calibration is accepted, and the derived
  fingerprint under `Data/derived/`. Nothing else has to happen for the analysis tools to
  see a new recording.
- **Caught up.** Whenever the link comes up, the phone lists the sessions and calibrations
  it holds; the desk answers with the ones it lacks; the phone uploads them. A session
  recorded on the train arrives the moment the phone is back on the home Wi-Fi with the
  desk running.
- **Found by itself.** The desk advertises a Bonjour service, `_ifp._tcp`, on the local
  network. The phone browses for it. No address is typed anywhere. The instrument screen
  shows the link's state and a switch to turn it off.

## 2. What it does not do

- It never leaves the local network. There is no server, no account, no cloud. The Mac and
  the phone have to be on the same Wi-Fi.
- It is not the record. The phone writes its own files exactly as before, and if the desk
  is down the phone drops nothing it would otherwise have kept. The link's outbound queue is
  bounded (four thousand messages); if the desk is unreachable for long the oldest live
  batches are discarded, and the complete session arrives by upload when the session ends
  and the link is back.
- Known, cosmetic: at connect the desk sometimes logs two sockets from the phone, one per
  IPv6 address, and one closes within a second. Nothing is duplicated on disk, since
  sessions are keyed by id, but the cause is not yet pinned down.
- It does not decide anything. The dashboard shows numbers; the numbers are the ones
  defined in `12-FINGERPRINT-FEATURES.md`; nothing on it names a state of mind.

## 3. Running it

```bash
pip3 install --user aiohttp zeroconf           # once
python3 Analysis/dashboard/server.py --open    # then leave it running
```

The phone connects within a few seconds of being on the same network with the app open
(first time, iOS asks for permission to find devices on the local network). The instrument
screen's last line reads `Desk · connected to Interaction Fingerprint Desk`.

## 4. Protocol

One WebSocket from phone to desk, `ws://<desk>:8765/ingest`, text frames, each a JSON
envelope `{"type": ..., "payload": ...}` with the payload's own JSON inserted verbatim so a
five-megabyte session document is never decoded and re-encoded on the phone.

| Type | Direction | Payload |
| --- | --- | --- |
| `hello` | phone → desk | device, protocol version |
| `have` | phone → desk | `sessions` (ids), `calibrations` (file names) the phone holds |
| `missing` | desk → phone | the subset of those the desk lacks |
| `upload` | phone → desk | `kind` (`session` or `calibration`), `id`, and the file's contents as payload |
| `session_start` | phone → desk | the `SessionRecord` |
| `events` | phone → desk | an array of `FingerprintEvent`, at most 250 ms of them |
| `areas` | phone → desk | the areas of interest laid out, frames normalised to the viewport |
| `session_end` | phone → desk | the `SessionRecord` with `endedAt` |
| `calibration` | phone → desk | the `CalibrationDocument` |

Browsers connect to `/live` and receive a snapshot on connect, then `phone`,
`session_start`, `events` (gaze rows compacted to position, quality, screen, area and the
nine expression coefficients), `fingerprint`, `session_end`, `areas`, `calibration` and
`uploaded`. `GET /api/sessions` lists the sessions on disk with their flattened
fingerprints; `GET /api/session/<id>` returns one fingerprint document.

## 5. Where it lives

- Phone: `Instrumentation/DeskLink.swift` (browsing, connection, queue, catch-up),
  `EventRecorder.sink` (every appended event), `StudySessionView` (start, events, areas,
  end), `ContentView` (calibrations, the readout and switch). `NSBonjourServices` and
  `NSLocalNetworkUsageDescription` in `Config/InteractionFingerprint-Info.plist`, merged into
  the generated plist and excluded from the bundle's resources.
- Mac: `Analysis/dashboard/server.py` (aiohttp, zeroconf), `Analysis/dashboard/static/`
  (the page, no build step, no framework).
- Tests: `Analysis/tests/test_dashboard.py` streams a session into a temporary desk and
  checks the files; the Swift tests check the envelope format and that the recorder's sink
  sees every event.

## 6. Privacy note

The stream carries what the files carry: observable signals, screen coordinates, blend-shape
coefficients, no images. Recordings of participants remain in `Data/`, which is never
committed. When participants are recorded (Phase 4), the desk runs on the researcher's own
machine on a network the researcher controls; the phone's switch is visible so a participant
can be shown that the link is off if they ask.
