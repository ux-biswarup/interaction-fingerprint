// The desk dashboard: one socket for live data, plain fetches for stored sessions.
// Feature meanings: docs/product/12-FINGERPRINT-FEATURES.md. Protocol: 13-DESK-LINK.md.
// Study conditions: 04-EXPERIMENT-PLAN.md.

const W = 393, H = 852;
const canvas = document.getElementById("phoneCanvas");
const ctx = canvas.getContext("2d");
const EXPRESSION = ["eyeBlink_L", "eyeBlink_R", "eyeSquint_L", "eyeSquint_R", "eyeWide_L", "eyeWide_R", "browInnerUp", "browOuterUp_L", "browOuterUp_R"];
// The shop's catalogue, so the timeline can say what was opened rather than an id.
const PRODUCTS = { sku_101: "Aurel M2 Headphones", sku_102: "Corven Field Speaker", sku_103: "Lumen Desk Lamp", sku_104: "Palis Travel Kettle", sku_105: "Orten Mechanical Keyboard", sku_106: "Halden Camera Bag" };
const TARGETS = { list_item: "a product in the list", cta: "Add to basket", back: "Back", title: "the title", price: "the price", rating: "the rating", reviews: "the reviews", description: "the description", product_image: "the image", header: "the header" };
const $ = (id) => document.getElementById(id);

const state = {
  phone: false, sessions: [],
  // live recording
  live: null, liveRows: [], liveFingerprint: null, areas: [], rateWindow: [], qualityCounts: {}, lastGaze: null,
  // what the page shows: "live" or a session id
  mode: "live", doc: null,
  // replay
  playing: false, playhead: 0, speed: 1, lastFrame: 0,
};

// ------------------------------------------------------------------ socket

function connect() {
  const ws = new WebSocket(`ws://${location.host}/live`);
  ws.onopen = () => { $("deskStatus").textContent = "desk connected"; };
  ws.onclose = () => { $("deskStatus").textContent = "desk offline, retrying"; setTimeout(connect, 1500); };
  ws.onmessage = (m) => handle(JSON.parse(m.data));
}

function handle(msg) {
  switch (msg.type) {
    case "hello":
      state.phone = msg.phone; state.sessions = msg.sessions || [];
      if (msg.live) { beginLive(msg.live.session, msg.live.areas, msg.live.started); (msg.live.recent || []).forEach(ingestLive); if (msg.live.fingerprint) state.liveFingerprint = msg.live.fingerprint; }
      renderSidebar();
      // A session named in the URL survives a refresh and can be sent to someone.
      if (location.hash.startsWith("#session=") && state.mode === "live" && !state.doc) openSession(location.hash.slice(9));
      else if (state.mode === "live") renderLive();
      break;
    case "phone": state.phone = msg.connected; break;
    case "session_start":
      beginLive(msg.session, msg.areas, Date.now() / 1000);
      if (state.mode !== "live") showNotice("A recording has started on the phone.");
      else renderLive();
      break;
    case "events": (msg.rows || []).forEach(ingestLive); if (state.live) state.live.eventCount = msg.eventCount; break;
    case "fingerprint": state.liveFingerprint = msg.fingerprint; if (state.mode === "live") renderFingerprint(msg.fingerprint); break;
    case "session_end":
      if (state.live) { state.live.ended = true; state.live.endedAt = Date.now() / 1000; }
      if (msg.fingerprint) state.liveFingerprint = msg.fingerprint;
      state.sessions = msg.sessions || state.sessions; renderSidebar();
      if (state.mode === "live") renderLive();
      break;
    case "areas": state.areas = msg.areas || []; break;
    case "uploaded": state.sessions = msg.sessions || state.sessions; renderSidebar(); break;
  }
  const pill = $("phonePill"); pill.textContent = state.phone ? "phone · connected" : "phone · not connected"; pill.className = `pill ${state.phone ? "on" : ""}`;
  updateLiveItem();
}

function beginLive(session, areas, started) {
  state.live = { session, started: started || Date.now() / 1000, eventCount: 0, ended: false };
  state.liveRows = []; state.liveFingerprint = null; state.areas = areas || []; state.qualityCounts = {}; state.rateWindow = []; state.lastGaze = null;
}

