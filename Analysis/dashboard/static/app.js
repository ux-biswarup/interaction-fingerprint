// The desk dashboard. One WebSocket to the server; everything else is drawing.
// Feature meanings: docs/product/12-FINGERPRINT-FEATURES.md. Protocol: 13-DESK-LINK.md.

const W = 393, H = 852;
const canvas = document.getElementById("phoneCanvas");
const ctx = canvas.getContext("2d");
const EXPRESSION = ["eyeBlink_L","eyeBlink_R","eyeSquint_L","eyeSquint_R","eyeWide_L","eyeWide_R","browInnerUp","browOuterUp_L","browOuterUp_R"];

const state = {
  phone: false, live: null, areas: [], trail: [], taps: [], fingerprint: null,
  rateWindow: [], sessions: [], viewing: null, compare: new Set(), qualityCounts: {}, onDisplay: [0, 0], lastGaze: null,
};

// ------------------------------------------------------------------ socket

function connect() {
  const ws = new WebSocket(`ws://${location.host}/live`);
  ws.onopen = () => setPill("server", "desk: connected", true);
  ws.onclose = () => { setPill("server", "desk: reconnecting", false); setTimeout(connect, 1500); };
  ws.onmessage = (m) => handle(JSON.parse(m.data));
}

function handle(msg) {
  switch (msg.type) {
    case "hello":
      state.phone = msg.phone; state.sessions = msg.sessions || [];
      if (msg.live) { startLive(msg.live.session, msg.live.areas, msg.live.started); (msg.live.recent || []).forEach(ingest); if (msg.live.fingerprint) setFingerprint(msg.live.fingerprint); }
      renderSessions(); break;
    case "phone": state.phone = msg.connected; break;
    case "session_start": startLive(msg.session, msg.areas, Date.now() / 1000); break;
    case "events": (msg.rows || []).forEach(ingest); if (state.live) state.live.eventCount = msg.eventCount; break;
    case "fingerprint": if (!state.viewing) setFingerprint(msg.fingerprint); break;
    case "session_end":
      logLine("session", "ended, saved to Data/");
      if (msg.fingerprint && !state.viewing) setFingerprint(msg.fingerprint);
      state.sessions = msg.sessions || state.sessions; renderSessions();
      if (state.live) state.live.ended = true; break;
    case "areas": state.areas = msg.areas || []; break;
    case "calibration": logLine("calibration", msg.model ? `${msg.model.source} · ${Math.round(msg.model.accuracyPoints)} pt held out` : "saved"); break;
    case "uploaded": logLine("upload", msg.name); state.sessions = msg.sessions || state.sessions; renderSessions(); break;
  }
  setPill("phone", state.phone ? "phone: connected" : "phone: not connected", state.phone);
}

function startLive(session, areas, started) {
  state.live = { session, started: started || Date.now() / 1000, eventCount: 0 };
  state.areas = areas || []; state.trail = []; state.taps = []; state.fingerprint = null; state.qualityCounts = {}; state.onDisplay = [0, 0];
  document.getElementById("log").innerHTML = "";
  logLine("session", `${(session.id || "").slice(0, 8)} started`);
  if (!state.viewing) { document.getElementById("fpTitle").innerHTML = 'Fingerprint <span class="sub">live, recomputed every 2 s</span>'; renderFingerprint(null); }
}

function ingest(e) {
  if (e.event === "gaze") {
    state.lastGaze = e;
    state.rateWindow.push(e.timestamp); while (state.rateWindow.length && e.timestamp - state.rateWindow[0] > 2) state.rateWindow.shift();
    state.qualityCounts[e.quality] = (state.qualityCounts[e.quality] || 0) + 1;
    if (e.quality === "good" && e.x != null) {
      state.trail.push(e); while (state.trail.length > 90) state.trail.shift();
      const on = e.x >= 0 && e.x <= 1 && e.y >= 0 && e.y <= 1; state.onDisplay[0] += on ? 1 : 0; state.onDisplay[1] += 1;
    }
    return;
  }
  if (e.event === "tap") { state.taps.push(e); while (state.taps.length > 12) state.taps.shift(); logLine("tap", `${e.screen} · ${e.target}${e.productID ? " · " + e.productID : ""} · ${Math.round(e.durationMs || 0)} ms`, "tap"); }
  else if (e.event === "screen_appear") logLine("screen", `${e.screen}${e.productID ? " · " + e.productID : ""}`);
  else if (e.event === "product_selected") logLine("selected", e.productID || "");
  else if (e.event === "back") logLine("back", e.productID || "");
  else if (e.event === "buffer_overflow") logLine("overflow", "the phone dropped events");
}

// ------------------------------------------------------------------ drawing

