#!/usr/bin/env python3
"""The desk: receives recordings from the phone and shows them live in the browser.

    python3 Analysis/dashboard/server.py            # then open http://localhost:8765
    python3 Analysis/dashboard/server.py --open     # opens the browser for you

Advertises itself on the local network as a Bonjour service (`_ifp._tcp`) so the phone
finds it by itself. Everything the phone streams is written into `Data/` in exactly the
files the app itself exports (`session_<id>.jsonl` as events arrive, `session_<id>.json`
when the session ends, `calibration_<t>.json`), and the fingerprint of the running session
is recomputed every couple of seconds for the dashboard. Sessions recorded while the phone
was away are uploaded when it reconnects: the phone lists what it holds, the desk answers
with what it lacks. Protocol: `docs/product/13-DESK-LINK.md`.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import socket
import sys
import time
import webbrowser
from pathlib import Path

import pandas as pd
from aiohttp import WSMsgType, web

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fingerprint import features as ft  # noqa: E402
from fingerprint import load  # noqa: E402

log = logging.getLogger("desk")
TICKER = web.AppKey("ticker", asyncio.Task)
SERVICE_TYPE = "_ifp._tcp.local."
SERVICE_NAME = "Interaction Fingerprint Desk"
FINGERPRINT_INTERVAL = 2.0
GAZE_LIVE_KEYS = ("timestamp", "x", "y", "quality", "screen", "target", "productID", "eyeZ", "eyesOpen")
EXPRESSION = ft.EXPRESSION


class Desk:
    """Everything the server knows: the files on disk, the phone's live session, the browsers."""

    def __init__(self, data_dir: Path):
        self.data = data_dir
        self.derived = data_dir / "derived"
        self.derived.mkdir(parents=True, exist_ok=True)
        self.browsers: set[web.WebSocketResponse] = set()
        self.phones: set[web.WebSocketResponse] = set()
        self.live: dict | None = None      # session, events, areas, file, computed_at, event_count_at_compute
        self.areas: list[dict] = []
        self.summaries: dict[str, dict] = {}   # session id -> flattened fingerprint + meta

    # ------------------------------------------------------------ files on disk

    def session_ids(self) -> set[str]:
        return {p.stem[len("session_"):] for p in self.data.glob("session_*.json")}

    def calibration_names(self) -> set[str]:
        return {p.name for p in self.data.glob("calibration_*.json")}

    def load_summaries(self) -> None:
        """Fingerprints of every session on disk, computing the missing ones."""
        for path in sorted(self.data.glob("session_*.json")):
            sid = path.stem[len("session_"):]
            if sid in self.summaries:
                continue
            derived = self.derived / f"fingerprint_{sid}.json"
            try:
                if derived.exists() and derived.stat().st_mtime >= path.stat().st_mtime:
                    fp = json.loads(derived.read_text())
                else:
                    fp = self.compute_fingerprint(path)
                self.summaries[sid] = self.summary(fp)
            except Exception as error:  # a bad file must not take the desk down
                log.warning("could not fingerprint %s: %s", path.name, error)

    def compute_fingerprint(self, path: Path) -> dict:
        session, events = load.load_session(path)
        fp = ft.fingerprint(session, events)
        (self.derived / f"fingerprint_{session.get('id', path.stem)}.json").write_text(json.dumps(fp, indent=1, default=float))
        return fp

    @staticmethod
    def summary(fp: dict) -> dict:
        flat = ft.flatten(fp)
        clean = {k: (None if isinstance(v, float) and v != v else v) for k, v in flat.items()}
        return dict(id=fp["session"]["id"], startedAt=fp["session"].get("startedAtWallClock"), flat=clean)

    def fingerprint_document(self, sid: str) -> dict | None:
        path = self.derived / f"fingerprint_{sid}.json"
        return json.loads(path.read_text()) if path.exists() else None

    # ------------------------------------------------------------ the phone's stream

    def start_session(self, session: dict) -> None:
        sid = session.get("id", f"unknown_{int(time.time())}")
        path = self.data / f"session_{sid}.jsonl"
        self.live = dict(session=session, events=[], file=path.open("w"), started=time.time(),
                         computed_events=0, fingerprint=None)
        log.info("session %s started", sid[:8])

    def add_events(self, events: list[dict]) -> None:
        if self.live is None:
            # A stream that started before the desk did: adopt it with what we know.
            self.start_session({"id": f"partial_{int(time.time())}"})
        self.live["events"].extend(events)
        f = self.live["file"]
        for e in events:
            f.write(json.dumps(e, separators=(",", ":")) + "\n")
        f.flush()

    def end_session(self, session: dict | None) -> dict | None:
        if self.live is None:
            return None
        live, self.live = self.live, None
        live["file"].close()
        record = session or live["session"]
        sid = record.get("id", "unknown")
        events = live["events"]
        (self.data / f"session_{sid}.json").write_text(json.dumps({"session": record, "events": events}, separators=(",", ":")))
        try:
            fp = ft.fingerprint(record, self.frame(events))
            (self.derived / f"fingerprint_{sid}.json").write_text(json.dumps(fp, indent=1, default=float))
            self.summaries[sid] = self.summary(fp)
            log.info("session %s saved, %d events", sid[:8], len(events))
            return fp
        except Exception as error:
            log.warning("fingerprint of %s failed: %s", sid[:8], error)
            return None

    def save_calibration(self, document: dict) -> str:
        created = document.get("createdAt") or time.time()
        name = f"calibration_{int(created)}.json"
        (self.data / name).write_text(json.dumps(document, separators=(",", ":")))
        log.info("calibration %s saved", name)
        return name

    def save_upload(self, kind: str, ident: str, payload: dict) -> str | None:
        if kind == "session":
            sid = ident
            if sid in self.session_ids():
                return None
            (self.data / f"session_{sid}.json").write_text(json.dumps(payload, separators=(",", ":")))
            with (self.data / f"session_{sid}.jsonl").open("w") as f:
                for e in payload.get("events", []):
                    f.write(json.dumps(e, separators=(",", ":")) + "\n")
            try:
                fp = self.compute_fingerprint(self.data / f"session_{sid}.json")
                self.summaries[sid] = self.summary(fp)
            except Exception as error:
                log.warning("fingerprint of uploaded %s failed: %s", sid[:8], error)
            log.info("session %s uploaded (%d events)", sid[:8], len(payload.get("events", [])))
            return f"session_{sid}"
        if kind == "calibration":
            name = ident if ident.startswith("calibration_") else f"calibration_{ident}"
            if not name.endswith(".json"):
                name += ".json"
            (self.data / name).write_text(json.dumps(payload, separators=(",", ":")))
            log.info("calibration %s uploaded", name)
            return name
        return None

    def missing(self, holdings: dict) -> dict:
        have_sessions, have_cal = self.session_ids(), self.calibration_names()
        return dict(
            type="missing",
            sessions=[s for s in holdings.get("sessions", []) if s not in have_sessions],
            calibrations=[c for c in holdings.get("calibrations", []) if c not in have_cal],
        )

    # ------------------------------------------------------------ live fingerprint

    @staticmethod
    def frame(events: list[dict]) -> pd.DataFrame:
        frame = pd.DataFrame(events)
        metrics = pd.json_normalize(frame["metrics"]) if "metrics" in frame else pd.DataFrame(index=frame.index)
        signals = pd.json_normalize(frame["signals"]) if "signals" in frame else pd.DataFrame(index=frame.index)
        frame = pd.concat([frame.drop(columns=[c for c in ("metrics", "signals") if c in frame]), metrics, signals], axis=1)
        frame["t"] = frame["timestamp"] - frame["timestamp"].min()
        return frame.sort_values("sequence").reset_index(drop=True) if "sequence" in frame else frame

    def live_fingerprint(self) -> dict | None:
        """Recompute when there is something new; None when nothing changed."""
        live = self.live
        if live is None or len(live["events"]) == live["computed_events"] or len(live["events"]) < 30:
            return None
        live["computed_events"] = len(live["events"])
        fp = ft.fingerprint(live["session"], self.frame(list(live["events"])))
        live["fingerprint"] = fp
        return fp

    @staticmethod
    def compact_gaze(e: dict) -> dict:
        row = {k: e.get(k) for k in GAZE_LIVE_KEYS if k in e}
        row["event"] = "gaze"
        metrics = e.get("metrics") or {}
        row["eyeZ"] = metrics.get("eyeZ")
        row["disturbance"] = metrics.get("deviceDisturbanceMm")
        signals = e.get("signals") or {}
        row["signals"] = {k: signals.get(k) for k in EXPRESSION if k in signals}
        return row

    def live_snapshot(self) -> dict | None:
        if self.live is None:
            return None
        live = self.live
        fp = live["fingerprint"]
        return dict(
            session=live["session"], eventCount=len(live["events"]), started=live["started"],
            areas=self.areas, fingerprint=self.trim(fp) if fp else None,
            recent=[self.compact_gaze(e) if e.get("event") == "gaze" else e for e in live["events"][-400:]],
        )

    @staticmethod
    def trim(fp: dict) -> dict:
        """The fingerprint without the full sample tables, for the wire."""
        out = {k: v for k, v in fp.items() if k not in ("fixation_list",)}
        out["fixation_list"] = fp["fixation_list"][-60:]
        return out