function ingestLive(e) {
  state.liveRows.push(e);
  if (e.event === "gaze") {
    state.lastGaze = e;
    state.rateWindow.push(e.timestamp); while (state.rateWindow.length && e.timestamp - state.rateWindow[0] > 2) state.rateWindow.shift();
    state.qualityCounts[e.quality] = (state.qualityCounts[e.quality] || 0) + 1;
  } else if (state.mode === "live") {
    renderTimeline(state.liveRows, state.liveFingerprint, state.live ? state.live.session : null);
  }
}

function updateLiveItem() {
  const dot = $("liveDot"), sub = $("liveSub");
  if (state.live && !state.live.ended) { dot.className = "dot recording"; sub.textContent = `recording · ${describeCondition(state.live.session.condition) || "free session"}`; }
  else if (state.phone) { dot.className = "dot ready"; sub.textContent = state.live ? "last recording ended" : "phone connected, idle"; }
  else { dot.className = "dot"; sub.textContent = "phone not connected"; }
  $("liveItem").classList.toggle("active", state.mode === "live");
}

function showNotice(text) { $("noticeText").textContent = text; $("notice").classList.remove("hidden"); }
$("noticeAction").addEventListener("click", () => { $("notice").classList.add("hidden"); goLive(); });
$("liveItem").addEventListener("click", goLive);

// ------------------------------------------------------------------ sidebar: participants and their sessions

function describeCondition(c) {
  if (!c) return "";
  return [c.task, c.pace, c.posture && c.posture.replace("_", " "), c.light].filter(Boolean).join(" · ");
}

function quality(s) {
  const share = (s.flat || {})["fixation.share_of_tracked"];
  if (share == null) return "bad";
  return share >= 0.4 ? "good" : share >= 0.2 ? "poor" : "bad";
}

function searchText(s) {
  const when = s.startedAt ? new Date(s.startedAt * 1000) : null;
  return [s.participant, describeCondition(s.condition), s.condition ? "" : "free", s.task ? (s.task.correct ? "correct" : s.task.selected ? "wrong" : s.task.timedOut ? "timed out" : "") : "",
          when && when.toLocaleDateString(undefined, { weekday: "long", day: "numeric", month: "long" }), when && when.toLocaleTimeString(),
          s.id, (s.device || {}).model, (s.calibration || {}).source].filter(Boolean).join(" ").toLowerCase();
}

function renderSidebar() {
  const query = ($("search").value || "").trim().toLowerCase().split(/\s+/).filter(Boolean);
  const shown = state.sessions.filter((s) => { const text = searchText(s); return query.every((q) => text.includes(q)); });
  const groups = new Map();
  for (const s of shown) {
    const key = s.participant || (s.condition ? "unlabelled" : "free recordings");
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(s);
  }
  // Whoever recorded most recently comes first, so the newest session is always at the top.
  const latest = (key) => Math.max(...groups.get(key).map((s) => s.startedAt || 0));
  const order = [...groups.keys()].sort((a, b) => latest(b) - latest(a));
  $("sessionList").innerHTML = (shown.length === 0 && state.sessions.length ? '<div class="empty">No sessions match.</div>' : "") + order.map((key) => {
    const list = groups.get(key).slice().sort((a, b) => (b.startedAt || 0) - (a.startedAt || 0));
    return `<div class="group"><div class="group-title"><span>${key}</span><span>${list.length}</span></div>${list.map((s) => {
      const when = s.startedAt ? new Date(s.startedAt * 1000).toLocaleString(undefined, { weekday: "short", hour: "2-digit", minute: "2-digit" }) : s.id.slice(0, 8);
      const day = s.startedAt ? new Date(s.startedAt * 1000).toLocaleDateString(undefined, { day: "numeric", month: "short" }) : "";
      return `<button class="session ${state.mode === s.id ? "active" : ""}" data-id="${s.id}">
        <span class="when">${day} · ${when}</span><span class="len">${fmtTime(s.duration_s || 0)}</span>
        <span class="what"><span class="q ${quality(s)}"></span>${describeCondition(s.condition) || "free session"}${s.task ? (s.task.correct ? " · correct" : s.task.timedOut ? " · timed out" : "") : ""}</span>
      </button>`; }).join("")}</div>`;
  }).join("") || (state.sessions.length ? "" : '<div class="empty">No sessions yet. They appear here as the phone records or uploads them.</div>');
  $("sessionList").querySelectorAll(".session").forEach((b) => b.addEventListener("click", () => openSession(b.dataset.id)));
  const select = $("compareSelect");
  const current = select.value;
  select.innerHTML = '<option value="">Compare with…</option>' + state.sessions.map((s) => `<option value="${s.id}">${s.participant || "free"} · ${s.startedAt ? new Date(s.startedAt * 1000).toLocaleString(undefined, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : s.id.slice(0, 8)} · ${describeCondition(s.condition) || "free"}</option>`).join("");
  select.value = current;
  updateLiveItem();
}