function draw() {
  ctx.clearRect(0, 0, W, H);
  ctx.fillStyle = "#f4f1ea"; ctx.fillRect(0, 0, W, H);
  const screen = state.lastGaze && state.lastGaze.screen;
  for (const a of state.areas) {
    if (screen && a.screen !== screen) continue;
    ctx.strokeStyle = "rgba(0,0,0,0.25)"; ctx.lineWidth = 1;
    ctx.strokeRect(a.x * W, a.y * H, a.width * W, a.height * H);
    ctx.fillStyle = "rgba(0,0,0,0.45)"; ctx.font = "10px ui-monospace, Menlo, monospace";
    ctx.fillText(a.target + (a.productID ? " " + a.productID.replace("sku_", "#") : ""), a.x * W + 4, a.y * H + 11);
  }
  const fp = state.viewing ? state.viewFingerprint : state.fingerprint;
  if (state.viewing && fp) {
    for (const t of (fp.tap_list || [])) {
      ctx.strokeStyle = t.element_distance_pt === 0 ? "#c98f00" : "#c04a2f"; ctx.lineWidth = 2; const x = t.x * W, y = t.y * H;
      ctx.beginPath(); ctx.moveTo(x - 8, y - 8); ctx.lineTo(x + 8, y + 8); ctx.moveTo(x + 8, y - 8); ctx.lineTo(x - 8, y + 8); ctx.stroke();
    }
  }
  if (fp && fp.fixation_list) {
    for (const f of fp.fixation_list.slice(-40)) {
      const r = 6 + Math.min(f.duration_s, 1.5) * 16;
      ctx.beginPath(); ctx.arc(f.x * W, f.y * H, r, 0, Math.PI * 2);
      ctx.fillStyle = "rgba(106,169,255,0.18)"; ctx.fill(); ctx.strokeStyle = "rgba(106,169,255,0.6)"; ctx.stroke();
    }
  }
  for (const t of state.viewing ? [] : state.taps) {
    if (t.targetMinX != null) { ctx.strokeStyle = "rgba(245,196,0,0.9)"; ctx.lineWidth = 2; ctx.strokeRect(t.targetMinX * W, t.targetMinY * H, (t.targetMaxX - t.targetMinX) * W, (t.targetMaxY - t.targetMinY) * H); }
    ctx.strokeStyle = "#c98f00"; ctx.lineWidth = 2; const x = t.x * W, y = t.y * H;
    ctx.beginPath(); ctx.moveTo(x - 8, y - 8); ctx.lineTo(x + 8, y + 8); ctx.moveTo(x + 8, y - 8); ctx.lineTo(x - 8, y + 8); ctx.stroke();
  }
  const trail = state.viewing ? [] : state.trail;
  for (let i = 1; i < trail.length; i++) {
    const a = trail[i - 1], b = trail[i], alpha = i / trail.length;
    ctx.strokeStyle = `rgba(200,60,30,${0.15 + 0.6 * alpha})`; ctx.lineWidth = 1.5;
    ctx.beginPath(); ctx.moveTo(a.x * W, a.y * H); ctx.lineTo(b.x * W, b.y * H); ctx.stroke();
  }
  if (trail.length) {
    const g = trail[trail.length - 1];
    ctx.beginPath(); ctx.arc(g.x * W, g.y * H, 11, 0, Math.PI * 2); ctx.fillStyle = "rgba(245,196,0,0.9)"; ctx.fill();
  }
  requestAnimationFrame(draw);
}

function tick() {
  const g = state.lastGaze;
  const now = Date.now() / 1000;
  const fresh = state.live && !state.live.ended && state.trail.length && (now - (state.liveSeenAt || 0)) < 3;
  document.getElementById("rate").textContent = state.rateWindow.length > 1 ? Math.round(state.rateWindow.length / 2) : "—";
  document.getElementById("distance").textContent = g && g.eyeZ != null ? Math.round(-g.eyeZ * 100) : "—";
  const total = Object.values(state.qualityCounts).reduce((a, b) => a + b, 0);
  document.getElementById("quality").textContent = total ? `${Math.round(100 * (state.qualityCounts.good || 0) / total)}% good` : "—";
  document.getElementById("onDisplay").textContent = state.onDisplay[1] ? `${Math.round(100 * state.onDisplay[0] / state.onDisplay[1])}%` : "—";
  document.getElementById("elapsed").textContent = state.live ? fmtTime((state.live.ended ? state.live.endedAt || now : now) - state.live.started) : "—";
  document.getElementById("events").textContent = state.live ? state.live.eventCount : "—";
  document.getElementById("screenLabel").textContent = g && g.screen ? `${g.screen}${g.productID ? " · " + g.productID : ""}${g.target ? " · " + g.target : ""}` : "—";
  setPill("session", state.live ? (state.live.ended ? `session ${(state.live.session.id || "").slice(0, 8)} ended` : `recording ${(state.live.session.id || "").slice(0, 8)}`) : "no live session", state.live && !state.live.ended);
  if (g && g.signals) renderShapes(g.signals);
}

