/**

- Sprig — a character drawn entirely in code.
- 
- Architecture (same pattern as Coucou's notch companion):
- 
    1. Pose – a handful of numbers fully describe the character right now.
- 
    1. Tweens – actions animate those numbers through [target, ms, easing] keyframes.
- 
    1. States – data objects (color, eyes, mouth, badge, behaviour flags, entrance move).
- 
    1. Renderer – every frame, draw the character from the pose. No images.
- 
- Usage:
- import { createSprig } from './sprig.js';
- const sprig = createSprig(document.querySelector('canvas'));
- sprig.setState('working');
- sprig.play('jump');
- 
- No dependencies. Works in any modern browser.
*/

// ---------------------------------------------------------------------------
// Easing
// ---------------------------------------------------------------------------
export const Ease = Object.freeze({
out: t => 1 - Math.pow(1 - t, 3),
inOut: t => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2),
back: t => { const c1 = 1.7, c3 = c1 + 1; return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2); },
in: t => t * t,
lin: t => t,
});

// ---------------------------------------------------------------------------
// Default states (data). `enter(ctx)` runs once when the state is entered.
// ---------------------------------------------------------------------------
export const DEFAULT_STATES = Object.freeze({
idle: {
label: 'Idle', color: '#8CCF9A', eye: 'oval', mouth: 'smile', badge: null,
enter: ctx => ctx.play('blink'),
},
thinking: {
label: 'Thinking', color: '#9B7BF0', eye: 'oval', mouth: 'flat', badge: 'dots',
look: [0.65, -0.7], leaf: -0.25,
enter: ctx => ctx.play('blink'),
},
working: {
label: 'Working', color: '#4F8DF7', eye: 'oval', mouth: 'flat', badge: 'dots',
scans: true, wiggle: true,
enter: ctx => ctx.play('blink'),
},
approval: {
label: 'Waiting for approval', color: '#F0A53A', eye: 'wide', mouth: 'o', badge: 'bang',
bounces: true, leaf: 0.12,
enter: ctx => ctx.anim('oy', [[-0.2, 150, Ease.out], [0, 320, Ease.back]]),
},
question: {
label: 'Asking a question', color: '#2BB3C8', eye: 'oval', mouth: 'flat', badge: 'q',
tilt: 0.17,
enter: ctx => ctx.play('blink'),
},
error: {
label: 'Error', color: '#EC5F5F', eye: 'flat', mouth: 'frown', badge: 'dot',
leaf: 0.75, sweat: true,
enter: ctx => ctx.play('shake'),
},
done: {
label: 'Done', color: '#36C08A', eye: 'happy', mouth: 'grin', badge: 'check', blush: 1,
enter: ctx => {
ctx.play('jump');
if (!ctx.reducedMotion) ctx.anim('leafSpin', [[Math.PI * 2, 800, Ease.inOut]], () => { ctx.pose.leafSpin = 0; });
ctx.later(420, () => ctx.burst('spark', ctx.reducedMotion ? 3 : 7));
},
},
sleeping: {
label: 'Sleeping', color: '#8E9BB0', eye: 'closed', mouth: 'flat', badge: null,
zz: true, breathes: true, leaf: 1.0,
},
dizzy: {
label: 'Dizzy', color: '#EE79B4', eye: 'spiral', mouth: 'wavy', badge: null,
enter: ctx => {
if (!ctx.reducedMotion) ctx.anim('spin', [[Math.PI * 4, 1300, Ease.inOut]], () => { ctx.pose.spin = 0; });
},
},
});