// ------------------------------------------------------------------ views

function goLive() {
  state.mode = "live"; state.doc = null; state.playing = false;
  if (location.hash) history.replaceState(null, "", location.pathname);
  renderSidebar(); renderLive();
}

function renderLive() {
  const live = state.live;
  $("title").textContent = live ? (live.ended ? "Live · last recording" : "Live") : "Live";
  const cond = live && live.session.condition;
  $("chips").innerHTML = live ? conditionChips(cond, live.session) : '<span class="chip">waiting for the phone to record</span>';
  $("transport").classList.add("hidden");
  $("screenSub").textContent = live && !live.ended ? "recording" : live ? "recording ended" : "—";
  renderRecord(live ? summaryFromLive() : null);
  renderFingerprint(state.liveFingerprint);
  renderTimeline(state.liveRows, state.liveFingerprint, live ? live.session : null);
  $("fpSub").textContent = live && !live.ended ? "recomputed every 2 s while recording" : live ? "final" : "waiting";
}

async function openSession(id) {
  const res = await fetch(`/api/session/${id}/replay`); if (!res.ok) return;
  const doc = await res.json();
  state.mode = id; state.doc = doc; state.playing = false; state.playhead = 0;
  history.replaceState(null, "", `#session=${id}`);
  const gaze = doc.rows.filter((r) => r.event === "gaze");
  doc.t0 = doc.rows.length ? Math.min(...doc.rows.map((r) => r.timestamp)) : 0;
  doc.t1 = doc.rows.length ? Math.max(...doc.rows.map((r) => r.timestamp)) : 0;
  doc.gaze = gaze;
  const s = state.sessions.find((x) => x.id === id) || {};
  $("title").textContent = `${s.participant || "Free recording"} · ${s.startedAt ? new Date(s.startedAt * 1000).toLocaleString(undefined, { weekday: "long", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" }) : id.slice(0, 8)}`;
  $("chips").innerHTML = conditionChips(s.condition, doc.session, s);
  $("transport").classList.remove("hidden");
  $("screenSub").textContent = "replay";
  $("fpSub").textContent = "whole session";
  $("notice").classList.add("hidden");
  renderRecord(s); renderFingerprint(doc.fingerprint); renderTimeline(doc.rows, doc.fingerprint, doc.session); renderSidebar();
  $("playBtn").disabled = gaze.length === 0; updateClock();
}

function conditionChips(c, session, summary) {
  const chips = [];
  if (c) { chips.push(`<span class="chip accent">${c.task}</span>`, `<span class="chip accent">${c.pace}</span>`, `<span class="chip">${(c.posture || "").replace("_", " ")}</span>`, `<span class="chip">${c.light}</span>`); }
  else chips.push('<span class="chip">free session, no condition</span>');
  if (summary && summary.task) chips.push(`<span class="chip">${summary.task.correct ? "task correct" : summary.task.selected ? "wrong product" : summary.task.timedOut ? "time ran out" : "task not completed"}</span>`);
  return chips.join("");
}

// ------------------------------------------------------------------ record card

