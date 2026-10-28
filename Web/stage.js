// Stage host: runs after the player IIFE (user script, document end).
// Talks to Swift through the synodHost message handler (ready, error) and,
// via SynodPlayer.mount, through synodPlayer (time, marker, fact, play, pause, scene).
(() => {
  const host = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.synodHost;
  const post = (message) => {
    try { if (host) host.postMessage(message); } catch (_) { /* closed web view */ }
  };
  const describe = (e) => String((e && e.message) || e);
  window.addEventListener("error", (e) => post({ event: "error", message: describe(e.error || e.message) }));
  window.addEventListener("unhandledrejection", (e) => post({ event: "error", message: describe(e.reason) }));

  const toBase64 = (blob) =>
    new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result).split(",", 2)[1]);
      reader.onerror = () => reject(reader.error);
      reader.readAsDataURL(blob);
    });

  // WebKit never calls requestAnimationFrame in a view that is not visible (headless smoke runs, no
  // window server frames). The player reads window.requestAnimationFrame on every call, so race the
  // native callback against a timer; the first to fire wins and the other is dropped. Playback stays
  // wall-clock paced because the player's clock reads performance.now().
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

  // The poster frame of a scene: the end of its opening burst of animation keys (gaps of at most
  // 300 ms, capped at 1 s or a quarter of the scene). A scene's frame at 0 ms is usually empty or a
  // pile of shapes still at their spawn point, which would leave the stage blank until Play.
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

  // Selection outline and drag rectangle: an overlay canvas over the player's canvas. It is not part of
  // the player's canvas, so exported and rendered frames never contain it.
  function installOverlay(player, canvas) {
    const root = canvas.parentElement;
    const overlay = document.createElement("canvas");
    overlay.style.cssText = "position:absolute;pointer-events:none;left:0;top:0;";
    root.appendChild(overlay);
    const state = { selection: null, drag: null };

    const local = (e) => {
      const r = canvas.getBoundingClientRect();
      return { x: e.clientX - r.left, y: e.clientY - r.top };
    };
    const intersects = (a, b) => a.x <= b.x + b.w && b.x <= a.x + a.w && a.y <= b.y + b.h && b.y <= a.y + a.h;

    let down = null;
    canvas.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return;
      const p = local(e);
      down = { x0: p.x, y0: p.y, id: e.pointerId, moved: false };
      try { canvas.setPointerCapture(e.pointerId); } catch (_) { /* synthetic event */ }
    });
    canvas.addEventListener("pointermove", (e) => {
      if (!down || e.pointerId !== down.id) return;
      const p = local(e);
      if (!down.moved && Math.hypot(p.x - down.x0, p.y - down.y0) > 4) down.moved = true;
      if (down.moved) {
        state.drag = { x: Math.min(down.x0, p.x), y: Math.min(down.y0, p.y), w: Math.abs(p.x - down.x0), h: Math.abs(p.y - down.y0) };
      }
    });
    const finish = (e) => {
      if (!down || e.pointerId !== down.id) return;
      const p = local(e);
      const wasDrag = down.moved;
      const start = down;
      down = null;
      state.drag = null;
      if (wasDrag) {
        const rect = { x: Math.min(start.x0, p.x), y: Math.min(start.y0, p.y), w: Math.abs(p.x - start.x0), h: Math.abs(p.y - start.y0) };
        const nodes = player.nodeBounds().filter((b) => intersects(rect, b)).map((b) => b.node);
        post({ event: "box", rect, nodes });
      } else if (e.type === "pointerup") {
        post({ event: "click", x: p.x, y: p.y, hit: player.hitTest(p.x, p.y) });
      }
    };
    canvas.addEventListener("pointerup", finish);
    canvas.addEventListener("pointercancel", finish);

    let drawn = false;
    function paint() {
      const need = state.selection !== null || state.drag !== null;
      if (need || drawn) {
        const r = canvas.getBoundingClientRect();
        const rr = root.getBoundingClientRect();
        const dpr = window.devicePixelRatio || 1;
        const w = Math.max(1, Math.round(r.width * dpr)), h = Math.max(1, Math.round(r.height * dpr));
        if (overlay.width !== w || overlay.height !== h) { overlay.width = w; overlay.height = h; }
        overlay.style.left = (r.left - rr.left) + "px";
        overlay.style.top = (r.top - rr.top) + "px";
        overlay.style.width = r.width + "px";
        overlay.style.height = r.height + "px";
        const ctx = overlay.getContext("2d");
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.clearRect(0, 0, w, h);
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        if (state.selection !== null) {
          const box = player.nodeBounds().find((b) => b.node === state.selection);
          if (box) {
            ctx.lineWidth = 2;
            ctx.strokeStyle = "#F4A340";
            ctx.strokeRect(box.x - 4, box.y - 4, box.w + 8, box.h + 8);
          }
        }
        if (state.drag) {
          ctx.lineWidth = 1;
          ctx.fillStyle = "rgba(244,163,64,0.12)";
          ctx.strokeStyle = "#F4A340";
          ctx.fillRect(state.drag.x, state.drag.y, state.drag.w, state.drag.h);
          ctx.strokeRect(state.drag.x + 0.5, state.drag.y + 0.5, state.drag.w, state.drag.h);
        }
        drawn = need;
      }
    }
    function loop() {
      paint();
      window.requestAnimationFrame(loop);
    }
    window.requestAnimationFrame(loop);
    state.paint = paint;
    return state;
  }

  async function boot() {
    const player = SynodPlayer.mount("#stage", { autoplay: false, bridge: "synodPlayer", fontBase: window.synodFontBase });
    const canvas = document.querySelector("#stage canvas");
    const entry = (e) => (e ? { seq: e.seq, at: e.at } : null);

    const overlay = installOverlay(player, canvas);

    window.player = player;
    window.stage = {
      info() {
        return {
          duration: player.duration, time: player.time, playing: player.playing, rate: player.rate,
          warnings: Array.from(player.warnings),
        };
      },
      setScene(text, keepTime) {
        player.setScene(text, { keepTime: !!keepTime });
        // Show the poster frame instead of the (usually empty) frame at 0 ms.
        if (!player.playing && player.time === 0) {
          const at = posterTime(text);
          if (at > 0) player.seek(at);
        }
        return window.stage.info();
      },
      play() { player.play(); },
      pause() { player.pause(); },
      seek(at) { player.seek(at); },
      setRate(r) { player.setRate(r); },
      setStopAtPause(b) { player.setStopAtPause(!!b); },
      // nextFact/prevFact exist in the v0.2.0 API; they pause and seek.
      nextFact() { return entry(player.nextFact()); },
      prevFact() { return entry(player.prevFact()); },
      factAt(at) { return entry(player.factAt(at)); },
      timeOfSeq(seq) { return player.timeOfSeq(seq); },
      // Hit testing on the frame last drawn; (x, y) are CSS px of the canvas. See 04-formats "Hit testing".
      hitTest(x, y) { return player.hitTest(x, y); },
      nodeBounds() { return player.nodeBounds(); },
      // Outlines the box of a node on every animation frame; null clears it.
      setSelection(node) {
        overlay.selection = node === null || node === undefined ? null : String(node);
        overlay.paint();   // at once; the animation-frame loop keeps it in step afterwards
      },
      // Renders one frame at `at` into a w x h css-pixel canvas at pixel ratio pr and returns PNG base64.
      // Pauses playback; the stage is redrawn at its own size afterwards.
      async renderFramePNG(at, w, h, pr) {
        player.pause();
        player.resize(w, h, pr);
        player.renderFrame(at);
        const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
        const b64 = await toBase64(blob);
        player.resize(undefined, undefined, window.devicePixelRatio || 1);
        return b64;
      },
    };

    await document.fonts.ready;
    post({ event: "ready" });
  }

  boot().catch((e) => post({ event: "error", fatal: true, message: describe(e) }));
})();
