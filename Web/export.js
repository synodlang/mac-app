// Export host: an offscreen canvas rendered frame by frame; frames leave as PNG base64.
(() => {
  let player = null;
  let canvas = null;

  const toBase64 = (blob) =>
    new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result).split(",", 2)[1]);
      reader.onerror = () => reject(reader.error);
      reader.readAsDataURL(blob);
    });

  window.exporter = {
    async init(sceneText, width, height, pixelRatio) {
      canvas = document.createElement("canvas");
      player = SynodPlayer.createPlayer(canvas, sceneText, {
        autoplay: false, autoResize: false, pixelRatio: pixelRatio, fontBase: window.synodFontBase,
      });
      player.resize(width, height, pixelRatio);
      await player.fontsReady();
      await document.fonts.ready;
      return { duration: player.duration, warnings: Array.from(player.warnings), width: canvas.width, height: canvas.height };
    },
    // Renders each time in order; toBlob snapshots the canvas at call time, so encoding overlaps the next draw.
    async frames(ats) {
      const pending = [];
      for (const at of ats) {
        player.renderFrame(at);
        pending.push(new Promise((resolve) => canvas.toBlob(resolve, "image/png")).then(toBase64));
      }
      return Promise.all(pending);
    },
  };
})();