function summaryFromLive() {
  const live = state.live, fp = state.liveFingerprint || {};
  const good = state.qualityCounts.good || 0, total = Object.values(state.qualityCounts).reduce((a, b) => a + b, 0);
  return {
    id: live.session.id, startedAt: live.started, condition: live.session.condition, device: live.session.device,
    calibration: live.session.calibration ? { source: live.session.calibration.source, accuracyPoints: live.session.calibration.accuracyPoints, accuracyDegrees: live.session.calibration.accuracyDegrees } : null,
    duration_s: (live.ended ? live.endedAt : Date.now() / 1000) - live.started, tracked_s: fp.tracked_s,
    flat: fp.fixations ? { "fixation.share_of_tracked": fp.fixations.share_of_tracked, "face.on_display_share": (fp.face && fp.face.all || {}).on_display_share, "nav.taps": fp.navigation && fp.navigation.taps, "face.distance_cm": (fp.face && fp.face.all || {}).distance_cm } : { "face.on_display_share": null },
    quality_live: total ? good / total : null, events: live.eventCount, task: fp.task,
  };
}

function renderRecord(s) {
  const el = $("record");
  if (!s) { el.innerHTML = '<div class="cell" style="grid-column: 1 / -1"><div class="k">Record</div><div class="v">—</div><div class="s">Start a session on the phone, or choose one from the left.</div></div>'; return; }
  const f = s.flat || {}, c = s.condition || {}, cal = s.calibration, dev = s.device || {};
  const share = f["fixation.share_of_tracked"];
  const cells = [
    ["Participant", c.participant || "—", c.task ? `${c.task} · ${c.pace}` : "free session"],
    ["Posture · light", c.posture ? `${c.posture.replace("_", " ")} · ${c.light}` : "—", ""],
    ["Recorded", s.startedAt ? new Date(s.startedAt * 1000).toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" }) : "—", s.startedAt ? new Date(s.startedAt * 1000).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" }) : ""],
    ["Length", fmtTime(s.duration_s || 0), s.tracked_s != null ? `${Math.round(s.tracked_s)} s of good gaze` : s.events != null ? `${s.events} events` : ""],
    ["Gaze quality", share != null ? `${Math.round(share * 100)}%` : s.quality_live != null ? `${Math.round(s.quality_live * 100)}% good` : "—", share != null ? (share >= 0.4 ? "passes the quality gate" : "below the 40% gate") : "share of tracked time in fixations", share != null ? (share >= 0.4 ? "ok" : "bad") : ""],
    ["Calibration", cal && cal.accuracyPoints != null ? `${Math.round(cal.accuracyPoints)} pt` : "—", cal ? `${cal.source || ""}${cal.accuracyDegrees != null ? ` · ${cal.accuracyDegrees.toFixed(2)}°` : ""}` : "no calibration recorded"],
    ["Device", dev.model || "—", dev.systemVersion ? `iOS ${dev.systemVersion} · ${dev.screenPointWidth}×${dev.screenPointHeight} pt` : ""],
    ["Task outcome", s.task ? (s.task.correct ? "Correct" : s.task.selected ? "Wrong product" : s.task.timedOut ? "Timed out" : "Not completed") : c.task ? "—" : "n/a", s.task && s.task.selected ? `chose ${PRODUCTS[s.task.selected] || s.task.selected}${s.task.correct ? "" : " · answer: Lumen Desk Lamp"}` : c.task === "search" ? "right answer: Lumen Desk Lamp" : "", s.task ? (s.task.correct ? "ok" : s.task.selected ? "bad" : "warn") : ""],
  ];
  el.innerHTML = cells.map(([k, v, sub, cls]) => `<div class="cell"><div class="k">${k}</div><div class="v ${cls || ""}">${v}</div>${sub ? `<div class="s">${sub}</div>` : ""}</div>`).join("");
}

// ------------------------------------------------------------------ fingerprint

function num(v, digits = 0, suffix = "") { return v == null || Number.isNaN(v) ? "—" : `${Number(v).toFixed(digits)}${suffix}`; }

