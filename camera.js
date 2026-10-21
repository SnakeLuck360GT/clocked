// "Try it with your camera": a small Developer View that runs entirely in the browser.
// MediaPipe (self-hosted in vendor/ and models/) finds the face, eyes, hands and phones; the evidence
// rules below are a simplified copy of the app's. Frames are never stored or sent anywhere.

const $ = (id) => document.getElementById(id);
const cam = $("cam"), video = $("camVideo"), canvas = $("camCanvas"), ctx = canvas.getContext("2d");
const startBox = $("camStart"), startBtn = $("camBtn"), msg = $("camMsg"), stopBtn = $("camStop");

const THRESHOLD = 10;
let face, hands, objects, running = false, stream = null;

// ---------- Input timing (counts only, never which keys) ----------
let lastKey = -1e9, lastPointer = -1e9;
addEventListener("keydown", () => (lastKey = performance.now()));
for (const ev of ["mousemove", "pointerdown", "wheel", "touchstart"]) addEventListener(ev, () => (lastPointer = performance.now()), { passive: true });

// ---------- Models ----------
async function loadModels() {
  const { FilesetResolver, FaceLandmarker, HandLandmarker, ObjectDetector } = await import("./vendor/mediapipe/vision_bundle.mjs");
  const files = await FilesetResolver.forVisionTasks(new URL("vendor/mediapipe/wasm", location.href).href);
  const opts = (path) => ({ baseOptions: { modelAssetPath: new URL(path, location.href).href, delegate: "GPU" }, runningMode: "VIDEO" });
  const make = async (Task, path, extra, gpu = true) => {
    const cpu = () => { const o = opts(path); o.baseOptions.delegate = "CPU"; return Task.createFromOptions(files, { ...o, ...extra }); };
    if (!gpu) return cpu();
    try { return await Task.createFromOptions(files, { ...opts(path), ...extra }); } catch { return cpu(); }
  };
  [face, hands, objects] = await Promise.all([
    make(FaceLandmarker, "models/face_landmarker.task", { numFaces: 1, outputFaceBlendshapes: true, outputFacialTransformationMatrixes: true }),
    make(HandLandmarker, "models/hand_landmarker.task", { numHands: 2 }),
    make(ObjectDetector, "models/efficientdet_lite2.tflite", { scoreThreshold: 0.2, categoryAllowlist: ["cell phone"], maxResults: 2 }, false), // the GPU path gives garbage in WebKit
  ]);
  return { FaceLandmarker, HandLandmarker };
}

// ---------- Start / stop ----------
let K;
async function start() {
  startBtn.disabled = true;
  msg.textContent = "Loading…";
  try {
    const testSrc = video.dataset.src; // used by the site's own tests in place of a camera
    const [models] = await Promise.all([
      loadModels(),
      testSrc ? Promise.resolve() : navigator.mediaDevices.getUserMedia({ video: { width: 640, height: 480, facingMode: "user" }, audio: false })
        .then((s) => { stream = s; video.srcObject = s; }),
    ]);
    K = models;
    if (testSrc) { video.src = testSrc; video.loop = true; }
    await video.play();
  } catch (e) {
    startBtn.disabled = false;
    msg.textContent = e && e.name === "NotAllowedError" ? "Camera access was blocked. Allow it in your browser to try this." : "Couldn't start the camera here.";
    stop();
    return;
  }
  reset();
  running = true;
  cam.classList.add("live");
  msg.textContent = "";
  requestAnimationFrame(loop);
}

function stop() {
  running = false;
  if (stream) stream.getTracks().forEach((t) => t.stop());
  stream = null;
  video.srcObject = null;
  cam.classList.remove("live");
  startBtn.disabled = false;
  ctx.clearRect(0, 0, canvas.width, canvas.height);
}

startBtn.addEventListener("click", start);
stopBtn.addEventListener("click", stop);
// The camera turns off as soon as you leave the tab.
document.addEventListener("visibilitychange", () => { if (document.hidden && running && !video.dataset.src) stop(); });

// ---------- Evidence (simplified from PhoneEvidence.swift) ----------
const st = {};
function reset() {
  Object.assign(st, {
    score: 0, onScreenFor: 0, noFaceFor: 0, flagged: false, flaggedAt: 0,
    study: 0, held: 0, phone: 0, baseline: null, samples: [],
  });
}

function median(a) { const b = [...a].sort((x, y) => x - y); return b[Math.floor(b.length / 2)]; }

