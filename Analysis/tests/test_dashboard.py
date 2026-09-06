import json
import sys
from pathlib import Path

import pytest
import pytest_asyncio
from aiohttp.test_utils import TestClient, TestServer

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dashboard import server as desk_server  # noqa: E402

RATE = 60


def gaze(t, x, y, screen="product_detail"):
    return dict(event="gaze", sequence=int(t * RATE), timestamp=t, quality="good", eyesOpen=True, screen=screen, productID="sku_1",
                target="title", x=x, y=y, metrics=dict(eyeZ=-0.31), signals=dict(eyeBlink_L=0.02))


pytestmark = pytest.mark.asyncio


@pytest_asyncio.fixture
async def client(tmp_path):
    app = desk_server.make_app(tmp_path)
    async with TestClient(TestServer(app)) as c:
        yield c, tmp_path


async def test_a_streamed_session_lands_on_disk_as_the_app_would_write_it(client):
    c, data = client
    async with c.ws_connect("/ingest") as phone, c.ws_connect("/live") as browser:
        hello = json.loads((await browser.receive()).data)
        assert hello["type"] == "hello" and hello["phone"] is True
        session = dict(id="ABC123", appID="test", startedAt=100.0)
        await phone.send_str(json.dumps(dict(type="session_start", payload=session)))
        events = [dict(event="session_start", sequence=1, timestamp=100.0), dict(event="screen_appear", sequence=2, timestamp=100.0, screen="product_detail", productID="sku_1")]
        events += [gaze(100.0 + i / RATE, 0.5, 0.3) for i in range(60)]
        await phone.send_str(json.dumps(dict(type="events", payload=events)))
        await phone.send_str(json.dumps(dict(type="session_end", payload=session)))
        kinds = []
        while len(kinds) < 3:
            kinds.append(json.loads((await browser.receive()).data)["type"])
        assert kinds == ["session_start", "events", "session_end"]
    doc = json.loads((data / "session_ABC123.json").read_text())
    assert doc["session"]["id"] == "ABC123" and len(doc["events"]) == 62
    lines = (data / "session_ABC123.jsonl").read_text().splitlines()
    assert len(lines) == 62 and json.loads(lines[2])["event"] == "gaze"
    fp = json.loads((data / "derived" / "fingerprint_ABC123.json").read_text())
    assert fp["fixations"]["count"] == 1
    sessions = await (await c.get("/api/sessions")).json()
    assert sessions[0]["id"] == "ABC123"


async def test_the_desk_asks_only_for_what_it_lacks_and_stores_uploads(client):
    c, data = client
    (data / "session_HAVE.json").write_text(json.dumps({"session": {"id": "HAVE"}, "events": []}))
    (data / "calibration_1.json").write_text("{}")
    async with c.ws_connect("/ingest") as phone:
        await phone.send_str(json.dumps(dict(type="have", payload=dict(sessions=["HAVE", "NEW"], calibrations=["calibration_1.json", "calibration_2.json"]))))
        reply = json.loads((await phone.receive()).data)
        assert reply == dict(type="missing", sessions=["NEW"], calibrations=["calibration_2.json"])
        events = [dict(event="session_start", sequence=1, timestamp=1.0)] + [gaze(1 + i / RATE, 0.4, 0.4) for i in range(30)]
        await phone.send_str(json.dumps(dict(type="upload", kind="session", id="NEW", payload={"session": {"id": "NEW"}, "events": events})))
        await phone.send_str(json.dumps(dict(type="upload", kind="calibration", id="calibration_2.json", payload={"model": None, "points": []})))
        await phone.send_str(json.dumps(dict(type="have", payload=dict(sessions=["NEW"], calibrations=["calibration_2.json"]))))
        reply = json.loads((await phone.receive()).data)
        assert reply["sessions"] == [] and reply["calibrations"] == []
    assert (data / "session_NEW.jsonl").read_text().count("\n") == 31
    assert (data / "derived" / "fingerprint_NEW.json").exists()


async def test_the_dashboard_page_is_served(client):
    c, _ = client
    page = await c.get("/")
    assert page.status == 200 and "Interaction Fingerprint" in await page.text()


async def test_a_websocket_at_the_root_is_the_phone(client):
    c, _ = client
    async with c.ws_connect("/") as phone, c.ws_connect("/live") as browser:
        await browser.receive()
        await phone.send_str(json.dumps(dict(type="have", payload=dict(sessions=["X"], calibrations=[]))))
        assert json.loads((await phone.receive()).data)["sessions"] == ["X"]