function renderFingerprint(fp) {
  const numbers = $("fpNumbers");
  if (!fp) { numbers.innerHTML = '<div><b>—</b><span>no fingerprint yet</span></div>'; $("dwellBars").innerHTML = ""; $("transitions").innerHTML = ""; document.querySelector("#tapTable tbody").innerHTML = ""; return; }
  const f = fp.fixations || {}, t = fp.taps || {}, n = fp.navigation || {}, face = (fp.face || {}).all || {};
  const cells = [
    [num(f.per_min), "fixations per minute"], [num(f.median_duration_s * 1000), "fixation median, ms"], [num(f.share_of_tracked * 100, 0, "%"), "time in fixations"], [num(f.saccade_median_amplitude_pt), "saccade median, pt"],
    [num(t.count), "taps"], [num(t.looked_at_share * 100, 0, "%"), "looked at before tapping"], [num(t.median_looked_first_s, 2, " s"), "first look before tap"], [num(t.median_hesitation_s, 2, " s"), "hesitation"],
    [num(t.median_press_ms), "press, ms"], [num(n.list_switches), "list switches"], [num(n.products_viewed), "products viewed"], [num(n.time_to_first_selection_s, 1, " s"), "time to first selection"],
    [num(face.blink_per_min, 1), "blinks per minute"], [num(face.distance_cm), "distance, cm"], [num(face.head_yaw_sd_deg, 1, "°"), "head yaw sd"], [num(face.on_display_share * 100, 0, "%"), "gaze on display"],
  ];
  numbers.innerHTML = cells.map(([v, l]) => `<div><b>${v}</b><span>${l}</span></div>`).join("");
  const areas = (fp.fixation_areas || []).slice(0, 12);
  const max = Math.max(0.1, ...areas.map((a) => a.fixation_dwell_s));
  $("dwellBars").innerHTML = areas.map((a) => `<div class="row ${a.screen === "product_list" ? "list" : ""}"><span>${a.target === "off_area" ? "off any area" : TARGETS[a.target] || a.target || "off any area"}${a.productID ? ` · ${(PRODUCTS[a.productID] || a.productID).split(" ")[0]}` : ""}</span><div class="bar"><i style="width:${100 * a.fixation_dwell_s / max}%"></i></div><span>${a.fixation_dwell_s.toFixed(1)}</span></div>`).join("") || '<div class="empty">no fixations yet</div>';
  const tr = fp.transitions || {}; const keys = Array.from(new Set([...Object.keys(tr), ...Object.values(tr).flatMap((r) => Object.keys(r))]));
  const peak = Math.max(1, ...Object.values(tr).flatMap((r) => Object.values(r)));
  $("transitions").innerHTML = keys.length ? `<table><tr><th></th>${keys.map((k) => `<th>${k.slice(0, 6)}</th>`).join("")}</tr>${keys.map((r) => `<tr><th>${r.slice(0, 11)}</th>${keys.map((c) => { const v = (tr[r] || {})[c] || 0; return `<td style="background:rgba(10,132,255,${0.08 + v / peak * 0.7})">${v || ""}</td>`; }).join("")}</tr>`).join("")}</table>` : '<div class="empty">no transitions yet</div>';
  document.querySelector("#tapTable tbody").innerHTML = (fp.tap_list || []).slice(-12).map((x) => `<tr><td>${x.screen === "product_list" ? "list" : "detail"} · ${TARGETS[x.target] || x.target || ""}</td><td>${num(x.press_ms)} ms</td><td class="${x.element_distance_pt == null ? "" : x.element_distance_pt === 0 ? "good" : x.element_distance_pt > 100 ? "bad" : ""}">${x.element_distance_pt == null ? "no frame" : x.element_distance_pt === 0 ? "on it" : `${num(x.element_distance_pt)} pt off`}</td><td>${num(x.looked_first_s, 2, " s")}</td><td>${num(x.hesitation_s, 2, " s")}</td></tr>`).join("") || '<tr><td colspan="5" class="empty">no taps yet</td></tr>';
}