# ---------------------------------------------------------------- web

async def broadcast(desk: Desk, message: dict) -> None:
    dead = []
    text = json.dumps(message, default=float)
    for ws in list(desk.browsers):
        try:
            await ws.send_str(text)
        except Exception:
            dead.append(ws)
    for ws in dead:
        desk.browsers.discard(ws)


async def ingest(request: web.Request) -> web.WebSocketResponse:
    """The phone's socket."""
    desk: Desk = request.app["desk"]
    ws = web.WebSocketResponse(max_msg_size=256 << 20, heartbeat=20)
    await ws.prepare(request)
    desk.phones.add(ws)
    log.info("phone connected from %s", request.remote)
    await broadcast(desk, dict(type="phone", connected=True))
    try:
        async for msg in ws:
            if msg.type != WSMsgType.TEXT:
                continue
            try:
                message = json.loads(msg.data)
            except json.JSONDecodeError:
                continue
            kind, payload = message.get("type"), message.get("payload")
            if kind == "session_start" and isinstance(payload, dict):
                desk.start_session(payload)
                await broadcast(desk, dict(type="session_start", session=payload, areas=desk.areas))
            elif kind == "events" and isinstance(payload, list):
                desk.add_events(payload)
                rows = [desk.compact_gaze(e) if e.get("event") == "gaze" else e for e in payload]
                await broadcast(desk, dict(type="events", rows=rows, eventCount=len(desk.live["events"]) if desk.live else 0))
            elif kind == "session_end":
                fp = desk.end_session(payload if isinstance(payload, dict) else None)
                await broadcast(desk, dict(type="session_end", fingerprint=desk.trim(fp) if fp else None,
                                           sessions=sorted(desk.summaries.values(), key=lambda s: s.get("startedAt") or 0, reverse=True)))
            elif kind == "calibration" and isinstance(payload, dict):
                name = desk.save_calibration(payload)
                await broadcast(desk, dict(type="calibration", name=name, model=payload.get("model")))
            elif kind == "areas" and isinstance(payload, list):
                desk.areas = payload
                await broadcast(desk, dict(type="areas", areas=payload))
            elif kind == "have" and isinstance(payload, dict):
                reply = desk.missing(payload)
                await ws.send_str(json.dumps(reply))
                log.info("phone holds %d sessions, desk lacks %d", len(payload.get("sessions", [])), len(reply["sessions"]))
            elif kind == "upload" and isinstance(payload, dict):
                saved = desk.save_upload(message.get("kind", ""), message.get("id", ""), payload)
                if saved:
                    await broadcast(desk, dict(type="uploaded", name=saved,
                                               sessions=sorted(desk.summaries.values(), key=lambda s: s.get("startedAt") or 0, reverse=True)))
    finally:
        desk.phones.discard(ws)
        log.info("phone disconnected")
        await broadcast(desk, dict(type="phone", connected=len(desk.phones) > 0))
    return ws


