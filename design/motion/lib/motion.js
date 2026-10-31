// design/motion/lib/motion.js
// Matematica de motion dos prototipos HTML, identica a de 04 §9.4 (paridade com o Swift).
//   - Bezier: UnitBezier do WebKit (Newton-Raphson + bissecao de fallback, eps = 1e-6),
//     mesma familia de CAMediaTimingFunction / Animation.timingCurve.
//   - Spring: oscilador amortecido com os parametros de .spring(response:dampingFraction:),
//     w0 = 2pi/response, zeta = dampingFraction, velocidade inicial 0.
// Tudo e funcao pura do tempo. Sem Date.now, sem Math.random, sem transicoes CSS.
// Requer window.MOTION (lib/tokens.js, gerado de tokens.json). Funciona tambem em Node.
(function (root) {
  'use strict';
  const EPS = 1e-6;

  function UnitBezier(x1, y1, x2, y2) {
    const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
    const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
    const sx = (t) => ((ax * t + bx) * t + cx) * t;
    const sy = (t) => ((ay * t + by) * t + cy) * t;
    const sdx = (t) => (3 * ax * t + 2 * bx) * t + cx;
    function solveX(x) {
      let t = x, e, d;
      for (let i = 0; i < 8; i++) {                   // Newton-Raphson
        e = sx(t) - x;
        if (Math.abs(e) < EPS) return t;
        d = sdx(t);
        if (Math.abs(d) < EPS) break;
        t -= e / d;
      }
      let lo = 0, hi = 1; t = x;                      // bissecao
      if (t < lo) return lo;
      if (t > hi) return hi;
      while (lo < hi) {
        e = sx(t);
        if (Math.abs(e - x) < EPS) return t;
        if (x > e) lo = t; else hi = t;
        t = (hi - lo) * 0.5 + lo;
      }
      return t;
    }
    return (x) => (x <= 0 ? 0 : x >= 1 ? 1 : sy(solveX(x)));
  }

  // SpringSpec.value(at:), x(t) = 1 - e^(-z w0 t)(cos wd t + (z w0 / wd) sin wd t)
  function springValue(response, zeta, t) {
    if (t <= 0) return 0;
    const w0 = 2 * Math.PI / response;
    if (zeta >= 1) return 1 - Math.exp(-w0 * t) * (1 + w0 * t);
    const wd = w0 * Math.sqrt(1 - zeta * zeta);
    return 1 - Math.exp(-zeta * w0 * t) * (Math.cos(wd * t) + (zeta * w0 / wd) * Math.sin(wd * t));
  }

  const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
  const lerp = (a, b, p) => a + (b - a) * p;
  const seg = (t, a, b) => clamp((t - a) / (b - a));

  const M = root.MOTION || (typeof require !== 'undefined' ? require('./tokens.js') : null);
  const cache = {};
  function bez(name) {
    if (!cache[name]) {
      const e = M.easing[name];
      if (!e) throw new Error('easing desconhecida: ' + name);
      cache[name] = UnitBezier(e[0], e[1], e[2], e[3]);
    }
    return cache[name];
  }
  // progresso 0..1 de uma curva por token; dur = segundos ou nome de token de duracao
  function curve(name, dur, t, t0 = 0) {
    const d = typeof dur === 'string' ? M.duration[dur] : dur;
    return bez(name)(clamp((t - t0) / d));
  }
  // spring por token: 0 -> ~1 (pode passar de 1)
  function spring(name, t, t0 = 0) {
    const s = M.spring[name];
    if (!s) throw new Error('spring desconhecida: ' + name);
    return springValue(s.response, s.dampingFraction, t - t0);
  }
  const dur = (n) => M.duration[n];
  const dist = (n) => M.distance[n];
  const scale = (n) => M.scale[n];
  const opac = (n) => M.opacity[n];

  // Spinner: 12 passos discretos de 30 graus, 1 volta/s, fase global (t absoluto)
  function spinnerAngle(t) {
    const L = M.loop.spinner;
    return (Math.floor(t * L.steps / L.period) % L.steps) * (360 / L.steps);
  }
  // Respiracao do halo: ida e volta (inOut), periodo loop.halo.period; devolve 0..1
  function halo(t, phase = 0) {
    const P = M.loop.halo.period, u = ((((t + phase) % P) + P) % P) / P;
    return bez('inOut')(u < 0.5 ? u * 2 : (1 - u) * 2);
  }
  // Keyframes do tokens.json, ex.: keyframes('clickRing', t, 'scale') quando o valor e [de, para]
  function keyframes(name, t, key) {
    const k = M.keyframes[name], pts = k[key], p = clamp(t / k.duration);
    if (typeof pts[0] === 'number') return lerp(pts[0], pts[1], bez(k.easing)(p));
    for (let i = 0; i < pts.length - 1; i++) {
      if (p <= pts[i + 1][0]) {
        const q = (p - pts[i][0]) / (pts[i + 1][0] - pts[i][0]);
        return lerp(pts[i][1], pts[i + 1][1], bez(k.easing)(q));
      }
    }
    return pts[pts.length - 1][1];
  }

  const api = { UnitBezier, springValue, clamp, lerp, seg, curve, spring, bez, dur, dist, scale, opac, spinnerAngle, halo, keyframes, tokens: M };
  root.Motion = api;
  if (typeof module !== 'undefined') module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
