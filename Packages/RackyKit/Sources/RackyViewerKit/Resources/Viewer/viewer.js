// Viewer do computador (T3-05, 07 §5): noVNC 1.6.0 vendorizado em ./novnc, servido pelo esquema local do app.
// O Swift comanda por `window.rackyViewer.*` e recebe eventos por `webkit.messageHandlers.viewer`.
import RFB from './novnc/core/rfb.js';

const XK = { Control_L: 0xffe3, Control_R: 0xffe4, Meta_L: 0xffe7, Meta_R: 0xffe8, Super_L: 0xffeb, Super_R: 0xffec, Return: 0xff0d, Tab: 0xff09 };
const post = (message) => { try { window.webkit.messageHandlers.viewer.postMessage(message); } catch (_) { /* fora do app */ } };

let rfb = null;
let inputEnabled = false;
let frames = 0;
let lastFrameAt = 0;
let lastServerAt = 0;
let keepAliveAt = 0;
let statsTimer = null;
let keepAliveTimer = null;
let flipWaiters = [];
let wsMessages = 0;
let wsBytes = 0;
let wsEncodings = new Set();
let window1s = { frames: 0, at: performance.now() };

// Diagnóstico do stream: contagem de mensagens e bytes do WebSocket e erros de JS (ficam no `stats` e em `jserror`).
// O noVNC confere as propriedades do próprio prototype do canal, então o WebSocket nativo não pode ser subclassado.
function countSocket() {
  const ws = rfb && rfb._sock && rfb._sock._websocket;
  if (ws && !ws.__abxCounted) {
    ws.__abxCounted = true;
    ws.addEventListener('message', (e) => { wsMessages += 1; wsBytes += (e.data && e.data.byteLength) || 0; });
  }
}
window.addEventListener('error', (e) => post({ type: 'jserror', detail: String(e.message || e) }));
window.addEventListener('unhandledrejection', (e) => post({ type: 'jserror', detail: 'rejection: ' + String(e.reason && (e.reason.stack || e.reason)) }));

function state(value, detail) { post({ type: 'state', value, detail: detail || null }); }

function countFrame() {
  const now = performance.now();
  lastServerAt = now;
  if (now - keepAliveAt < 150) { return; }  // resposta ao keepalive de 1 pixel, não é quadro novo
  frames += 1;
  lastFrameAt = now;
  const waiters = flipWaiters; flipWaiters = [];
  for (const resolve of waiters) { resolve(now); }
}

function mapKey(keysym) {
  // Cmd -> Ctrl (CS-420); Option segue como Alt.
  if (keysym === XK.Meta_L || keysym === XK.Super_L) { return XK.Control_L; }
  if (keysym === XK.Meta_R || keysym === XK.Super_R) { return XK.Control_R; }
  return keysym;
}