async def live(request: web.Request) -> web.WebSocketResponse:
    """A browser's socket: a full snapshot on connect, then whatever happens."""
    desk: Desk = request.app["desk"]
    ws = web.WebSocketResponse(heartbeat=20)
    await ws.prepare(request)
    desk.browsers.add(ws)
    await ws.send_str(json.dumps(dict(
        type="hello", phone=len(desk.phones) > 0,
        sessions=sorted(desk.summaries.values(), key=lambda s: s.get("startedAt") or 0, reverse=True),
        live=desk.live_snapshot(),
    ), default=float))
    try:
        async for msg in ws:
            if msg.type == WSMsgType.ERROR:
                break
    finally:
        desk.browsers.discard(ws)
    return ws


async def api_sessions(request: web.Request) -> web.Response:
    desk: Desk = request.app["desk"]
    return web.json_response(sorted(desk.summaries.values(), key=lambda s: s.get("startedAt") or 0, reverse=True))


async def api_session(request: web.Request) -> web.Response:
    desk: Desk = request.app["desk"]
    fp = desk.fingerprint_document(request.match_info["sid"])
    if fp is None:
        raise web.HTTPNotFound()
    return web.json_response(fp, dumps=lambda o: json.dumps(o, default=float))


async def index(request: web.Request):
    """The page for browsers; the phone's socket when the request is a WebSocket upgrade.

    The phone reaches the desk through a Bonjour endpoint, which carries no path, so its
    connection arrives at the root."""
    if request.headers.get("Upgrade", "").lower() == "websocket":
        return await ingest(request)
    return web.FileResponse(Path(__file__).parent / "static" / "index.html")