function renderShapes(signals) {
  const el = document.getElementById("shapes");
  el.innerHTML = EXPRESSION.map((k) => { const v = signals[k] || 0; return `<div class="shape"><span>${k}</span><div class="bar"><i style="width:${Math.min(100, v * 100)}%"></i></div><span>${v.toFixed(2)}</span></div>`; }).join("");
}

// ------------------------------------------------------------------ fingerprint panel

function setFingerprint(fp) { state.fingerprint = fp; renderFingerprint(fp); }

function num(v, digits = 0, suffix = "") { return v == null || Number.isNaN(v) ? "—" : `${Number(v).toFixed(digits)}${suffix}`; }

function renderFingerprint(fp) {
  const numbers = document.getElementById("fpNumbers");
  if (!fp) { numbers.innerHTML = '<div><b>—</b><span>waiting for gaze</span></div>'; document.getElementById("dwellBars").innerHTML = ""; document.getElementById("transitions").innerHTML = ""; document.querySelector("#tapTable tbody").innerHTML = ""; return; }
  const f = fp.fixations || {}, t = fp.taps || {}, n = fp.navigation || {}, face = (fp.face || {}).all || {};
  const cells = [
    [num(fp.tracked_s, 0, " s"), "tracked gaze"], [num(f.per_min), "fixations / min"], [num(f.median_duration_s * 1000), "fixation median ms"], [num(f.share_of_tracked * 100, 0, "%"), "time in fixations"],
    [num(f.saccade_median_amplitude_pt), "saccade median pt"], [num(t.count), "taps"], [num(t.looked_at_share * 100, 0, "%"), "looked at before tap"], [num(t.median_element_distance_pt), "gaze to element pt"],
    [num(t.median_looked_first_s, 2, " s"), "first look before tap"], [num(t.median_hesitation_s, 2, " s"), "hesitation"], [num(t.median_press_ms), "press ms"], [num(n.list_switches), "list switches"],
    [num(n.products_viewed), "products viewed"], [num(n.selections), "selected"], [num(n.backs), "backs"], [num(face.blink_per_min, 1), "blinks / min"],
    [num(face.distance_cm), "distance cm"], [num(face.head_yaw_sd_deg, 1, "°"), "head yaw sd"], [num(face.phone_tilt_deg, 0, "°"), "phone tilt"], [num(face.on_display_share * 100, 0, "%"), "gaze on display"],
  ];
  numbers.innerHTML = cells.map(([v, l]) => `<div><b>${v}</b><span>${l}</span></div>`).join("");

  const areas = (fp.fixation_areas || []).slice(0, 12);
  const max = Math.max(0.1, ...areas.map((a) => a.fixation_dwell_s));
  document.getElementById("dwellBars").innerHTML = areas.map((a) => `<div class="row ${a.screen === "product_list" ? "list" : ""}"><span>${a.target}${a.productID ? " " + a.productID.replace("sku_", "#") : ""}</span><div class="bar"><i style="width:${100 * a.fixation_dwell_s / max}%"></i></div><span>${a.fixation_dwell_s.toFixed(1)}</span></div>`).join("") || '<span class="sub">no fixations yet</span>';

  const tr = fp.transitions || {}; const keys = Array.from(new Set([...Object.keys(tr), ...Object.values(tr).flatMap((r) => Object.keys(r))])).sort();
  const peak = Math.max(1, ...Object.values(tr).flatMap((r) => Object.values(r)));
  document.getElementById("transitions").innerHTML = keys.length ? `<table><tr><th></th>${keys.map((k) => `<th>${k.slice(0, 6)}</th>`).join("")}</tr>${keys.map((r) => `<tr><th>${r.slice(0, 9)}</th>${keys.map((c) => { const v = (tr[r] || {})[c] || 0; return `<td style="background:rgba(106,169,255,${v / peak * 0.7})">${v || ""}</td>`; }).join("")}</tr>`).join("")}</table>` : '<span class="sub">no transitions yet</span>';

  document.querySelector("#tapTable tbody").innerHTML = (fp.tap_list || []).slice(-10).map((x) => `<tr><td>${x.screen || ""}</td><td>${x.target || ""}</td><td>${num(x.press_ms)}</td><td class="${x.element_distance_pt == null ? "" : x.element_distance_pt === 0 ? "good" : x.element_distance_pt > 100 ? "bad" : ""}">${num(x.element_distance_pt)}</td><td>${num(x.looked_first_s, 2)}</td><td>${num(x.hesitation_s, 2)}</td></tr>`).join("");
}

