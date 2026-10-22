// Shared, deterministic water-surface helpers used by the intro and outro scenes.
(function () {
  const NS = "http://www.w3.org/2000/svg";

  // Seeded PRNG (mulberry32) so every render draws identical ripples.
  function prng(seed) {
    return function () {
      seed |= 0;
      seed = (seed + 0x6d2b79f5) | 0;
      let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  // Horizontal ripple lines, wider spaced and taller toward the bottom (perspective).
  function buildRipples(svg, seed) {
    const rnd = prng(seed);
    const lines = [];
    let y = 120;
    let i = 0;
    while (y < 1920) {
      const depth = y / 1920;
      const amp = 4 + depth * 14 + rnd() * 4;
      const wl = 140 + depth * 260 + rnd() * 80;
      const phase = rnd() * Math.PI * 2;
      let d = "";
      for (let x = 0; x <= 1400; x += 10) {
        const yy = y + Math.sin((x / wl) * Math.PI * 2 + phase) * amp;
        d += (x === 0 ? "M" : "L") + x + " " + yy.toFixed(1) + " ";
      }
      const p = document.createElementNS(NS, "path");
      p.setAttribute("d", d);
      p.setAttribute("fill", "none");
      const warm = depth < 0.18 && rnd() < 0.5;
      p.setAttribute("stroke", warm ? "#f0c8a8" : "#d7e7fb");
      p.setAttribute("stroke-width", (1.2 + depth * 2.6).toFixed(2));
      p.setAttribute("stroke-linecap", "round");
      p.setAttribute("opacity", (0.07 + rnd() * 0.14).toFixed(2));
      svg.appendChild(p);
      lines.push({ el: p, dir: i % 2 === 0 ? -1 : 1, speed: 30 + rnd() * 50 });
      y += 46 + depth * 70 + rnd() * 24;
      i++;
    }
    return lines;
  }

  // Concentric "drop" rings, flattened like rings on a water surface.
  function buildRings(svg, cy, count) {
    const rings = [];
    for (let k = 0; k < count; k++) {
      const e = document.createElementNS(NS, "ellipse");
      e.setAttribute("cx", 540);
      e.setAttribute("cy", cy);
      e.setAttribute("rx", 420);
      e.setAttribute("ry", 120);
      e.setAttribute("fill", "none");
      e.setAttribute("stroke", "#e6f0fc");
      e.setAttribute("stroke-width", 3);
      e.setAttribute("opacity", 0);
      e.style.transformBox = "fill-box";
      e.style.transformOrigin = "50% 50%";
      svg.appendChild(e);
      rings.push(e);
    }
    return rings;
  }

  window.Water = { prng, buildRipples, buildRings };
})();