$("compareSelect").addEventListener("change", async (e) => {
  const id = e.target.value; const box = $("compare");
  if (!id) { box.classList.add("hidden"); return; }
  const other = state.sessions.find((s) => s.id === id); if (!other) return;
  const mine = state.mode === "live" ? summaryFromLiveFlat() : (state.sessions.find((s) => s.id === state.mode) || {}).flat || {};
  const keys = ["fixation.per_min", "fixation.median_duration_s", "fixation.share_of_tracked", "fixation.saccade_median_amplitude_pt", "tap.count", "tap.median_press_ms", "tap.looked_at_share", "tap.median_looked_first_s", "nav.time_to_first_selection_s", "nav.list_switches", "nav.backs", "scroll.reversals", "face.blink_per_min", "face.head_yaw_sd_deg", "face.distance_cm", "dwell.revisits_fixation"];
  box.classList.remove("hidden");
  box.innerHTML = `<table><tr><th>feature</th><th>this session</th><th>${other.participant || "free"} · ${describeCondition(other.condition) || other.id.slice(0, 8)}</th></tr>${keys.map((k) => { const a = mine[k], b = (other.flat || {})[k]; const diff = a != null && b != null && Math.min(a, b) > 0 && Math.max(a, b) / Math.min(a, b) > 1.3; return `<tr><td>${k}</td><td class="${diff ? "diff" : ""}">${num(a, Number.isInteger(a) ? 0 : 2)}</td><td class="${diff ? "diff" : ""}">${num(b, Number.isInteger(b) ? 0 : 2)}</td></tr>`; }).join("")}</table>`;
});
function summaryFromLiveFlat() {
  const fp = state.liveFingerprint; if (!fp) return {};
  const f = fp.fixations || {}, t = fp.taps || {}, n = fp.navigation || {}, face = (fp.face || {}).all || {};
  return { "fixation.per_min": f.per_min, "fixation.median_duration_s": f.median_duration_s, "fixation.share_of_tracked": f.share_of_tracked, "fixation.saccade_median_amplitude_pt": f.saccade_median_amplitude_pt, "tap.count": t.count, "tap.median_press_ms": t.median_press_ms, "tap.looked_at_share": t.looked_at_share, "tap.median_looked_first_s": t.median_looked_first_s, "nav.time_to_first_selection_s": n.time_to_first_selection_s, "nav.list_switches": n.list_switches, "nav.backs": n.backs, "face.blink_per_min": face.blink_per_min, "face.head_yaw_sd_deg": face.head_yaw_sd_deg, "face.distance_cm": face.distance_cm };
}

// ------------------------------------------------------------------ timeline in plain language

function renderTimeline(rows, fp, session) {
  const t0 = rows.length ? Math.min(...rows.map((r) => r.timestamp)) : 0;
  const taps = (fp && fp.tap_list) || [];
  const items = [];
  for (const e of rows) {
    if (e.event === "gaze") continue;
    const t = fmtTime(e.timestamp - t0);
    const name = PRODUCTS[e.productID] || (e.productID ? e.productID : "");
    if (e.event === "session_start") items.push([t, "Recording started", "", "screen"]);
    else if (e.event === "screen_appear") items.push([t, e.screen === "product_detail" ? `Opened ${name}` : "Product list", "", "screen"]);
    else if (e.event === "back") items.push([t, `Back to the list from ${name}`, "", "screen"]);
    else if (e.event === "product_selected") items.push([t, `Added ${name} to the basket`, "", "select"]);
    else if (e.event === "tap") {
      const match = taps.find((x) => Math.abs(x.timestamp - e.timestamp) < 0.01);
      let how = "";
      if (match) {
        if (match.element_distance_pt === 0) how = `looked at it${match.looked_first_s != null ? ` ${match.looked_first_s.toFixed(1)} s before` : ""}`;
        else if (match.element_distance_pt != null) how = `gaze was ${Math.round(match.element_distance_pt)} pt away`;
        else how = "no element frame";
      }
      items.push([t, `Tapped ${TARGETS[e.target] || e.target}${e.screen === "product_list" && name ? ` (${name})` : ""}`, how, "tap"]);
    }
    else if (e.event === "task_result") { const correct = e.correct === 1 || (e.metrics && e.metrics.correct === 1); const timed = e.timedOut === 1 || (e.metrics && e.metrics.timedOut === 1); items.push([t, correct ? "Task completed correctly" : timed ? "Time ran out" : "Task ended without the right answer", "", "result"]); }
    else if (e.event === "session_end") items.push([t, "Recording ended", "", "screen"]);
    else if (e.event === "buffer_overflow") items.push([t, "The phone dropped events", "", "screen"]);
  }
  $("timeline").innerHTML = items.map(([t, text, sub, cls]) => `<li class="${cls}"><span class="t">${t}</span><span class="e">${text}${sub ? `<small>${sub}</small>` : ""}</span></li>`).join("") || '<li><span class="t"></span><span class="e empty">nothing yet</span></li>';
  $("timelineSub").textContent = session && session.condition ? `${session.condition.participant} · ${describeCondition(session.condition)}` : "what happened, in order";
}