// ---------------------------------------------------------------------------
// Default actions. Each receives the action context (see makeContext below).
// ---------------------------------------------------------------------------
export const DEFAULT_ACTIONS = Object.freeze({
blink(ctx) {
if (ctx.isAnimating('open')) return;
ctx.anim('open', [[0.06, 70, Ease.inOut], [1, 130, Ease.out]]);
},
squish(ctx) {
ctx.anim('sy', [[0.78, 70, Ease.out], [1.1, 130, Ease.out], [1, 170, Ease.inOut]]);
ctx.anim('sx', [[1.16, 70, Ease.out], [0.95, 130, Ease.out], [1, 170, Ease.inOut]]);
},
jump(ctx) {
// anticipation squash → rise → fall (ease-in) → landing squish
ctx.anim('sy', [[0.8, 110, Ease.out], [1.14, 160, Ease.out], [1, 240, Ease.inOut]]);
ctx.anim('sx', [[1.15, 110, Ease.out], [0.92, 160, Ease.out], [1, 240, Ease.inOut]]);
ctx.anim('oy', [[0, 110, Ease.lin], [-0.95, 280, Ease.out], 0, 260, [Ease.in]], () => ctx.play('squish'));
},
shake(ctx) {
ctx.anim('ox', [[0.09, 50, Ease.out], [-0.09, 70, Ease.inOut], [0.06, 70, Ease.inOut], [-0.03, 70, Ease.inOut], [0, 90, Ease.out]]);
},
spin(ctx) {
if (ctx.reducedMotion) { ctx.play('squish'); return; }
ctx.anim('sy', [[0.86, 90, Ease.out], [1, 200, Ease.out]]);
ctx.anim('spin', [[Math.PI * 2, 750, Ease.inOut]], () => { ctx.pose.spin = 0; });
},
hearts(ctx) {
ctx.setEyes('heart', 1600);
ctx.setMouth('grin', 1600);
const rest = ctx.stateConfig.blush || 0;
ctx.anim('blush', [[1, 200, Ease.out], [1, 1200, Ease.lin], [rest, 400, Ease.out]]);
ctx.burst('heart', ctx.reducedMotion ? 2 : 5);
ctx.play('squish');
},
lookAround(ctx) {
ctx.lookAt(-1, -0.1);
ctx.later(600, () => ctx.lookAt(1, -0.1));
ctx.later(1200, () => ctx.lookAt(0, 0.5));
ctx.later(1700, () => { ctx.lookAt(null); ctx.play('blink'); });
},
bigEyes(ctx) {
ctx.anim('es', [[1.45, 180, Ease.back], [1.45, 700, Ease.lin], [1, 300, Ease.inOut]]);
ctx.setMouth('o', 1100);
},
});

const POSE_DEFAULTS = Object.freeze({
yaw: 0, pitch: 0, tilt: 0, open: 1, sx: 1, sy: 1, ox: 0, oy: 0,
spin: 0, leaf: 0, leafSpin: 0, blush: 0, es: 1, badgeS: 0,
});

