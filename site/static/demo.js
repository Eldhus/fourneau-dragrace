// The fire's colours, the masthead's and the live banner's: clear, through
// violet, magenta and orange, to gold, 37 steps of heat.
const firePalette = (() => {
  const stops = [[23, 11, 38, 0], [110, 40, 200, 150], [255, 95, 180, 210],
    [255, 169, 77, 235], [255, 231, 150, 255]];
  return Array.from({ length: 37 }, (_, i) => {
    const t = (i / 36) * (stops.length - 1);
    const low = stops[Math.floor(t)], high = stops[Math.min(stops.length - 1, Math.ceil(t))];
    const f = t - Math.floor(t);
    return low.map((value, k) => Math.round(value + (high[k] - value) * f));
  });
})();

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
    const palette = firePalette;
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

// A result landing in the live banner: the
// masthead's fire in one burst across the banner. A poof (the fuel at full
// heat and heat thrown up at once), a fast burn, the flame lowering to
// embers, then ash smoke rising away: about three seconds, a confetti
// burst's cadence, a little longer. Each landing patches in a new canvas
// (`canvas.flare`, its id the count of results in), which burns once and
// goes. Nothing burns for prefers-reduced-motion.
(() => {
  const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const total = 3200; // ms, the smoke's last wisp included
  const poof = 140, burning = 900, lowering = 1900, smouldering = 2600;
  const quiet = "inset 0 0 18px rgba(255,169,77,.12), 0 0 14px rgba(255,95,180,.12)";
  const lit = "inset 0 0 40px rgba(255,215,110,.55), 0 0 36px rgba(255,95,180,.6)";

  const burn = (canvas) => {
    if (canvas.dataset.burned === canvas.id) return;
    canvas.dataset.burned = canvas.id;
    if (still) {
      canvas.remove();
      return;
    }
    const banner = canvas.closest(".racer");
    if (banner && banner.animate) {
      banner.animate([{ boxShadow: quiet }, { boxShadow: lit, offset: 0.12 }, { boxShadow: quiet }],
        { duration: 1400, easing: "ease-out" });
    }
    // Pixels six screen pixels wide, as coarse as the masthead's.
    const rect = canvas.getBoundingClientRect();
    const width = Math.max(40, Math.min(240, Math.round(rect.width / 6)));
    const height = Math.max(16, Math.min(80, Math.round(rect.height / 6)));
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext("2d");
    const image = context.createImageData(width, height);
    const heat = new Uint8Array(width * height);
    const base = height - 1;
    let smoke = [];
    const start = performance.now();

    // The fuel along the bottom row at `t` ms.
    const fuel = (t) => {
      if (t < burning) return 36;
      if (t < lowering) {
        const gone = (t - burning) / (lowering - burning);
        return Math.random() < 1 - gone * 0.7 ? 36 - Math.floor(gone * 24) : 0;
      }
      if (t < smouldering) return Math.random() < 0.06 ? 7 + Math.floor(Math.random() * 9) : 0;
      return 0;
    };

    const frame = (now) => {
      const t = now - start;
      for (let x = 0; x < width; x++) heat[base * width + x] = fuel(t);
      if (t < poof) {
        // The poof: sparks of heat thrown up the lower half at once.
        for (let y = Math.floor(height * 0.45); y < base; y++) {
          for (let x = 0; x < width; x++) {
            if (Math.random() < 0.22) {
              heat[y * width + x] = Math.max(heat[y * width + x], 18 + Math.floor(Math.random() * 19));
            }
          }
        }
      }
      // The masthead's rule: each pixel the heat of one below it, cooling
      // as it rises. The canvas is a third of the masthead's height, so it
      // cools about twice as fast (flames die two thirds of the way up);
      // while it burns hard they stand a little taller.
      const cooling = t < burning ? 4.4 : 5.6;
      for (let y = 1; y < height; y++) {
        for (let x = 0; x < width; x++) {
          const drift = Math.floor(Math.random() * 3);
          const target = (y - 1) * width + Math.min(width - 1, Math.max(0, x - drift + 1));
          heat[target] = Math.max(0, heat[y * width + x] - Math.floor(Math.random() * cooling));
        }
      }
      for (let i = 0; i < heat.length; i++) image.data.set(firePalette[heat[i]], i * 4);
      // Ash: grey pixels leaving the dying flame, drifting up and fading.
      if (t > 1500 && t < 2900) {
        for (let i = 0; i < 2; i++) {
          smoke.push({ x: Math.random() * width, y: base - Math.random() * height * 0.25, life: 1 });
        }
      }
      for (const puff of smoke) {
        puff.y -= 0.32;
        puff.x += (Math.random() - 0.5) * 0.7;
        puff.life -= 0.011;
        const px = Math.round(puff.x), py = Math.round(puff.y);
        if (puff.life > 0 && px >= 0 && px < width && py >= 0 && py < height) {
          const k = (py * width + px) * 4, alpha = Math.round(puff.life * 180);
          if (image.data[k + 3] < alpha) image.data.set([196, 182, 212, alpha], k);
        }
      }
      smoke = smoke.filter((puff) => puff.life > 0 && puff.y >= 0);
      context.putImageData(image, 0, 0);
      if (t < total) requestAnimationFrame(frame);
      else canvas.remove();
    };
    requestAnimationFrame(frame);
  };

  // A canvas patched in, or renamed by a morph that kept the element.
  const scan = (node) => {
    if (node.nodeType !== 1) return;
    if (node.matches("canvas.flare")) burn(node);
    node.querySelectorAll("canvas.flare").forEach(burn);
  };
  new MutationObserver((records) => {
    for (const record of records) {
      if (record.type === "attributes") scan(record.target);
      record.addedNodes.forEach(scan);
    }
  }).observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ["id"] });
})();

