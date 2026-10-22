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

  async function boot() {
    const player = SynodPlayer.mount("#stage", { autoplay: false, bridge: "synodPlayer" });
    const canvas = document.querySelector("#stage canvas");
    const entry = (e) => (e ? { seq: e.seq, at: e.at } : null);

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