// ---------------------------------------------------------------------------
// Color helpers
// ---------------------------------------------------------------------------
const hexToRgb = h => {
const s = h.replace('#', '');
const full = s.length === 3 ? s.split('').map(c => c + c).join('') : s;
const n = parseInt(full, 16);
return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
};
const rgba = (c, a = 1) => `rgba(${c[0] | 0},${c[1] | 0},${c[2] | 0},${a})`;
const mixRgb = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------
/**

- @param {HTMLCanvasElement} canvas
- @param {object} [options] see README / sprig.d.ts
*/
export function createSprig(canvas, options = {}) {
if (!(canvas instanceof HTMLCanvasElement)) throw new TypeError('createSprig: first argument must be a <canvas> element');

const prefersReduced = typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
const opts = {
size: 0.19,              // body half-width as a fraction of min(canvas width, height)
ground: 0.76,            // ground line as a fraction of canvas height
initialState: 'idle',
interactive: true,       // click to squish, rapid clicks → dizzy
followPointer: true,     // eyes follow the pointer anywhere on the page
dizzyClicks: 3,
dizzyMs: 2600,
sleepAfter: 0,           // ms of idle before falling asleep (0 = never)
showSprout: true,
ink: '#1E2530',
sproutColors: ['#3E8F57', '#5DBB75', '#4DA866'], // stem, big leaf, small leaf
reducedMotion: prefersReduced,
maxDpr: 2,
autoStart: true,
pauseWhenHidden: true,   // stop drawing when off-screen or tab hidden
...options,
};

const ctx2d = canvas.getContext('2d');
const states = { ...DEFAULT_STATES, ...(options.states || {}) };
const actions = { ...DEFAULT_ACTIONS, ...(options.actions || {}) };

if (!states[opts.initialState]) throw new Error(`createSprig: unknown initialState "${opts.initialState}"`);

// ---- internal state ----
const P = { ...POSE_DEFAULTS };
const tweens = new Map();
const timers = new Set();
const listeners = new Map();
let state = opts.initialState;
let cfg = states[state];
let curColor = hexToRgb(cfg.color);
let badge = null, badgeToken = 0;
let eyeOverride = null, eyeUntil = 0, mouthOverride = null, mouthUntil = 0;
let lookOverride = null;
let externalLook = null;
let particles = [];
let pokes = [], dizzyToken = 0;
let geo = { cx: 0, gy: 0, R: 1, W: 1, H: 1 };
let dpr = 1, cw = 0, ch = 0;
let rafId = 0, running = false, visible = true, destroyed = false;
const t0 = performance.now();
let last = t0, nextBlink = t0 + 2500, nextBounce = 0, nextZ = 0, nextSweat = 0;
let stateSince = t0;
const pointer = { x: 0, y: 0 };
let theme = { shadow: '24,34,46', shadowAlpha: 0.18, z: '#566476' };

// ---- events ----
function emitEvent(type, detail) {
const set = listeners.get(type);
if (set) for (const fn of [...set]) { try { fn(detail); } catch (e) { console.error(e); } }
}

// ---- tweens ----
function anim(key, keys, done) {
if (!(key in P)) throw new Error(`anim: unknown pose key "${key}"`);
tweens.set(key, { keys, i: 0, from: P[key], start: performance.now(), done });
}
function stepTweens(now) {
for (const [k, tw] of tweens) {
const kf = tw.keys[tw.i];
const p = clamp((now - tw.start) / Math.max(1, kf[1]), 0, 1);
P[k] = tw.from + (kf[0] - tw.from) * (kf[2] || Ease.lin)(p);
if (p >= 1) {
tw.from = kf[0]; tw.i++; tw.start = now;
if (tw.i >= tw.keys.length) { tweens.delete(k); if (tw.done) tw.done(); }
}
}
}
function later(ms, fn) {
const id = setTimeout(() => { timers.delete(id); if (!destroyed) fn(); }, ms);
timers.add(id);
return id;
}

// ---- action context handed to actions and state.enter ----
const actionCtx = {
Ease,
pose: P,
anim,
later,
isAnimating: key => tweens.has(key),
play: name => play(name),
burst: (type, count) => burst(type, count),
setEyes(shape, ms) { eyeOverride = shape; eyeUntil = performance.now() + ms; },
setMouth(shape, ms) { mouthOverride = shape; mouthUntil = performance.now() + ms; },
lookAt(x, y) { lookOverride = x == null ? null : [clamp(x, -1, 1), clamp(y ?? 0, -1, 1)]; },
get reducedMotion() { return opts.reducedMotion; },
get state() { return state; },
get stateConfig() { return cfg; },
};

function setBadge(b) {
if (b === badge) return;
const tok = ++badgeToken;
anim('badgeS', [[0, 90, Ease.inOut]], () => {
if (tok !== badgeToken) return;
badge = b;
if (b) anim('badgeS', [[1, 280, Ease.back]]);
});
}

// ---- public: state & actions ----
function setState(name, { force = false } = {}) {
if (!states[name]) { console.warn(`Sprig: unknown state "${name}"`); return false; }
if (name === state && !force) return false;
const from = state;
state = name; cfg = states[name]; stateSince = performance.now();
if (name !== 'dizzy') dizzyToken++; // an explicit change cancels the pending return from dizzy
setBadge(cfg.badge || null);
anim('blush', [[cfg.blush || 0, 300, Ease.out]]);
if (typeof cfg.enter === 'function') cfg.enter(actionCtx);
emitEvent('statechange', { from, to: name, config: cfg });
return true;
}

function play(name) {
const fn = actions[name];
if (!fn) { console.warn(`Sprig: unknown action "${name}"`); return false; }
fn(actionCtx);
emitEvent('action', { name });
return true;
}

function poke() {
if (state === 'dizzy') return;
const now = performance.now();
pokes = pokes.filter(t => now - t < 1500);
pokes.push(now);
play('squish');
emitEvent('poke', { count: pokes.length });
if (pokes.length >= opts.dizzyClicks && states.dizzy) {
pokes = [];
const back = state;
setState('dizzy');
const tok = ++dizzyToken;
emitEvent('dizzy', { returnTo: back });
later(opts.dizzyMs, () => { if (tok === dizzyToken && state === 'dizzy') setState(back); });
} else {
actionCtx.setEyes('flat', 700);
actionCtx.setMouth('frown', 700);
}
}

// ---- particles ----
function burst(type, count = 1) {
const { cx, gy, R, W, H } = geo;
for (let i = 0; i < count; i++) {
const topY = gy + P.oy * R - H * 1.02;
particles.push({
type,
x: cx + (Math.random() - 0.5) * W * (type === 'z' ? 0.4 : 1.4) + (type === 'z' ? W * 0.5 : 0),
y: topY + (type === 'sweat' ? H * 0.25 : 0),
vx: (Math.random() - 0.5) * (type === 'spark' ? 260 : 50) + (type === 'z' ? 20 : 0),
vy: type === 'spark' ? -200 - Math.random() * 160 : (type === 'sweat' ? 40 : -50 - Math.random() * 40),
age: 0,
life: type === 'z' ? 2.4 : 1.4 + Math.random() * 0.5,
rot: Math.random() * Math.PI,
size: R * (type === 'z' ? 0.22 : 0.13) * (0.8 + Math.random() * 0.4),
});
}
}

// ---- sizing & theme ----
function resize() {
dpr = Math.min(opts.maxDpr, window.devicePixelRatio || 1);
cw = canvas.clientWidth; ch = canvas.clientHeight;
canvas.width = Math.max(1, Math.round(cw * dpr));
canvas.height = Math.max(1, Math.round(ch * dpr));
}
function readTheme() {
const dark = typeof matchMedia === 'function' && matchMedia('(prefers-color-scheme: dark)').matches;
const cs = getComputedStyle(canvas);
theme = {
shadow: cs.getPropertyValue('--sprig-shadow-rgb').trim() || (dark ? '0,0,0' : '24,34,46'),
shadowAlpha: parseFloat(cs.getPropertyValue('--sprig-shadow-alpha')) || (dark ? 0.35 : 0.18),
z: cs.getPropertyValue('--sprig-z-color').trim() || (dark ? '#9AA8B6' : '#566476'),
};
}

// ---- pointer ----
function hitBody(px, py) {
const cy = geo.gy + P.oy * geo.R - geo.H / 2;
const dx = (px - geo.cx) / (geo.W * 1.1), dy = (py - cy) / (geo.H * 0.6);
return dx * dx + dy * dy < 1;
}
function onPointerMove(e) {
const r = canvas.getBoundingClientRect();
const px = e.clientX - r.left, py = e.clientY - r.top;
const cy = geo.gy - geo.H / 2;
pointer.x = clamp((px - geo.cx) / (geo.R * 3), -1, 1);
pointer.y = clamp((py - cy) / (geo.R * 3), -1, 1);
if (opts.interactive) canvas.style.cursor = hitBody(px, py) ? 'pointer' : '';
}
function onPointerDown(e) {
if (!opts.interactive) return;
const r = canvas.getBoundingClientRect();
if (hitBody(e.clientX - r.left, e.clientY - r.top)) poke();
}

// ---- drawing ----
function bodyPath(W, H) {
const p = new Path2D();
p.moveTo(-W, -0.26 * H);
p.bezierCurveTo(-W, -0.72 * H, -0.6 * W, -H, 0, -H);
p.bezierCurveTo(0.6 * W, -H, W, -0.72 * H, W, -0.26 * H);
p.bezierCurveTo(W, -0.03 * H, 0.78 * W, 0, 0, 0);
p.bezierCurveTo(-0.78 * W, 0, -W, -0.03 * H, -W, -0.26 * H);
return p;
}
function heartPath(s) {
const p = new Path2D();
p.moveTo(0, s * 0.38);
p.bezierCurveTo(-s * 1.15, -s * 0.35, -s * 0.48, -s * 1.08, 0, -s * 0.45);
p.bezierCurveTo(s * 0.48, -s * 1.08, s * 1.15, -s * 0.35, 0, s * 0.38);
return p;
}

function drawSprout(c, W, H, t) {
const [stem, big, small] = opts.sproutColors;
let a = P.leaf + Math.sin(t * 1.8) * 0.06;
if (cfg.wiggle) a += Math.sin(t * 11) * 0.12;
c.save();
c.translate(0, -H * 0.95);
c.rotate(a);
c.strokeStyle = stem; c.lineWidth = W * 0.06; c.lineCap = 'round';
c.beginPath(); c.moveTo(0, W * 0.1); c.quadraticCurveTo(W * 0.07, -W * 0.22, 0, -W * 0.42); c.stroke();
c.translate(0, -W * 0.42);
c.save();
c.rotate(-0.55 + P.leafSpin);
c.fillStyle = big;
c.beginPath(); c.moveTo(0, 0);
c.quadraticCurveTo(W * 0.36, -W * 0.02, W * 0.44, -W * 0.32);
c.quadraticCurveTo(W * 0.1, -W * 0.32, 0, 0); c.fill();
c.strokeStyle = 'rgba(30,80,45,.35)'; c.lineWidth = W * 0.02;
c.beginPath(); c.moveTo(W * 0.02, -W * 0.02); c.lineTo(W * 0.32, -W * 0.24); c.stroke();
c.restore();
c.save();
c.rotate(0.7 - P.leafSpin * 0.5);
c.fillStyle = small;
c.beginPath(); c.moveTo(0, 0);
c.quadraticCurveTo(-W * 0.24, -W * 0.02, -W * 0.28, -W * 0.22);
c.quadraticCurveTo(-W * 0.06, -W * 0.22, 0, 0); c.fill();
c.restore();
c.restore();
}

function drawEye(c, shape, side, ew, eh, W, t) {
c.fillStyle = opts.ink; c.strokeStyle = opts.ink;
c.lineCap = 'round'; c.lineJoin = 'round';
c.lineWidth = W * 0.055;
if ((shape === 'oval' || shape === 'wide') && P.open < 0.3) shape = 'blinkline';
switch (shape) {
case 'oval':
case 'wide': {
const k = shape === 'wide' ? 1.22 : 1;
c.beginPath(); c.ellipse(0, 0, ew * k, eh * k * Math.max(0.08, P.open), 0, 0, Math.PI * 2); c.fill();
if (P.open > 0.6) {
c.fillStyle = '#FFFFFF';
c.beginPath(); c.arc(ew * 0.35, -eh * 0.4 * k, ew * 0.36 * k, 0, Math.PI * 2); c.fill();
}
break;
}
case 'blinkline':
c.beginPath(); c.moveTo(-ew * 1.1, 0); c.lineTo(ew * 1.1, 0); c.stroke(); break;
case 'flat':
c.beginPath(); c.moveTo(-ew * 1.1, -side * eh * 0.12); c.lineTo(ew * 1.1, side * eh * 0.12); c.stroke(); break;
case 'happy':
c.beginPath(); c.moveTo(-ew * 1.15, eh * 0.25); c.quadraticCurveTo(0, -eh * 1.2, ew * 1.15, eh * 0.25); c.stroke(); break;
case 'closed':
c.beginPath(); c.moveTo(-ew * 1.15, -eh * 0.1); c.quadraticCurveTo(0, eh * 0.8, ew * 1.15, -eh * 0.1); c.stroke(); break;
case 'spiral': {
c.lineWidth = W * 0.035;
c.beginPath();
for (let i = 0; i <= 44; i++) {
const f = i / 44, a = f * Math.PI * 4 + t * 7 * side, r = f * ew * 1.3;
const x = Math.cos(a) * r, y = Math.sin(a) * r;
i ? c.lineTo(x, y) : c.moveTo(x, y);
}
c.stroke();
break;
}
case 'heart': {
const pulse = 1 + Math.sin(t * 10) * 0.08;
c.save(); c.scale(pulse, pulse);
c.fillStyle = '#E8456B'; c.fill(heartPath(ew * 1.45));
c.restore();
break;
}
default: break;
}
}

function drawMouth(c, shape, W, t) {
c.strokeStyle = opts.ink; c.fillStyle = opts.ink;
c.lineWidth = W * 0.045; c.lineCap = 'round';
switch (shape) {
case 'smile':
c.beginPath(); c.moveTo(-W * 0.1, 0); c.quadraticCurveTo(0, W * 0.09, W * 0.1, 0); c.stroke(); break;
case 'grin':
c.beginPath(); c.moveTo(-W * 0.14, -W * 0.01); c.quadraticCurveTo(0, W * 0.22, W * 0.14, -W * 0.01); c.closePath(); c.fill();
c.fillStyle = '#F07C8F';
c.beginPath(); c.ellipse(0, W * 0.075, W * 0.06, W * 0.03, 0, 0, Math.PI * 2); c.fill();
break;
case 'flat':
c.beginPath(); c.moveTo(-W * 0.07, W * 0.02); c.lineTo(W * 0.07, W * 0.02); c.stroke(); break;
case 'frown':
c.beginPath(); c.moveTo(-W * 0.09, W * 0.06); c.quadraticCurveTo(0, -W * 0.04, W * 0.09, W * 0.06); c.stroke(); break;
case 'o':
c.beginPath(); c.ellipse(0, W * 0.03, W * 0.05, W * 0.065, 0, 0, Math.PI * 2); c.fill(); break;
case 'wavy':
c.beginPath();
for (let i = 0; i <= 16; i++) {
const x = -W * 0.12 + (i / 16) * W * 0.24, y = Math.sin((i / 16) * Math.PI * 3 + t * 8) * W * 0.025 + W * 0.02;
i ? c.lineTo(x, y) : c.moveTo(x, y);
}
c.stroke(); break;
default: break;
}
}

function drawBadge(c, bx, by, r, col, t) {
if (!badge || P.badgeS < 0.02) return;
c.save(); c.translate(bx, by); c.scale(P.badgeS, P.badgeS);
c.fillStyle = rgba(col);
c.beginPath(); c.arc(0, 0, r, 0, Math.PI * 2); c.fill();
c.strokeStyle = 'rgba(255,255,255,.9)'; c.lineWidth = r * 0.16; c.stroke();
c.fillStyle = '#FFFFFF'; c.strokeStyle = '#FFFFFF'; c.lineCap = 'round'; c.lineJoin = 'round';
switch (badge) {
case 'dots':
for (let i = -1; i <= 1; i++) {
const lift = Math.max(0, Math.sin(t * 6 - i * 0.9)) * r * 0.22;
c.beginPath(); c.arc(i * r * 0.42, -lift, r * 0.15, 0, Math.PI * 2); c.fill();
}
break;
case 'bang':
c.lineWidth = r * 0.22;
c.beginPath(); c.moveTo(0, -r * 0.5); c.lineTo(0, r * 0.1); c.stroke();
c.beginPath(); c.arc(0, r * 0.45, r * 0.13, 0, Math.PI * 2); c.fill();
break;
case 'q':
c.lineWidth = r * 0.2;
c.beginPath(); c.arc(0, -r * 0.18, r * 0.3, Math.PI * 1.1, Math.PI * 0.35);
c.quadraticCurveTo(0, -r * 0.02, 0, r * 0.15); c.stroke();
c.beginPath(); c.arc(0, r * 0.47, r * 0.12, 0, Math.PI * 2); c.fill();
break;
case 'dot':
c.beginPath(); c.arc(0, 0, r * 0.3, 0, Math.PI * 2); c.fill(); break;
case 'check':
c.lineWidth = r * 0.22;
c.beginPath(); c.moveTo(-r * 0.4, 0); c.lineTo(-r * 0.08, r * 0.32); c.lineTo(r * 0.45, -r * 0.3); c.stroke();
break;
default: break;
}
c.restore();
}

function drawParticles(c, dt) {
particles = particles.filter(p => p.age < p.life);
for (const p of particles) {
p.age += dt;
p.x += p.vx * dt; p.y += p.vy * dt;
if (p.type === 'spark') { p.vy += 520 * dt; p.rot += dt * 6; }
if (p.type === 'sweat') p.vy += 300 * dt;
if (p.type === 'z') p.vx = 22 + Math.sin(p.age * 3) * 25;
c.save(); c.globalAlpha = Math.max(0, 1 - p.age / p.life); c.translate(p.x, p.y);
if (p.type === 'spark') {
c.rotate(p.rot); c.fillStyle = '#F5B83D';
const s = p.size; c.beginPath();
for (let i = 0; i < 8; i++) { const r = i % 2 ? s * 0.35 : s; const ang = (i * Math.PI) / 4; c.lineTo(Math.cos(ang) * r, Math.sin(ang) * r); }
c.closePath(); c.fill();
} else if (p.type === 'heart') {
c.fillStyle = '#E8456B'; c.fill(heartPath(p.size));
} else if (p.type === 'z') {
c.fillStyle = theme.z;
c.font = `600 ${p.size * (0.7 + (p.age / p.life) * 0.6)}px system-ui, sans-serif`;
c.fillText('z', 0, 0);
} else if (p.type === 'sweat') {
c.fillStyle = '#6FB7F2'; const s = p.size * 0.7;
c.beginPath(); c.moveTo(0, -s); c.quadraticCurveTo(s * 0.9, s * 0.2, 0, s * 0.6); c.quadraticCurveTo(-s * 0.9, s * 0.2, 0, -s); c.fill();
}
c.restore();
}
}

function draw(now, dt) {
const c = ctx2d;
const t = (now - t0) / 1000;
c.setTransform(dpr, 0, 0, dpr, 0, 0);
c.clearRect(0, 0, cw, ch);
const R = Math.min(cw, ch) * opts.size;
const W = R, H = R * 1.9;
const cx = cw / 2, gy = ch * opts.ground;
geo = { cx, gy, R, W, H };

```
const br = cfg.breathes ? Math.sin(t * 1.5) * 0.035 : Math.sin(t * 2.2) * 0.012;
const sx = P.sx * (1 - br * 0.6), sy = P.sy * (1 + br);

// ground shadow
const lift = Math.max(0, -P.oy);
c.fillStyle = `rgba(${theme.shadow},${theme.shadowAlpha * (1 - lift * 0.45)})`;
c.beginPath(); c.ellipse(cx + P.ox * R, gy + R * 0.05, R * 1.02 * P.sx * (1 - lift * 0.3), R * 0.15 * (1 - lift * 0.3), 0, 0, Math.PI * 2); c.fill();

c.save();
c.translate(cx + P.ox * R, gy + P.oy * R);           // origin at the base so squash stays grounded
c.rotate(P.tilt + (cfg.wiggle ? Math.sin(t * 13) * 0.015 : 0));
c.translate(0, -H / 2); c.rotate(P.spin); c.translate(0, H / 2); // spin around body centre
c.scale(sx, sy);

if (opts.showSprout) drawSprout(c, W, H, t);

const body = bodyPath(W, H);
const g = c.createLinearGradient(0, -H, 0, 0);
g.addColorStop(0, rgba(mixRgb(curColor, [255, 255, 255], 0.32)));
g.addColorStop(0.55, rgba(curColor));
g.addColorStop(1, rgba(mixRgb(curColor, [0, 0, 0], 0.14)));
c.fillStyle = g; c.fill(body);

c.save();
c.clip(body);
c.fillStyle = 'rgba(255,255,255,.28)';
c.beginPath(); c.ellipse(-W * 0.42, -H * 0.72, W * 0.22, H * 0.12, -0.5, 0, Math.PI * 2); c.fill();

const fx = P.yaw * W * 0.3, fy = P.pitch * H * 0.09;
if (P.blush > 0.01) {
  c.fillStyle = `rgba(255,128,160,${0.7 * P.blush})`;
  for (const side of [-1, 1]) {
    c.beginPath(); c.ellipse(side * W * 0.58 + fx * 0.8, -H * 0.36 + fy, W * 0.15, W * 0.08, 0, 0, Math.PI * 2); c.fill();
  }
}
const eyeShape = eyeOverride && now < eyeUntil ? eyeOverride : cfg.eye;
for (const side of [-1, 1]) {
  const far = Math.max(0, -side * P.yaw);            // the far eye foreshortens when looking sideways
  c.save();
  c.translate(side * W * 0.36 * (1 - far * 0.15) + fx, -H * 0.5 + fy);
  c.scale(1 - far * 0.28, 1);
  drawEye(c, eyeShape, side, W * 0.115 * P.es, W * 0.16 * P.es, W, t);
  c.restore();
}
const mouthShape = mouthOverride && now < mouthUntil ? mouthOverride : cfg.mouth;
c.save(); c.translate(fx * 1.05, -H * 0.31 + fy * 0.8);
drawMouth(c, mouthShape, W, t);
c.restore();
c.restore(); // clip

c.strokeStyle = 'rgba(0,0,0,.08)'; c.lineWidth = W * 0.02; c.stroke(body);
c.restore();

drawBadge(c, cx + P.ox * R + W * 0.92 * sx, gy + P.oy * R - H * 0.92 * sy, R * 0.24, hexToRgb(cfg.color), t);
drawParticles(c, dt);
```

}

// ---- frame loop ----
function frame(now) {
if (!running) return;
const dt = Math.min(0.05, (now - last) / 1000); last = now;
const t = (now - t0) / 1000;
stepTweens(now);

```
let tx = opts.followPointer ? pointer.x : 0, ty = opts.followPointer ? pointer.y : 0;
if (externalLook) [tx, ty] = externalLook;
if (lookOverride) [tx, ty] = lookOverride;
else if (cfg.look) { tx = tx * 0.3 + cfg.look[0] * 0.7; ty = ty * 0.3 + cfg.look[1] * 0.7; }
else if (cfg.scans) { tx = Math.sin(t * 2.8) * 0.7; ty = 0.35; }
if (state === 'sleeping') { tx = 0; ty = 0.25; }
if (state === 'dizzy') { tx = Math.sin(t * 9) * 0.5; ty = 0; }
const k = 1 - Math.exp(-dt * 10);
P.yaw += (tx - P.yaw) * k;
P.pitch += (ty - P.pitch) * k;
const k2 = 1 - Math.exp(-dt * 6);
P.tilt += ((cfg.tilt || 0) - P.tilt) * k2;
P.leaf += ((cfg.leaf || 0) - P.leaf) * k2;
curColor = mixRgb(curColor, hexToRgb(cfg.color), 1 - Math.exp(-dt * 7));

if (now > nextBlink) {
  if (cfg.eye === 'oval' || cfg.eye === 'wide') play('blink');
  nextBlink = now + 2200 + Math.random() * 3200;
}
if (cfg.bounces && now > nextBounce && !tweens.has('oy')) {
  anim('oy', [[-0.14, 160, Ease.out], [0, 300, Ease.back]]);
  nextBounce = now + 1500;
}
if (cfg.zz && now > nextZ) { burst('z', 1); nextZ = now + 1000; }
if (cfg.sweat && now > nextSweat) { burst('sweat', 1); nextSweat = now + 1800; }
if (opts.sleepAfter > 0 && state === 'idle' && states.sleeping && now - stateSince > opts.sleepAfter) setState('sleeping');

draw(now, dt);
emitEvent('frame', P);
rafId = requestAnimationFrame(frame);
```

}

function start() {
if (running || destroyed) return;
running = true;
last = performance.now();
rafId = requestAnimationFrame(frame);
}
function stop() {
running = false;
cancelAnimationFrame(rafId);
}

// ---- wiring ----
const ro = new ResizeObserver(() => { resize(); readTheme(); });
ro.observe(canvas);
resize(); readTheme();

const darkMq = typeof matchMedia === 'function' ? matchMedia('(prefers-color-scheme: dark)') : null;
darkMq?.addEventListener?.('change', readTheme);

window.addEventListener('pointermove', onPointerMove, { passive: true });
canvas.addEventListener('pointerdown', onPointerDown);

let io = null;
function onVisibility() {
if (!opts.pauseWhenHidden) return;
const shouldRun = visible && document.visibilityState === 'visible';
if (shouldRun) start(); else stop();
}
if (opts.pauseWhenHidden && 'IntersectionObserver' in window) {
io = new IntersectionObserver(entries => { visible = entries[0].isIntersecting; onVisibility(); });
io.observe(canvas);
}
document.addEventListener('visibilitychange', onVisibility);

// initial state (apply config without firing enter animations twice)
setBadge(cfg.badge || null);
P.blush = cfg.blush || 0;

// ---- public API ----
const api = {
get state() { return state; },
get states() { return { ...states }; },
get actions() { return Object.keys(actions); },
setState,
play,
poke,
burst,
/** Point the eyes at a normalised direction (-1..1, -1..1), or null to follow the pointer again. */
lookAt(x, y) { externalLook = x == null ? null : [clamp(x, -1, 1), clamp(y ?? 0, -1, 1)]; },
getPose() { return { ...P }; },
registerState(name, config) {
if (!config || typeof config.color !== 'string') throw new Error('registerState: config.color (hex) is required');
states[name] = { label: name, eye: 'oval', mouth: 'smile', badge: null, ...config };
if (name === state) cfg = states[name];
},
registerAction(name, fn) {
if (typeof fn !== 'function') throw new Error('registerAction: fn must be a function');
actions[name] = fn;
},
on(type, fn) {
if (!listeners.has(type)) listeners.set(type, new Set());
listeners.get(type).add(fn);
return () => listeners.get(type)?.delete(fn);
},
setOptions(patch) { Object.assign(opts, patch); resize(); readTheme(); },
resize,
start,
stop,
destroy() {
if (destroyed) return;
stop();
destroyed = true;
ro.disconnect();
io?.disconnect();
darkMq?.removeEventListener?.('change', readTheme);
window.removeEventListener('pointermove', onPointerMove);
canvas.removeEventListener('pointerdown', onPointerDown);
document.removeEventListener('visibilitychange', onVisibility);
for (const id of timers) clearTimeout(id);
timers.clear(); tweens.clear(); listeners.clear(); particles = [];
ctx2d.setTransform(1, 0, 0, 1, 0, 0);
ctx2d.clearRect(0, 0, canvas.width, canvas.height);
canvas.style.cursor = '';
},
};

if (opts.autoStart) start();
return api;
}

export default createSprig;