function connect(url) {
  disconnect();
  state('connecting');
  const screen = document.getElementById('screen');
  const mine = new RFB(screen, url, { wsProtocols: ['binary'] });
  rfb = mine;
  rfb.scaleViewport = true;       // letterbox: o canvas escala sem distorcer (CS-424)
  rfb.resizeSession = false;
  rfb.clipViewport = false;
  rfb.focusOnClick = true;
  countSocket();
  setTimeout(countSocket, 0);
  rfb.viewOnly = !inputEnabled;
  rfb.background = '#0a0a0a';
  // Eventos de uma conexão antiga (a página reconectou por cima dela) nunca mexem na atual: sem isso o `disconnect` tardio do
  // RFB velho zerava `rfb` e avisava "disconnected" com a conexão nova viva (a tela mostrava "Disconnected from <computer>").
  mine.addEventListener('connect', () => { if (rfb !== mine) { return; } frames = 0; lastServerAt = performance.now(); state('live'); startTimers(); });
  mine.addEventListener('disconnect', (e) => { if (rfb !== mine) { return; } stopTimers(); state('disconnected', e.detail && e.detail.clean ? 'clean' : 'dirty'); rfb = null; });
  mine.addEventListener('securityfailure', (e) => post({ type: 'error', detail: (e.detail && e.detail.reason) || 'security failure' }));
  rfb.addEventListener('desktopname', (e) => post({ type: 'desktopname', name: e.detail.name }));
  // Contagem de quadros: um `flip()` fora da fila por FramebufferUpdate (rfb.js, `_framebufferUpdate`).
  const display = rfb._display;
  const flip = display.flip.bind(display);
  display.flip = (fromQueue) => { if (fromQueue !== true) { countFrame(); } return flip(fromQueue); };
  // Teclado: Cmd -> Ctrl antes de o noVNC mandar o KeyEvent.
  const original = rfb._keyboard.onkeyevent;
  rfb._keyboard.onkeyevent = (keysym, code, down, ...rest) => original(mapKey(keysym), code, down, ...rest);
  const canvas = rfb._canvas;
  canvas.addEventListener('focus', () => post({ type: 'keyboard', captured: inputEnabled }));
  canvas.addEventListener('blur', () => post({ type: 'keyboard', captured: false }));
  canvas.addEventListener('pointerdown', () => { if (!inputEnabled) { post({ type: 'blocked-input' }); } }, true);
  // F28: sinal de vida do humano (no máximo 1 por segundo) para o app devolver o controle ao agente se ele ficar ocioso.
  let lastInputAt = 0;
  const alive = () => { const now = Date.now(); if (inputEnabled && now - lastInputAt > 1000) { lastInputAt = now; post({ type: 'input' }); } };
  for (const name of ['pointerdown', 'pointermove', 'wheel', 'keydown']) { canvas.addEventListener(name, alive, true); }
}

function disconnect() {
  stopTimers();
  if (rfb) { const old = rfb; rfb = null; try { old.disconnect(); } catch (_) { /* já fechado */ } }
}

function startTimers() {
  stopTimers();
  window1s = { frames, at: performance.now() };
  statsTimer = setInterval(() => {
    const now = performance.now();
    const fps = (frames - window1s.frames) * 1000 / Math.max(1, now - window1s.at);
    window1s = { frames, at: now };
    post({ type: 'stats', fps: Math.round(fps * 10) / 10, frames, silentMs: Math.round(now - lastServerAt), sinceFrameMs: Math.round(now - lastFrameAt), wsMessages, wsBytes, hidden: document.hidden });
  }, 1000);
  // Keepalive: pedido NÃO incremental de 1 pixel. Em tela parada o x11vnc não manda nada, então sem isso "sem quadro há 2 s"
  // não distinguiria tela estática de stream caído (CS-404).
  keepAliveTimer = setInterval(() => {
    if (!rfb || !rfb._sock || performance.now() - lastServerAt < 900) { return; }  // só quando o stream está calado
    keepAliveAt = performance.now();
    RFB.messages.fbUpdateRequest(rfb._sock, false, 0, 0, 1, 1);
  }, 1000);
}

function stopTimers() {
  if (statsTimer) { clearInterval(statsTimer); statsTimer = null; }
  if (keepAliveTimer) { clearInterval(keepAliveTimer); keepAliveTimer = null; }
}

// Atalhos reservados do app (03 §11.6): nunca vão para o computador. Fase de captura, antes do noVNC.
window.addEventListener('keydown', (e) => {
  if (!inputEnabled || !rfb) { return; }
  const meta = e.metaKey, ctrl = e.ctrlKey, alt = e.altKey, shift = e.shiftKey;
  const key = e.key.toLowerCase();
  let reserved = null;
  if (meta && !alt && !ctrl && ['q', 'w', 'h', 'm'].includes(key)) { reserved = 'app'; }
  else if (meta && ctrl && key === 'f') { reserved = 'app'; }
  else if (meta && shift && key === 'r') { reserved = 'handback'; }
  else if (meta && e.key === 'Escape') { reserved = 'release-keyboard'; }
  else if (ctrl && alt && (e.key === 'Control' || e.key === 'Alt')) { reserved = 'release-keyboard'; }
  else if (meta && !alt && !ctrl && !shift && key === 'v') { reserved = 'paste'; }
  if (!reserved) { return; }
  e.stopImmediatePropagation();
  e.preventDefault();
  post({ type: 'reserved', action: reserved, key: e.key });
}, true);