function step(dt, now, f) {
  const typing = now - lastKey < 1500;
  const still = now - Math.max(lastKey, lastPointer) > 3000;

  // Head pitch relative to your own screen posture, learned in the first moments and while typing.
  let headDown = false, eyesDown = false, smile = false;
  if (f.present) {
    // Everything is compared with how you look at the screen, like the app's posture baseline.
    if (st.baseline === null) {
      st.samples.push(f);
      if (st.samples.length >= 45) st.baseline = {
        pitch: median(st.samples.map((x) => x.pitch)),
        lookDown: median(st.samples.map((x) => x.lookDown)),
        blink: median(st.samples.map((x) => x.blink)),
      };
    } else {
      const b = st.baseline;
      if (typing) for (const k of ["pitch", "lookDown", "blink"]) b[k] += (f[k] - b[k]) * 0.05;
      headDown = f.pitch - b.pitch > 12;
      eyesDown = f.lookDown - b.lookDown > 0.15 || f.blink - b.blink > 0.25;
    }
    smile = f.smile > 0.5;
  }
  const down = headDown || eyesDown;
  const cues = {
    head: headDown,
    eyes: eyesDown && !headDown,
    still: still && down,
    smile: smile && down,
    phone: f.phone > 0,
    typing,
    screen: f.present && !down && !f.phone,
  };

  let rate = (cues.head ? 0.55 : 0) + (cues.eyes ? 0.35 : 0) + (cues.still ? 0.45 : 0) + (cues.smile ? 0.3 : 0) + (cues.phone ? 3 : 0);
  if (typing) st.score *= Math.pow(0.25, dt);
  else if (rate > 0) { st.score += rate * dt; st.onScreenFor = 0; }
  else if (cues.screen) {
    st.onScreenFor += dt;
    st.score = st.onScreenFor >= 2 ? st.score * Math.pow(0.5, dt) : st.score - dt;
  } else st.score -= 0.5 * dt;
  st.score = Math.min(Math.max(st.score, 0), THRESHOLD * 1.5);

  st.noFaceFor = f.present ? 0 : st.noFaceFor + dt;
  const away = st.noFaceFor > 5;

  // Flagged: stays on your phone until you type or use the mouse again.
  if (!st.flagged && st.score >= THRESHOLD) { st.flagged = true; st.flaggedAt = now; st.phone += st.held; st.held = 0; }
  if (st.flagged && Math.max(lastKey, lastPointer) > st.flaggedAt + 300) { st.flagged = false; st.score = THRESHOLD * 0.3; }

  // The study clock: held back past halfway, given back if it fades, moved to phone time if flagged.
  if (st.flagged) st.phone += dt;
  else if (away) { /* paused */ }
  else if (st.score >= THRESHOLD / 2) st.held += dt;
  else {
    if (st.held && st.score < THRESHOLD * 0.25) { st.study += st.held; st.held = 0; }
    if (!st.held) st.study += dt;
  }
  return { cues, away };
}

// ---------- Detection loop ----------
let readings = null;
// For checking the thresholds: the latest raw readings (numbers only).
export const debug = () => ({ ...readings, baseline: st.baseline, score: st.score });
let lastT = -1, frame = 0, lastHands = [], lastPhones = [], prev = performance.now();
function loop(now) {
  if (!running) return;
  requestAnimationFrame(loop);
  if (video.readyState < 2 || video.currentTime === lastT) return;
  lastT = video.currentTime;
  frame++;

  const fr = face.detectForVideo(video, now);
  if (frame % 2 === 0) lastHands = hands.detectForVideo(video, now).landmarks || [];
  if (frame % 5 === 0) lastPhones = (objects.detectForVideo(video, now).detections || []).filter((d) => d.categories[0].score >= 0.22);

  const lm = fr.faceLandmarks && fr.faceLandmarks[0];
  const f = { present: !!lm, pitch: 0, lookDown: 0, blink: 0, smile: 0, phone: lastPhones.length };
  if (lm) {
    const m = fr.facialTransformationMatrixes && fr.facialTransformationMatrixes[0];
    if (m) f.pitch = (Math.atan2(-m.data[9], m.data[10]) * 180) / Math.PI;
    const bs = {};
    for (const c of (fr.faceBlendshapes && fr.faceBlendshapes[0] && fr.faceBlendshapes[0].categories) || []) bs[c.categoryName] = c.score;
    f.lookDown = ((bs.eyeLookDownLeft || 0) + (bs.eyeLookDownRight || 0)) / 2;
    f.smile = ((bs.mouthSmileLeft || 0) + (bs.mouthSmileRight || 0)) / 2;
    f.blink = ((bs.eyeBlinkLeft || 0) + (bs.eyeBlinkRight || 0)) / 2;
  }
  readings = f;

  const dt = Math.min((now - prev) / 1000, 0.25);
  prev = now;
  const r = step(dt, now, f);
  draw(lm, f);
  readout(r);
}