// ------------------------------------------------------------------ the phone canvas: live trail or replay

function drawAreas(screen) {
  for (const a of state.areas) {
    if (screen && a.screen !== screen) continue;
    ctx.strokeStyle = "rgba(0,0,0,0.22)"; ctx.lineWidth = 1; ctx.strokeRect(a.x * W, a.y * H, a.width * W, a.height * H);
    ctx.fillStyle = "rgba(0,0,0,0.4)"; ctx.font = "10px ui-monospace, Menlo, monospace";
    ctx.fillText(a.target + (a.productID ? " " + a.productID.replace("sku_", "#") : ""), a.x * W + 4, a.y * H + 11);
  }
}
function drawTap(t, onIt) {
  if (t.targetMinX != null) { ctx.strokeStyle = "rgba(245,196,0,0.9)"; ctx.lineWidth = 2; ctx.strokeRect(t.targetMinX * W, t.targetMinY * H, (t.targetMaxX - t.targetMinX) * W, (t.targetMaxY - t.targetMinY) * H); }
  ctx.strokeStyle = onIt === false ? "#c04a2f" : "#c98f00"; ctx.lineWidth = 2; const x = t.x * W, y = t.y * H;
  ctx.beginPath(); ctx.moveTo(x - 8, y - 8); ctx.lineTo(x + 8, y + 8); ctx.moveTo(x + 8, y - 8); ctx.lineTo(x - 8, y + 8); ctx.stroke();
}
function drawTrail(points) {
  for (let i = 1; i < points.length; i++) {
    const a = points[i - 1], b = points[i], alpha = i / points.length;
    ctx.strokeStyle = `rgba(200,60,30,${0.15 + 0.6 * alpha})`; ctx.lineWidth = 1.5;
    ctx.beginPath(); ctx.moveTo(a.x * W, a.y * H); ctx.lineTo(b.x * W, b.y * H); ctx.stroke();
  }
  if (points.length) { const g = points[points.length - 1]; ctx.beginPath(); ctx.arc(g.x * W, g.y * H, 11, 0, Math.PI * 2); ctx.fillStyle = "rgba(245,196,0,0.9)"; ctx.fill(); }
}
function drawFixations(list, until) {
  for (const f of list) {
    if (until != null && f.start > until) continue;
    const r = 6 + Math.min(f.duration_s, 1.5) * 16;
    ctx.beginPath(); ctx.arc(f.x * W, f.y * H, r, 0, Math.PI * 2); ctx.fillStyle = "rgba(10,132,255,0.16)"; ctx.fill(); ctx.strokeStyle = "rgba(10,132,255,0.6)"; ctx.stroke();
  }
}

