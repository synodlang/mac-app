// Compare host: two players side by side, the left one drives. Runs after the player IIFE (user script,
// document end) and talks to Swift through the synodHost message handler. The right player is never
// played; on every animation frame it is seeked to the time that matches the left one, either by
// simulated time (through the sync maps) or by presentation time.
//
// Events posted: ready, time {T, atL, atR}, marker {marker} (left side), play, pause {reason}, click
// {side, x, y, hit}, scene {durationL, durationR}, error {message}.
(() => {
  const host = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.synodHost;
  const post = (message) => {
    try { if (host) host.postMessage(message); } catch (_) { /* closed web view */ }
  };
  const describe = (e) => String((e && e.message) || e);
  window.addEventListener("error", (e) => post({ event: "error", message: describe(e.error || e.message) }));
  window.addEventListener("unhandledrejection", (e) => post({ event: "error", message: describe(e.reason) }));

  // As in stage.js: WebKit never calls requestAnimationFrame in a view that is not visible, so race the
  // native callback against a timer.
  const nativeRaf = window.requestAnimationFrame.bind(window);
  const nativeCaf = window.cancelAnimationFrame.bind(window);
  const pending = new Map();
  let nextHandle = 1;
  window.requestAnimationFrame = (cb) => {
    const handle = nextHandle++;
    const fire = () => {
      const entry = pending.get(handle);
      if (!entry) return;
      pending.delete(handle);
      nativeCaf(entry.raf);
      clearTimeout(entry.timer);
      cb(performance.now());
    };
    pending.set(handle, { raf: nativeRaf(fire), timer: setTimeout(fire, document.hidden ? 33 : 100) });
    return handle;
  };
  window.cancelAnimationFrame = (handle) => {
    const entry = pending.get(handle);
    if (!entry) return;
    pending.delete(handle);
    nativeCaf(entry.raf);
    clearTimeout(entry.timer);
  };

  // ---- Sync maps: knots [[T_us, at_ms], ...], piecewise linear, T ascending. -----------------------
  function normalizeKnots(knots, duration) {
    const out = [];
    for (const k of knots || []) {
      if (!Array.isArray(k) || k.length < 2) continue;
      const T = Number(k[0]);
      let at = Number(k[1]);
      if (!isFinite(T) || !isFinite(at)) continue;
      if (out.length) {
        if (T < out[out.length - 1][0]) continue;
        at = Math.max(at, out[out.length - 1][1]);   // monotone
      }
      out.push([T, at]);
    }
    if (out.length === 0) out.push([0, 0], [Math.max(1, duration * 1000), duration]);
    return out;
  }
  // at(T): interpolates linearly and clamps.
  function atOf(knots, T) {
    if (T <= knots[0][0]) return knots[0][1];
    for (let i = 1; i < knots.length; i++) {
      if (T <= knots[i][0]) {
        const [t0, a0] = knots[i - 1], [t1, a1] = knots[i];
        return t1 === t0 ? a1 : a0 + ((T - t0) / (t1 - t0)) * (a1 - a0);
      }
    }
    return knots[knots.length - 1][1];
  }
  // T(at): the smallest T with at(T) >= at; clamps at both ends.
  function tOf(knots, at) {
    if (at <= knots[0][1]) return knots[0][0];
    for (let i = 1; i < knots.length; i++) {
      if (at <= knots[i][1]) {
        const [t0, a0] = knots[i - 1], [t1, a1] = knots[i];
        return a1 === a0 ? t1 : t0 + ((at - a0) / (a1 - a0)) * (t1 - t0);
      }
    }
    return knots[knots.length - 1][0];
  }

  function posterTime(text) {
    try {
      const scene = JSON.parse(text);
      const cap = Math.min(1000, (scene.duration || 0) / 4);
      const times = new Set();
      for (const shape of scene.shapes || []) for (const k of shape.keys || []) times.add(k.at);
      let at = 0;
      for (const t of Array.from(times).sort((x, y) => x - y)) {
        if (t - at > 300 || t > cap) break;
        at = t;
      }
      return at;
    } catch (_) {
      return 0;
    }
  }

  // ---- One side: canvas, player, overlay, knots. ----------------------------------------------------
  function makeSide(name, pane, canvas) {
    const overlay = document.createElement("canvas");
    overlay.style.cssText = "position:absolute;pointer-events:none;left:0;top:0;width:100%;height:100%;";
    pane.appendChild(overlay);
    const side = { name, pane, canvas, overlay, player: null, knots: [[0, 0]], duration: 0, drawn: false, lastSeek: NaN };
    canvas.addEventListener("pointerup", (e) => {
      if (!side.player || e.button !== 0) return;
      const r = canvas.getBoundingClientRect();
      const x = e.clientX - r.left, y = e.clientY - r.top;
      post({ event: "click", side: side.name, x, y, hit: side.player.hitTest(x, y) });
    });
    return side;
  }

  const state = { mode: "sim", selection: null, rate: 1, lastPost: 0 };
  let L = null, R = null;
  const wired = new WeakSet();

  function wireLeft(side) {
    const p = side.player;
    if (wired.has(p)) return;
    wired.add(p);
    p.on("marker", (e) => { if (L === side) post({ event: "marker", marker: e.marker }); });
    p.on("play", () => { if (L === side) post({ event: "play" }); });
    p.on("pause", (e) => { if (L === side) post({ event: "pause", reason: e.reason }); });
  }

  function loadSide(side, text, knots) {
    if (side.player) {
      side.player.setScene(text, { keepTime: false });
    } else {
      side.player = SynodPlayer.createPlayer(side.canvas, text, { autoplay: false, stopAtPause: false, fontBase: window.synodFontBase });
    }
    side.duration = side.player.duration;
    side.knots = normalizeKnots(knots, side.duration);
    side.lastSeek = NaN;
    side.player.setStopAtPause(false);
    wireLeft(side);
  }

  function rightTime() {
    const atL = L.player.time;
    if (state.mode === "presentation") return Math.min(atL, R.duration);
    return atOf(R.knots, tOf(L.knots, atL));
  }

  function syncRight(force) {
    if (!L || !R || !L.player || !R.player) return;
    const atR = rightTime();
    if (force || atR !== R.lastSeek) {
      R.lastSeek = atR;
      R.player.seek(atR);
    }
  }

  function drawOverlay(side) {
    const need = state.selection !== null;
    if (!need && !side.drawn) return;
    const r = side.canvas.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    const w = Math.max(1, Math.round(r.width * dpr)), h = Math.max(1, Math.round(r.height * dpr));
    if (side.overlay.width !== w || side.overlay.height !== h) { side.overlay.width = w; side.overlay.height = h; }
    const ctx = side.overlay.getContext("2d");
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, w, h);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    if (need && side.player) {
      const box = side.player.nodeBounds().find((b) => b.node === state.selection);
      if (box) {
        ctx.lineWidth = 2;
        ctx.strokeStyle = "#F4A340";
        ctx.strokeRect(box.x - 4, box.y - 4, box.w + 8, box.h + 8);
      }
    }
    side.drawn = need;
  }

  function currentTimes() {
    const atL = L.player.time;
    const T = tOf(L.knots, atL);
    return { T, atL, atR: R.player ? R.lastSeek : 0 };
  }

  function frame() {
    if (L && R && L.player && R.player) {
      syncRight(false);
      const now = performance.now();
      if (now - state.lastPost >= 33) {
        state.lastPost = now;
        const t = currentTimes();
        post({ event: "time", T: t.T, atL: t.atL, atR: Number.isNaN(t.atR) ? 0 : t.atR });
      }
      drawOverlay(L);
      drawOverlay(R);
    }
    window.requestAnimationFrame(frame);
  }

  function info() {
    return {
      durationL: L && L.player ? L.duration : 0,
      durationR: R && R.player ? R.duration : 0,
      warningsL: L && L.player ? Array.from(L.player.warnings) : [],
      warningsR: R && R.player ? Array.from(R.player.warnings) : [],
      playing: !!(L && L.player && L.player.playing),
      rate: state.rate,
      sync: state.mode,
    };
  }

  function boot() {
    L = makeSide("left", document.getElementById("paneA"), document.getElementById("canvasA"));
    R = makeSide("right", document.getElementById("paneB"), document.getElementById("canvasB"));
    const sideOf = (s) => (s === "right" ? R : L);

    window.compare = {
      info,
      // Loads both scenes; knots are [[T_us, at_ms], ...] per run (SyncMap). Shows the left poster frame.
      setScenes(textL, textR, knotsL, knotsR) {
        loadSide(L, textL, knotsL);
        loadSide(R, textR, knotsR);
        L.player.setRate(state.rate);
        const at = posterTime(textL);
        if (at > 0) L.player.seek(at);
        syncRight(true);
        post({ event: "scene", durationL: L.duration, durationR: R.duration });
        return info();
      },
      play() { if (L && L.player) L.player.play(); },
      pause() {
        if (!L || !L.player) return;
        L.player.pause();
        syncRight(true);   // the right side lands exactly where the left one stopped
      },
      // Seeks both sides to simulated time T (microseconds, in the left run's clock).
      seekSim(T) {
        if (!L || !L.player) return;
        L.player.seek(atOf(L.knots, T));
        syncRight(true);
      },
      seek(at) {
        if (!L || !L.player) return;
        L.player.seek(at);
        syncRight(true);
      },
      setRate(r) { state.rate = r; if (L && L.player) L.player.setRate(r); if (R && R.player) R.player.setRate(r); },
      setSync(mode) {
        state.mode = mode === "presentation" ? "presentation" : "sim";
        syncRight(true);
      },
      // Exchanges the two runs: the new left drives, at the same simulated time.
      swap() {
        if (!L || !R || !L.player || !R.player) return;
        const wasPlaying = L.player.playing;
        const T = tOf(L.knots, L.player.time);
        L.player.pause();
        const panes = document.getElementById("panes");
        const a = L.pane, b = R.pane;
        panes.insertBefore(b, a);   // b now precedes a
        [L, R] = [R, L];
        L.name = "left"; R.name = "right";
        L.player.setRate(state.rate);
        L.player.seek(atOf(L.knots, T));
        syncRight(true);
        if (wasPlaying) L.player.play();
        return info();
      },
      hitTest(side, x, y) {
        const s = sideOf(side);
        return s.player ? s.player.hitTest(x, y) : null;
      },
      nodeBounds(side) {
        const s = sideOf(side);
        return s.player ? s.player.nodeBounds() : [];
      },
      // Outlines the named node on both sides (null clears it).
      setSelection(node) { state.selection = node === null || node === undefined ? null : String(node); },
      times() { return L && L.player && R && R.player ? currentTimes() : { T: 0, atL: 0, atR: 0 }; },
      // Test hooks for the sync maps.
      _atOf: atOf, _tOf: tOf,
    };

    window.requestAnimationFrame(frame);
    document.fonts.ready.then(() => post({ event: "ready" }));
  }

  try { boot(); } catch (e) { post({ event: "error", fatal: true, message: describe(e) }); }
})();
