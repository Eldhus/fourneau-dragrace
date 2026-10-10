// The demoscene fire under the logo on the front page (each pixel the heat
// of the one below it, cooling as it rises). Decoration only: the pages
// read the same without it, and it holds still for prefers-reduced-motion.
(() => {
  const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  const fire = document.getElementById("fire");
  if (fire) {
    const width = 160, height = 56; // low resolution, scaled up: the look
    fire.width = width;
    fire.height = height;
    const context = fire.getContext("2d");
    const image = context.createImageData(width, height);
    const heat = new Uint8Array(width * height);
    // Clear, through violet, magenta and orange, to gold: 37 steps of heat.
    const stops = [[23, 11, 38, 0], [110, 40, 200, 150], [255, 95, 180, 210],
      [255, 169, 77, 235], [255, 231, 150, 255]];
    const palette = Array.from({ length: 37 }, (_, i) => {
      const t = (i / 36) * (stops.length - 1);
      const low = stops[Math.floor(t)], high = stops[Math.min(stops.length - 1, Math.ceil(t))];
      const f = t - Math.floor(t);
      return low.map((value, k) => Math.round(value + (high[k] - value) * f));
    });
    for (let x = 0; x < width; x++) heat[(height - 1) * width + x] = 36;
    const step = () => {
      for (let y = 1; y < height; y++) {
        for (let x = 0; x < width; x++) {
          const drift = Math.floor(Math.random() * 3);
          const target = (y - 1) * width + Math.min(width - 1, Math.max(0, x - drift + 1));
          // Cools by 0-2 a row (1 on average): flames die about two thirds
          // of the way up, below the text.
          heat[target] = Math.max(0, heat[y * width + x] - Math.floor(Math.random() * 2.2));
        }
      }
      for (let i = 0; i < heat.length; i++) image.data.set(palette[heat[i]], i * 4);
      context.putImageData(image, 0, 0);
    };
    let frames = 0;
    const draw = () => {
      if (frames++ % 2 === 0) step(); // 30 frames a second is plenty of fire
      if (!still) requestAnimationFrame(draw);
    };
    if (still) for (let i = 0; i < 80; i++) step();
    draw();
  }
})();

// Switching sizes keeps your place. The tabs stay at the top of the screen
// while the results scroll under them (style.css); a click swaps the
// results in place (Datastar), and the workload you were looking at is put
// back where it was, so flipping between sizes compares one chart, not two
// scroll positions. Both sizes list the same workloads in the same order,
// so the nth chart before is the nth after. A section switch (HTTP/1.1,
// HTTP/2 + TLS) lists other workloads: it puts the first chart under the
// tabs instead, if you had scrolled past it.
(() => {
  let kept = null;
  document.addEventListener("datastar-fetch", (event) => {
    const { type, el } = event.detail;
    if (type === "started") {
      const region = el && el.closest && el.closest("#race-classes, #history-classes");
      if (!region) return;
      const below = region.querySelector(".tabbar").getBoundingClientRect().bottom;
      const strips = [...region.querySelectorAll(".strip")];
      let index = strips.findIndex((strip) => strip.getBoundingClientRect().bottom > below);
      let top = index < 0 ? 0 : strips[index].getBoundingClientRect().top;
      if (index > 0 && el.closest("nav.protocol")) {
        index = 0;
        top = below + 14;
      }
      kept = index < 0 ? null : { region: region.id, index, top };
    } else if (type === "finished" && kept) {
      const { region, index, top } = kept;
      kept = null;
      requestAnimationFrame(() => {
        const strip = document.querySelectorAll(`#${region} .strip`)[index];
        if (strip) window.scrollBy(0, strip.getBoundingClientRect().top - top);
      });
    }
  });
})();