function draw(now) {
  ctx.fillStyle = "#f4f1ea"; ctx.fillRect(0, 0, W, H);
  if (state.mode === "live") {
    const gaze = state.liveRows.filter((r) => r.event === "gaze" && r.quality === "good" && r.x != null);
    const last = gaze[gaze.length - 1];
    drawAreas(last && last.screen);
    if (state.liveFingerprint) drawFixations((state.liveFingerprint.fixation_list || []).slice(-40));
    state.liveRows.filter((r) => r.event === "tap").slice(-10).forEach((t) => drawTap(t));
    drawTrail(gaze.slice(-90));
  } else if (state.doc) {
    const doc = state.doc;
    if (state.playing) { state.playhead = Math.min(doc.t1 - doc.t0, state.playhead + (now - state.lastFrame) / 1000 * state.speed); if (state.playhead >= doc.t1 - doc.t0) { state.playing = false; $("playBtn").textContent = "▶"; } }
    // Before play is pressed the whole session is shown at once; playing walks through it.
    const overview = !state.playing && state.playhead === 0;
    const until = overview ? Infinity : doc.t0 + state.playhead;
    const gaze = overview ? [] : doc.gaze.filter((r) => r.quality === "good" && r.x != null && r.timestamp <= until && r.timestamp > until - 1.5);
    const current = doc.gaze.filter((r) => r.timestamp <= until).pop();
    drawAreas(null);
    if (doc.fingerprint) drawFixations(doc.fingerprint.fixation_list || [], until);
    for (const t of doc.rows.filter((r) => r.event === "tap" && r.timestamp <= until)) {
      const m = doc.fingerprint && (doc.fingerprint.tap_list || []).find((x) => Math.abs(x.timestamp - t.timestamp) < 0.01);
      drawTap(t, m ? m.element_distance_pt === 0 : null);
    }
    drawTrail(gaze);
    $("screenSub").textContent = overview ? "whole session · press play to replay" : current ? `replay · ${current.screen === "product_list" ? "list" : "detail"}${current.productID ? " · " + (PRODUCTS[current.productID] || current.productID) : ""}${current.target ? " · " + (TARGETS[current.target] || current.target) : ""}` : "replay";
    updateClock();
  }
  state.lastFrame = now;
  requestAnimationFrame(draw);
}

// transport
$("playBtn").addEventListener("click", () => { if (!state.doc) return; if (state.playhead >= state.doc.t1 - state.doc.t0) state.playhead = 0; state.playing = !state.playing; $("playBtn").textContent = state.playing ? "❚❚" : "▶"; });
$("scrub").addEventListener("input", (e) => { if (!state.doc) return; state.playhead = (e.target.value / 1000) * (state.doc.t1 - state.doc.t0); });
$("speed").addEventListener("change", (e) => { state.speed = Number(e.target.value); });
function updateClock() {
  if (!state.doc) return;
  const total = state.doc.t1 - state.doc.t0;
  $("clock").textContent = `${fmtTime(state.playhead)} / ${fmtTime(total)}`;
  if (!document.activeElement || document.activeElement.id !== "scrub") $("scrub").value = total ? Math.round(1000 * state.playhead / total) : 0;
}

// live readouts
function tick() {
  const g = state.lastGaze, live = state.live;
  if (state.mode !== "live") { $("readouts").innerHTML = ""; $("shapes").innerHTML = ""; return; }
  const total = Object.values(state.qualityCounts).reduce((a, b) => a + b, 0);
  const cells = [
    [state.rateWindow.length > 1 ? Math.round(state.rateWindow.length / 2) : "—", "Hz"],
    [g && g.eyeZ != null ? Math.round(-g.eyeZ * 100) : "—", "cm"],
    [total ? `${Math.round(100 * (state.qualityCounts.good || 0) / total)}%` : "—", "good quality"],
    [live ? fmtTime((live.ended ? live.endedAt : Date.now() / 1000) - live.started) : "—", "elapsed"],
    [live ? live.eventCount : "—", "events"],
    [g && g.screen ? `${g.screen === "product_list" ? "list" : "detail"}${g.target ? " · " + g.target : ""}` : "—", "looking at"],
  ];
  $("readouts").innerHTML = cells.map(([v, l]) => `<div><b>${v}</b><span>${l}</span></div>`).join("");
  if (g && g.signals) $("shapes").innerHTML = EXPRESSION.map((k) => { const v = g.signals[k] || 0; return `<div class="shape"><span>${k}</span><div class="bar"><i style="width:${Math.min(100, v * 100)}%"></i></div><span>${v.toFixed(2)}</span></div>`; }).join("");
  if (live && !live.ended) renderRecord(summaryFromLive());
}

function fmtTime(s) { s = Math.max(0, Math.round(s)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; }

$("search").addEventListener("input", renderSidebar);
connect(); requestAnimationFrame(draw); setInterval(tick, 500); renderLive();