// Switching tabs keeps your place, across sizes and sections alike. The
// tabs stay at the top of the screen while the results scroll under them
// (style.css); a click morphs the results in place (Datastar), and the
// chart you were looking at is put back where it was on the screen, so
// flipping a tab compares one chart, not two scroll positions. Charts are
// matched by `data-chart` (View.chart_key): Echo 4 KiB over HTTP/1.1 and
// over HTTP/2 + TLS are one chart. One the other side lacks gives way to
// the next one it has. (The section tabs went back to
// the top.) Between sections every chart is where it was already, at every
// width (the same captions, rows and legends: View.as_test, the "n/a"
// rows), so this moves nothing there; between classes on a
// phone, the machines' lines above the charts can differ by a line.
(() => {
  let kept = null;
  document.addEventListener("datastar-fetch", (event) => {
    const { type, el } = event.detail;
    if (type === "started") {
      const region = el && el.closest && el.closest("#race-classes");
      if (!region) return;
      const below = region.querySelector(".tabbar").getBoundingClientRect().bottom;
      const charts = [...region.querySelectorAll("[data-chart]")];
      const index = charts.findIndex((chart) => chart.getBoundingClientRect().bottom > below);
      kept = index < 0 ? null : {
        region: region.id,
        keys: charts.slice(index).map((chart) => chart.dataset.chart),
        top: charts[index].getBoundingClientRect().top,
      };
    } else if (type === "finished" && kept) {
      const { region, keys, top } = kept;
      kept = null;
      requestAnimationFrame(() => {
        const charts = [...document.querySelectorAll(`#${region} [data-chart]`)];
        const chart = keys.map((key) => charts.find((c) => c.dataset.chart === key)).find(Boolean);
        if (chart) window.scrollBy(0, chart.getBoundingClientRect().top - top);
      });
    }
  });
})();

// The time left to push before the daily build takes fourneau's and roux's
// masters (Store.nothing_new says why `data-utc` is 17 minutes early),
// counted in the reader's browser; past it, the next day's.
(() => {
  const countdown = document.querySelector(".racer .countdown");
  if (!countdown) return;
  const [hour, minute] = countdown.dataset.utc.split(":").map(Number);
  const pad = (n) => String(n).padStart(2, "0");
  const tick = () => {
    const now = new Date();
    const deadline = new Date(now);
    deadline.setUTCHours(hour, minute, 0, 0);
    if (deadline <= now) deadline.setUTCDate(deadline.getUTCDate() + 1);
    const left = Math.floor((deadline - now) / 1000);
    const h = Math.floor(left / 3600), m = Math.floor(left / 60) % 60, s = left % 60;
    countdown.textContent = `${h}h ${pad(m)}m ${pad(s)}s left to push`;
  };
  tick();
  setInterval(tick, 1000);
})();