// ---------- Drawing (mirrored, like a selfie view) ----------
function draw(lm, f) {
  const vw = video.videoWidth, vh = video.videoHeight;
  const W = canvas.clientWidth, H = canvas.clientHeight, dpr = devicePixelRatio || 1;
  if (canvas.width !== Math.round(W * dpr)) { canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr); }
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  // Cover-fit the video into the canvas.
  const s = Math.max(W / vw, H / vh), dw = vw * s, dh = vh * s, ox = (W - dw) / 2, oy = (H - dh) / 2;
  ctx.save();
  ctx.translate(W, 0);
  ctx.scale(-1, 1);
  ctx.drawImage(video, W - ox - dw, oy, dw, dh);
  ctx.restore();
  const X = (x) => W - (ox + x * dw), Y = (y) => oy + y * dh;

  const path = (pts, conn, color, width) => {
    ctx.strokeStyle = color;
    ctx.lineWidth = width;
    ctx.beginPath();
    for (const { start, end } of conn) {
      ctx.moveTo(X(pts[start].x), Y(pts[start].y));
      ctx.lineTo(X(pts[end].x), Y(pts[end].y));
    }
    ctx.stroke();
  };

  if (lm) {
    const FL = K.FaceLandmarker;
    path(lm, FL.FACE_LANDMARKS_FACE_OVAL, "rgba(255,255,255,0.45)", 1);
    path(lm, FL.FACE_LANDMARKS_LEFT_EYE, "rgba(255,255,255,0.8)", 1);
    path(lm, FL.FACE_LANDMARKS_RIGHT_EYE, "rgba(255,255,255,0.8)", 1);
    path(lm, FL.FACE_LANDMARKS_LIPS, "rgba(255,255,255,0.5)", 1);
    ctx.fillStyle = "#FF9150";
    for (const i of [468, 473]) if (lm[i]) { ctx.beginPath(); ctx.arc(X(lm[i].x), Y(lm[i].y), 2.5, 0, 7); ctx.fill(); }

    // Face box with the head angle.
    let x0 = 1, y0 = 1, x1 = 0, y1 = 0;
    for (const p of lm) { x0 = Math.min(x0, p.x); y0 = Math.min(y0, p.y); x1 = Math.max(x1, p.x); y1 = Math.max(y1, p.y); }
    const bx = X(x1), by = Y(y0), bw = X(x0) - X(x1), bh = Y(y1) - Y(y0);
    const down = st.baseline !== null ? Math.round(f.pitch - st.baseline.pitch) : null;
    ctx.strokeStyle = "rgba(255,255,255,0.9)";
    ctx.lineWidth = 1.5;
    ctx.strokeRect(bx, by, bw, bh);
    label(down === null ? "learning your screen posture" : `head ${down >= 0 ? "down" : "up"} ${Math.abs(down)}°`, bx, by < 22 ? by + 22 : by, "rgba(255,255,255,0.9)", "#111");
  }

  for (const h of lastHands) path(h, K.HandLandmarker.HAND_CONNECTIONS, "#51CF66", 2);

  for (const d of lastPhones) {
    const b = d.boundingBox;
    const x = W - (ox + ((b.originX + b.width) / vw) * dw), y = oy + (b.originY / vh) * dh;
    const w = (b.width / vw) * dw, h = (b.height / vh) * dh;
    ctx.strokeStyle = "#EF4F2C";
    ctx.lineWidth = 2.5;
    ctx.strokeRect(x, y, w, h);
    label(`phone ${Math.round(d.categories[0].score * 100)}%`, x, y < 22 ? y + 22 : y, "#EF4F2C", "#fff");
  }
}

function label(text, x, y, bg, fg) {
  ctx.font = "600 12px -apple-system, BlinkMacSystemFont, sans-serif";
  const w = ctx.measureText(text).width + 10;
  ctx.fillStyle = bg;
  ctx.fillRect(x - 0.75, y - 20, w, 20);
  ctx.fillStyle = fg;
  ctx.textBaseline = "middle";
  ctx.fillText(text, x + 4.25, y - 10);
}

// ---------- Readout ----------
const pad = (n) => String(n).padStart(2, "0");
const clock = (s) => { s = Math.floor(s); return `${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}`; };
const cueEls = [...document.querySelectorAll("#cues li")];
function readout({ cues, away }) {
  $("roClock").textContent = clock(st.study);
  const state = st.flagged ? "phone" : away ? "away" : st.held > 0 ? "held" : "study";
  $("readout").dataset.state = state;
  $("roState").textContent =
    state === "phone" ? `On your phone. Clock stopped${st.phone >= 1 ? `, ${Math.round(st.phone)}s of phone time` : ""}` :
    state === "away" ? "Away" :
    state === "held" ? `Holding back ${Math.round(st.held)}s` : "Studying";
  const pct = Math.min(st.score / THRESHOLD, 1);
  $("meterFill").style.width = `${pct * 100}%`;
  for (const li of cueEls) li.classList.toggle("on", !!cues[li.dataset.cue]);
}