// ------------------------------------------------------------------ sessions

function renderSessions() {
  document.getElementById("sessionCount").textContent = state.sessions.length ? `${state.sessions.length} on disk` : "";
  const body = document.querySelector("#sessionTable tbody");
  body.innerHTML = state.sessions.map((s) => {
    const f = s.flat || {}; const when = s.startedAt ? new Date(s.startedAt * 1000).toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }) : s.id.slice(0, 8);
    return `<tr data-id="${s.id}" class="${state.viewing === s.id ? "active" : ""}"><td><input type="checkbox" data-cmp="${s.id}" ${state.compare.has(s.id) ? "checked" : ""}></td><td>${when}</td><td>${num(f["nav.session_s"], 0, " s")}</td><td>${num(f["fixation.per_min"])}</td><td>${num(f["nav.taps"])}</td><td>${num(f["tap.looked_at_share"] * 100, 0, "%")}</td><td>${num(f["face.blink_per_min"], 1)}</td></tr>`;
  }).join("");
  body.querySelectorAll("tr").forEach((row) => row.addEventListener("click", (ev) => { if (ev.target.tagName !== "INPUT") viewSession(row.dataset.id); }));
  body.querySelectorAll("input[data-cmp]").forEach((box) => box.addEventListener("change", () => { box.checked ? state.compare.add(box.dataset.cmp) : state.compare.delete(box.dataset.cmp); renderCompare(); }));
}

async function viewSession(id) {
  const res = await fetch(`/api/session/${id}`); if (!res.ok) return;
  const fp = await res.json();
  state.viewing = id; state.viewFingerprint = fp;
  document.getElementById("fpTitle").innerHTML = `Fingerprint <span class="sub">session ${id.slice(0, 8)}, ${fp.navigation ? Math.round(fp.navigation.session_s) : "?"} s</span>`;
  document.getElementById("backToLive").classList.remove("hidden");
  renderFingerprint(fp); renderSessions();
}

document.getElementById("backToLive").addEventListener("click", (e) => { e.preventDefault(); state.viewing = null; document.getElementById("backToLive").classList.add("hidden"); document.getElementById("fpTitle").innerHTML = 'Fingerprint <span class="sub">live, recomputed every 2 s</span>'; renderFingerprint(state.fingerprint); renderSessions(); });

function renderCompare() {
  const el = document.getElementById("compare");
  const picked = state.sessions.filter((s) => state.compare.has(s.id));
  if (picked.length < 2) { el.classList.add("hidden"); return; }
  el.classList.remove("hidden");
  const keys = ["nav.session_s", "fixation.per_min", "fixation.median_duration_s", "fixation.saccade_median_amplitude_pt", "tap.count", "tap.median_press_ms", "tap.looked_at_share", "tap.median_element_distance_pt", "tap.median_looked_first_s", "nav.time_to_first_selection_s", "nav.list_switches", "nav.backs", "scroll.reversals", "scroll.travel_pt", "face.blink_per_min", "face.head_yaw_sd_deg", "face.distance_cm", "dwell.revisits_fixation"];
  el.innerHTML = `<table><tr><th>feature</th>${picked.map((s) => `<th>${s.id.slice(0, 8)}</th>`).join("")}</tr>${keys.map((k) => {
    const vals = picked.map((s) => (s.flat || {})[k]); const nums = vals.filter((v) => v != null);
    const spread = nums.length > 1 && Math.min(...nums) > 0 ? Math.max(...nums) / Math.min(...nums) : 1;
    return `<tr><td>${k}</td>${vals.map((v) => `<td class="${spread > 1.3 ? "diff" : ""}">${num(v, Number.isInteger(v) ? 0 : 2)}</td>`).join("")}</tr>`; }).join("")}</table>`;
}

// ------------------------------------------------------------------ helpers

function logLine(kind, text, cls = "") {
  const li = document.createElement("li"); li.className = cls;
  li.innerHTML = `<b>${kind}</b> ${text}`;
  const log = document.getElementById("log"); log.prepend(li); while (log.children.length > 80) log.removeChild(log.lastChild);
}
function setPill(id, text, on) { const el = document.getElementById(id); el.textContent = text; el.className = `pill ${on ? "on" : "off"}`; }
function fmtTime(s) { s = Math.max(0, Math.round(s)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; }

const originalIngest = ingest;
ingest = function (e) { state.liveSeenAt = Date.now() / 1000; return originalIngest(e); };

connect(); draw(); setInterval(tick, 250);