async def fingerprint_ticker(app: web.Application) -> None:
    desk: Desk = app["desk"]
    loop = asyncio.get_running_loop()
    while True:
        await asyncio.sleep(FINGERPRINT_INTERVAL)
        try:
            fp = await loop.run_in_executor(None, desk.live_fingerprint)
        except Exception as error:
            log.warning("live fingerprint failed: %s", error)
            continue
        if fp:
            await broadcast(desk, dict(type="fingerprint", fingerprint=desk.trim(fp)))


def local_addresses() -> list[str]:
    addresses = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addresses.add(info[4][0])
    except socket.gaierror:
        pass
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("192.0.2.1", 9))  # no traffic is sent; this just picks the outbound interface
        addresses.add(probe.getsockname()[0])
        probe.close()
    except OSError:
        pass
    return sorted(a for a in addresses if not a.startswith("127."))


def advertise(port: int):
    """Bonjour registration so the phone finds the desk without an address."""
    try:
        from zeroconf import ServiceInfo, Zeroconf
    except ImportError:
        log.warning("zeroconf is not installed (pip install zeroconf); the phone cannot find this desk by itself")
        return None
    addresses = local_addresses()
    if not addresses:
        log.warning("no local network address found; is Wi-Fi on?")
        return None
    zc = Zeroconf()
    info = ServiceInfo(
        SERVICE_TYPE, f"{SERVICE_NAME}.{SERVICE_TYPE}", port=port,
        addresses=[socket.inet_aton(a) for a in addresses],
        server=f"{socket.gethostname().split('.')[0]}.local.",
        properties={"protocol": "1"},
    )
    zc.register_service(info)
    log.info("advertising %s on %s port %d", SERVICE_TYPE, ", ".join(addresses), port)
    return zc, info


def make_app(data_dir: Path) -> web.Application:
    app = web.Application()
    desk = Desk(data_dir)
    desk.load_summaries()
    app["desk"] = desk
    app.router.add_get("/", index)
    app.router.add_get("/ingest", ingest)
    app.router.add_get("/live", live)
    app.router.add_get("/api/sessions", api_sessions)
    app.router.add_get("/api/session/{sid}", api_session)
    app.router.add_static("/static", Path(__file__).parent / "static")

    async def start_ticker(app):
        app[TICKER] = asyncio.create_task(fingerprint_ticker(app))

    async def stop_ticker(app):
        app[TICKER].cancel()

    app.on_startup.append(start_ticker)
    app.on_cleanup.append(stop_ticker)
    return app


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data", default=str(Path(__file__).resolve().parents[2] / "Data"))
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--open", action="store_true", help="open the dashboard in the browser")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S")
    data_dir = Path(args.data)
    data_dir.mkdir(parents=True, exist_ok=True)
    app = make_app(data_dir)
    registration = advertise(args.port)
    url = f"http://localhost:{args.port}"
    log.info("dashboard at %s, writing to %s", url, data_dir)
    if args.open:
        webbrowser.open(url)
    try:
        web.run_app(app, port=args.port, print=None)
    finally:
        if registration:
            zc, info = registration
            zc.unregister_service(info)
            zc.close()


if __name__ == "__main__":
    main()