function keysymFor(char) {
  const cp = char.codePointAt(0);
  if (char === '\n' || char === '\r') { return XK.Return; }
  if (char === '\t') { return XK.Tab; }
  return cp < 0x100 ? cp : 0x01000000 + cp;  // Unicode acima de Latin-1 (CS-420)
}

async function typeText(text) {
  if (!rfb || !inputEnabled) { return 0; }
  let count = 0;
  for (const char of Array.from(text).slice(0, 20000)) {
    const keysym = keysymFor(char);
    rfb.sendKey(keysym, null, true);
    rfb.sendKey(keysym, null, false);
    count += 1;
    if (count % 20 === 0) { await new Promise((r) => setTimeout(r, 8)); }
  }
  return count;
}

// Sonda de latência de input: movimentos de mouse sintéticos no canvas, tempo até o próximo quadro. A página do computador
// muda de cor a cada mousemove (a tela só muda por causa do input).
async function probeLatency(count, gapMs) {
  const samples = [];
  const canvas = rfb && rfb._canvas;
  if (!canvas || !inputEnabled) { return samples; }
  const rect = canvas.getBoundingClientRect();
  for (let i = 0; i < count; i += 1) {
    const x = rect.left + rect.width * (0.3 + 0.4 * ((i % 2) ? 0.2 : 0.8));
    const y = rect.top + rect.height * (0.3 + 0.01 * i);
    const t0 = performance.now();
    const next = new Promise((resolve) => { flipWaiters.push(resolve); setTimeout(() => resolve(null), 800); });
    canvas.dispatchEvent(new MouseEvent('mousemove', { clientX: x, clientY: y, bubbles: true }));
    const at = await next;
    flipWaiters = [];
    if (at !== null) { samples.push(Math.round((at - t0) * 10) / 10); }
    await new Promise((r) => setTimeout(r, gapMs));
  }
  return samples;
}

window.rackyViewer = {
  connect,
  disconnect,
  setInputEnabled(enabled) {
    inputEnabled = !!enabled;
    document.body.classList.toggle('blocked', !inputEnabled);
    if (rfb) {
      rfb.viewOnly = !inputEnabled;
      if (!inputEnabled) { rfb.blur(); }
    }
  },
  focus() { if (rfb && inputEnabled) { rfb.focus(); } },
  release() { if (rfb) { rfb.blur(); } post({ type: 'keyboard', captured: false }); },
  typeText,
  probeLatency,
  debug() {
    const q = rfb && rfb._display && rfb._display._renderQ;
    const first = q && q[0];
    return { queue: q ? q.length : -1, first: first ? first.type : null, imgComplete: first && first.img ? first.img.complete : null,
             flushing: rfb ? rfb._flushing : null, state: rfb ? rfb._rfbConnectionState : null, hidden: document.hidden, vis: document.visibilityState,
             fbu: rfb ? rfb._FBU.rects : null, encodings: Array.from(wsEncodings), msgs: wsMessages, bytes: wsBytes };
  },
  // Só para testes: derruba o WebSocket de forma abrupta, como uma queda de rede ou o x11vnc reiniciando.
  dropForTesting() { const ws = rfb && rfb._sock && rfb._sock._websocket; if (ws) { ws.close(); return true; } return false; },
  stats() { return { frames, lastFrameAt, silentMs: Math.round(performance.now() - lastServerAt) }; },
};
post({ type: 'ready' });
