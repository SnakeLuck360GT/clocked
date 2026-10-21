// Interactive copy of Clocked's main window. Today is rebuilt in HTML and behaves like the app;
// the other sidebar panes are renders of the real app.
(() => {
  const W = 1000, H = 740;
  // Sidebar geometry of the renders, in points from the window's top-left.
  const SIDEBAR = { x: 8, width: 180, contentX: 188 };
  const PANES = [
    ["today", 68], ["stats", 100], ["sessions", 132], ["groups", 164],
    ["general", 228], ["detection", 260], ["postures", 292], ["learning", 324],
    ["accountability", 356], ["sites", 388], ["privacy", 420],
  ];
  const ROW_H = 32;

  const GOAL_DAY = 5 * 3600, GOAL_SESSION = 50 * 60;
  const subjects = [
    { name: "Calculus", color: "#4C6EF5", today: 98 * 60, exam: ["D-5", "red"] },
    { name: "Organic Chem", color: "#20C997", today: 72 * 60, exam: ["D-16", "grey"] },
    { name: "History essay", color: "#FAB005", today: 52 * 60 },
    { name: "Spanish", color: "#F06595", today: 30 * 60 },
  ];

  const $ = (id) => document.getElementById(id);
  const stage = $("stage"), scaler = $("scaler"), win = $("win");
  const paneImg = $("paneImg"), sideHit = $("sideHit"), today = $("today");
  const banner = $("banner");

  // ---------- Formatting ----------
  const pad = (n) => String(n).padStart(2, "0");
  const hms = (s) => `${pad(Math.floor(s / 3600))}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}`;
  const clock = (s) => `${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}`;
  const dur = (s) => (s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`);
  const dateLine = new Date().toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "short" });

  // ---------- Icons ----------
  const icon = {
    play: '<svg width="13" height="13" viewBox="0 0 12 12"><path d="M3 1.9v8.2c0 .6.6.9 1.1.6l6.4-4.1c.4-.3.4-.9 0-1.2L4.1 1.3C3.6 1 3 1.3 3 1.9z" fill="currentColor"/></svg>',
    stop: '<svg width="12" height="12" viewBox="0 0 12 12"><rect x="1.5" y="1.5" width="9" height="9" rx="1.8" fill="currentColor"/></svg>',
    plus: '<svg width="11" height="11" viewBox="0 0 11 11"><path d="M5.5 1v9M1 5.5h9" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>',
    updown: '<svg width="7" height="11" viewBox="0 0 7 11"><path d="M1 4l2.5-2.5L6 4M1 7l2.5 2.5L6 7" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    camera: '<svg width="15" height="12" viewBox="0 0 15 12"><path d="M1 3.5C1 2.7 1.7 2 2.5 2h2L5.6.8C5.8.6 6 .5 6.3.5h2.4c.3 0 .5.1.7.3L10.5 2h2c.8 0 1.5.7 1.5 1.5v6c0 .8-.7 1.5-1.5 1.5h-10C1.7 11 1 10.3 1 9.5z" fill="currentColor"/><circle cx="7.5" cy="6.5" r="2.4" fill="#fff"/></svg>',
    mic: '<svg width="10" height="14" viewBox="0 0 10 14"><rect x="2.5" y="0.5" width="5" height="8.5" rx="2.5" fill="currentColor"/><path d="M1 6.5a4 4 0 008 0M5 10.5v2.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>',
    window: '<svg width="15" height="12" viewBox="0 0 15 12"><rect x="1" y="1" width="13" height="10" rx="2" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M1 4h13" stroke="currentColor" stroke-width="1.3"/></svg>',
    check: '<svg width="12" height="12" viewBox="0 0 12 12"><circle cx="6" cy="6" r="5.5" fill="currentColor"/><path d="M3.5 6.2l1.7 1.7 3.3-3.6" fill="none" stroke="#fff" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    phone: '<svg width="9" height="13" viewBox="0 0 9 13"><rect x="0.7" y="0.7" width="7.6" height="11.6" rx="1.8" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M3.3 2.4h2.4" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/></svg>',
    phoneLarge: '<svg width="17" height="25" viewBox="0 0 9 13"><rect x="0.7" y="0.7" width="7.6" height="11.6" rx="1.8" fill="none" stroke="currentColor" stroke-width="1.1"/><path d="M3.3 2.4h2.4" stroke="currentColor" stroke-width="1" stroke-linecap="round"/></svg>',
    warn: '<svg width="13" height="12" viewBox="0 0 13 12"><path d="M5.6 1.1a1 1 0 011.8 0l5 9.2a1 1 0 01-.9 1.5H1.5a1 1 0 01-.9-1.5z" fill="currentColor"/><path d="M6.5 4.2v3.2" stroke="#fff" stroke-width="1.3" stroke-linecap="round"/><circle cx="6.5" cy="9.3" r=".8" fill="#fff"/></svg>',
    warnLarge: '<svg width="24" height="22" viewBox="0 0 13 12"><path d="M5.6 1.1a1 1 0 011.8 0l5 9.2a1 1 0 01-.9 1.5H1.5a1 1 0 01-.9-1.5z" fill="none" stroke="currentColor" stroke-width=".9"/><path d="M6.5 4.4v3" stroke="currentColor" stroke-width="1" stroke-linecap="round"/><circle cx="6.5" cy="9.2" r=".6" fill="currentColor"/></svg>',
    away: '<svg width="12" height="12" viewBox="0 0 12 12"><circle cx="6" cy="6" r="5" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M6 3.2V6l2 1.3" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>',
    cup: '<svg width="12" height="12" viewBox="0 0 12 12"><path d="M1.5 4h7v3.5a3 3 0 01-3 3h-1a3 3 0 01-3-3zM8.5 5h1a1.5 1.5 0 010 3h-1" fill="none" stroke="currentColor" stroke-width="1.3"/></svg>',
  };

  // ---------- State ----------
  const s = {
    pane: "today",
    phase: "idle",          // idle | running | break
    current: -1,
    status: "focused",      // focused | phone | offTask | away
    suspecting: false, held: 0,
    elapsed: 0, focused: 0, phone: 0, offTask: 0, away: 0, nudges: 0,
    pending: null,          // { kind, t }
    offLabel: "",
    sinceNudge: 0,
  };
  const total = () => subjects.reduce((a, x) => a + x.today, 0);
  const distracted = () => s.status !== "focused";

  // ---------- Build Today ----------
  today.style.left = SIDEBAR.contentX + "px";
  today.innerHTML = `
    <div class="t-title">Today</div>
    <div class="t-col">
      <div class="t-hero">
        <div class="ring" id="ring">
          <svg viewBox="0 0 258 258" id="ringSvg"></svg>
          <div class="ring-in">
            <span class="ring-date">${dateLine}</span>
            <span class="ring-time" id="ringTime"></span>
            <span class="ring-status" id="ringStatus"></span>
          </div>
        </div>
        <div class="goalbar" id="goalbar" hidden>
          <div class="track"><div class="fill" id="goalFill"></div></div>
          <span id="goalText"></span>
        </div>
      </div>
      <div class="card subjects" id="subjects"></div>
      <div class="card" id="lower"></div>
    </div>`;

  const subjectsEl = $("subjects");
  subjectsEl.innerHTML = subjects.map((x, i) => `
    <div class="row" style="--c:${x.color}" data-i="${i}">
      <button class="play" data-i="${i}" aria-label="Start ${x.name}">${icon.play}</button>
      <span class="row-name">${x.name}</span>
      ${x.exam ? `<span class="chip ${x.exam[1]}">${x.exam[0]}</span>` : ""}
      <span class="row-time"></span>
    </div>`).join("") + `<div class="add">${icon.plus}Add Subject</div>`;
  const rows = [...subjectsEl.querySelectorAll(".row")];

  subjectsEl.addEventListener("click", (e) => {
    const b = e.target.closest(".play");
    if (!b) return;
    const i = +b.dataset.i;
    if (s.phase !== "idle" && s.current === i) end();
    else start(i);
  });

  // ---------- Session ----------
  let timer = null;
  function start(i) {
    if (s.phase === "idle") {
      Object.assign(s, { elapsed: 0, focused: 0, phone: 0, offTask: 0, away: 0, nudges: 0 });
      timer = setInterval(tick, 1000);
      // A few seconds in, the student picks up their phone.
      s.pending = { kind: "phone", t: -4 };
    }
    s.current = i;
    s.phase = "running";
    render();
  }
  function end() {
    resolve();
    s.phase = "idle";
    s.current = -1;
    clearInterval(timer);
    render();
  }
  function takeBreak() { resolve(); s.phase = "break"; render(); }
  function resume() { s.phase = "running"; render(); }

  function tick() {
    if (s.phase === "idle") return;
    s.elapsed++;
    if (s.phase === "running") {
      if (s.status === "focused") {
        if (s.suspecting) s.held++;
        else { s.focused++; subjects[s.current].today++; }
      } else {
        s[s.status]++;
        // Firm strictness: another banner every 30 seconds while you stay distracted.
        if (s.status !== "away" && ++s.sinceNudge >= 30) nudge();
      }
      if (s.pending) advance();
    }
    render();
  }

  // Scripted detection, roughly at the app's speed.
  function advance() {
    const p = s.pending;
    p.t++;
    if (p.kind === "phone") {
      if (p.t === 4) s.suspecting = true;          // evidence past halfway: time is held back
      if (p.t === 9) {                              // flagged: the held time becomes phone time
        s.suspecting = false;
        s.phone += s.held; s.held = 0;
        s.status = "phone";
        nudge();
      }
    }
  }

  // Switching to another tab during a session is caught for real.
  document.addEventListener("visibilitychange", () => {
    if (s.phase !== "running") return;
    if (document.hidden) {
      resolve();
      s.offLabel = "another tab";
      s.status = "offTask";
    } else if (s.status === "offTask") {
      nudge();
      setTimeout(() => { if (s.status === "offTask") back(); }, 4000);
    }
    render();
  });

  // Back to work. Suspected-but-unconfirmed time is given back.
  function resolve() {
    if (s.held && s.current >= 0) { s.focused += s.held; subjects[s.current].today += s.held; }
    s.held = 0;
    s.suspecting = false;
    s.status = "focused";
    s.pending = null;
    hideBanner();
  }

  // ---------- Banner ----------
  let bannerTimer = null;
  function nudge() {
    s.nudges++;
    s.sinceNudge = 0;
    const subject = subjects[s.current].name;
    if (s.status === "phone") {
      showBanner(icon.phoneLarge, "Phone use detected", "Signals: head down · not typing · sound not from the Mac.",
        [["Writing Notes", back], ["Not My Phone", back]]);
    } else {
      showBanner(icon.warnLarge, `Off task: ${s.offLabel}`, `Not related to ${subject}.`, [["Mark as Study", back]]);
    }
  }
  function back() { resolve(); render(); }
  function showBanner(svg, title, msg, actions) {
    $("bannerIcon").innerHTML = svg;
    $("bannerTitle").textContent = title;
    $("bannerMsg").textContent = msg;
    const box = $("bannerActions");
    box.innerHTML = "";
    for (const [label, fn] of actions) {
      const b = document.createElement("button");
      b.className = "push";
      b.textContent = label;
      b.addEventListener("click", fn);
      box.appendChild(b);
    }
    banner.hidden = false;
    clearTimeout(bannerTimer);
    bannerTimer = setTimeout(hideBanner, 9000);
  }
  function hideBanner() { banner.hidden = true; clearTimeout(bannerTimer); }
  $("bannerX").addEventListener("click", hideBanner);

  // ---------- Render ----------
  function ring() {
    const C = 2 * Math.PI * 120;
    const segs = subjects.map((x) => ({ color: x.color, f: x.today / GOAL_DAY })).filter((x) => x.f > 0);
    let start = 0, arcs = "";
    for (const g of segs) {
      if (start >= 1) break;
      const end = Math.min(start + g.f, 1);
      const gap = segs.length > 1 && end - start > 0.01 ? 0.004 : 0;
      arcs += `<circle cx="129" cy="129" r="120" fill="none" stroke="${g.color}" stroke-width="18"
        stroke-dasharray="${(end - start - gap) * C} ${C}" stroke-dashoffset="${-start * C}" transform="rotate(-90 129 129)"/>`;
      start = end;
    }
    $("ringSvg").innerHTML = `<circle cx="129" cy="129" r="120" fill="none" stroke="var(--w-track)" stroke-width="18"/>` + arcs;
  }

  function render() {
    const active = s.phase !== "idle";
    const sub = subjects[s.current];
    const paused = s.phase === "break" || (active && distracted());
    ring();
    $("ring").classList.toggle("dim", paused);
    $("ringTime").textContent = hms(total());

    const st = $("ringStatus");
    st.className = "ring-status";
    st.style.color = "";
    if (!active) st.textContent = `${Math.round((total() / GOAL_DAY) * 100)}% of 5h goal`;
    else {
      st.classList.add("strong");
      if (s.phase === "break") { st.textContent = "On break"; st.style.color = "#007AFF"; }
      else if (s.status === "phone") st.textContent = "Paused · Phone";
      else if (s.status === "offTask") st.textContent = "Paused · Off task";
      else if (s.status === "away") st.textContent = "Paused · Away";
      else if (s.suspecting) st.textContent = `Checking… (${dur(s.held)} on hold)`;
      else { st.textContent = sub.name; st.style.color = sub.color; }
    }

    $("goalbar").hidden = !active;
    if (active) {
      $("goalFill").style.width = `${Math.min(s.focused / GOAL_SESSION, 1) * 100}%`;
      $("goalFill").style.background = sub.color;
      $("goalText").textContent = `${Math.ceil((GOAL_SESSION - s.focused) / 60)} min to go`;
    }

    rows.forEach((r, i) => {
      const cur = active && i === s.current;
      r.classList.toggle("current", cur);
      r.querySelector(".row-time").textContent = hms(subjects[i].today);
      const b = r.querySelector(".play");
      b.innerHTML = cur ? icon.stop : icon.play;
      b.setAttribute("aria-label", `${cur ? "Stop" : "Start"} ${subjects[i].name}`);
    });

    const lower = $("lower");
    if (!active) {
      if (lower.dataset.mode !== "idle") {
        lower.dataset.mode = "idle";
        lower.className = "card opts";
        lower.innerHTML = `
          <span>Goal</span><span class="popup">50 min ${icon.updown}</span>
          <span>Strictness</span><span class="popup">Firm ${icon.updown}</span>
          <span>Style</span><span class="popup">Both ${icon.updown}</span>
          <span class="sensors"><span class="sensor">${icon.camera}</span><span class="sensor">${icon.mic}</span><span class="sensor">${icon.window}</span></span>`;
      }
    } else {
      if (lower.dataset.mode !== "running") {
        lower.dataset.mode = "running";
        lower.className = "card running";
        lower.innerHTML = `
          <div class="run-top"><span class="badge" id="badge"></span>
            <button class="push" id="breakBtn"></button><button class="push" id="endBtn">End Session</button></div>
          <div class="tiles" id="tiles"></div>`;
        $("breakBtn").addEventListener("click", () => (s.phase === "break" ? resume() : takeBreak()));
        $("endBtn").addEventListener("click", end);
      }
      const badge = $("badge");
      const [label, color, ic] =
        s.phase === "break" ? ["On break", "#007AFF", icon.cup] :
        s.status === "phone" ? ["Phone", "#E39B2E", icon.phone] :
        s.status === "offTask" ? [`Off task: ${s.offLabel}`, "#E39B2E", icon.warn] :
        s.status === "away" ? ["Away", "#007AFF", icon.away] :
        ["Focused", "#28A745", icon.check];
      badge.style.setProperty("--bc", color);
      badge.innerHTML = ic + label;
      $("breakBtn").textContent = s.phase === "break" ? "Resume" : "Break";
      $("tiles").innerHTML = [
        ["Session", clock(s.elapsed)], ["Phone", dur(s.phone)], ["Off task", dur(s.offTask)],
        ["Away", dur(s.away)], ["Nudges", s.nudges],
      ].map(([t, v]) => `<div class="tile"><b>${v}</b><span>${t}</span></div>`).join("");
    }

  }


  // ---------- Sidebar and panes ----------
  const dark = matchMedia("(prefers-color-scheme: dark)");
  const mode = () => (document.documentElement.dataset.theme || (dark.matches ? "dark" : "light"));
  function showPane(id) {
    s.pane = id;
    paneImg.style.backgroundImage = `url("img/panes/pane-${id}-${mode()}.png")`;
    today.hidden = id !== "today";
  }
  sideHit.style.left = SIDEBAR.x + "px";
  sideHit.style.width = SIDEBAR.width + "px";
  for (const [id, y] of PANES) {
    const b = document.createElement("button");
    b.style.top = y - ROW_H / 2 + "px";
    b.style.height = ROW_H + "px";
    b.setAttribute("aria-label", id[0].toUpperCase() + id.slice(1));
    b.addEventListener("click", () => showPane(id));
    sideHit.appendChild(b);
  }
  dark.addEventListener("change", () => showPane(s.pane));
  // Warm the cache so switching panes doesn't flash.
  addEventListener("load", () => {
    for (const [id] of PANES) new Image().src = `img/panes/pane-${id}-${mode()}.png`;
  });

  // ---------- Fit the 1000x740 window to the page ----------
  function fit() {
    const avail = stage.clientWidth;
    const narrow = avail < 640;
    const cropX = narrow ? SIDEBAR.contentX : 0;
    const scale = Math.min(1, avail / (W - cropX));
    win.style.transform = `translateX(${-cropX * scale}px) scale(${scale})`;
    scaler.style.height = H * scale + "px";
    scaler.style.width = (W - cropX) * scale + "px";
  }
  addEventListener("resize", fit);
  fit();
  showPane("today");
  render();
})();
