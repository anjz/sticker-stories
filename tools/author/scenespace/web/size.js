// The sizing page: stickers on the scene at their depth, to size against
// each other. A size is a sticker's drawn height at depth 1 (art heights);
// standing at depth z it is size / z tall, never below the floor
// (scenespace/space.go). Drawn back to front with the scene's layers, as
// the app will.

const data = await (await fetch('/api/scene')).json();
const S = data.space, A = data.aspect, eye = S.horizon - S.ground;
document.getElementById('title').textContent = `Sizes — ${data.pack}`;

// Until a line-up is saved, every sticker starts at its size class's
// default (today's medium sticker at depth 2 is drawn as tall as now).
const classScale = { huge: 1.8, big: 1.3, medium: 1, small: 0.75, tiny: 0.55 };
const saved = (S.lineup || []).length > 0;
const sizes = {};
for (const st of data.stickers) {
  sizes[st.id] = (saved && S.sizes && S.sizes[st.id]) || +(0.32 * (classScale[st.size] || 1)).toFixed(3);
}
let floor = S.floor ?? 0.04;
let lineup = (S.lineup || []).map(l => ({ sticker: l.sticker, at: [...l.at], flip: !!l.flip }));
let selected = null;   // a lineup entry
let dirty = false;
const ui = { ghosts: true, layers: true, wide: false };

// MARK: Images

const load = src => new Promise((ok, fail) => { const i = new Image(); i.onload = () => ok(i); i.onerror = fail; i.src = src; });
const art = {};
async function plane(name) {
  const p = data.planes[name], src = ui.wide ? p.wide : p.base;
  return art[src] || (art[src] = await load(src));
}
const stickers = {};
await Promise.all(data.stickers.map(async st => {
  const img = await load('/pack/' + st.image);
  const c = document.createElement('canvas');
  c.width = img.width; c.height = img.height;
  const g = c.getContext('2d');
  g.drawImage(img, 0, 0);
  const a = g.getImageData(0, 0, c.width, c.height).data;
  let x0 = c.width, y0 = c.height, x1 = 0, y1 = 0;
  for (let y = 0; y < c.height; y += 2) for (let x = 0; x < c.width; x += 2) {
    if (a[(y * c.width + x) * 4 + 3] > 40) { x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); }
  }
  stickers[st.id] = { ...st, img, box: { x: x0, y: y0, w: x1 - x0 + 2, h: y1 - y0 + 2 } };
}));

// MARK: Space

const depthAt = v => v < S.horizon - 0.01 ? Math.min(Math.max(eye / (S.horizon - v), 0.5), S.back) : S.back;
const groundAt = z => S.horizon - eye / z;
const drawnHeight = (size, z) => Math.max(size / z, Math.min(floor, size));
const layers = () => S.layers.map(l => ({ ...l, plane: l.art || 'foreground', ...(ui.wide && l.wide ? l.wide : {}) }));

const canvas = document.getElementById('c'), ctx = canvas.getContext('2d');
function rect() {
  const k = ui.wide ? data.wide : 1, ar = A * k;
  const W = canvas.clientWidth, H = canvas.clientHeight;
  const w = Math.min(W, H * ar), h = w / ar;
  return { x: (W - w) / 2, y: (H - h) / 2, w, h, k };
}
const toScreen = (r, [u, v]) => ({ x: r.x + (u / r.k + (r.k - 1) / (2 * r.k)) * r.w, y: r.y + (1 - v) * r.h });
const fromScreen = (r, x, y) => [((x - r.x) / r.w - (r.k - 1) / (2 * r.k)) * r.k, 1 - (y - r.y) / r.h];

// MARK: Drawing

let hits = [];   // [{entry, x, y, w, h}], nearest first

function stickerRect(r, entry, at) {
  const st = stickers[entry.sticker], z = depthAt(at[1]);
  const h = drawnHeight(sizes[entry.sticker], z) * r.h, w = h * st.box.w / st.box.h;
  const p = toScreen(r, at);
  return { x: p.x - w / 2, y: p.y - h, w, h, feet: p, z };
}

function drawSticker(r, entry, at, alpha) {
  const st = stickers[entry.sticker], b = stickerRect(r, entry, at);
  ctx.save();
  ctx.globalAlpha = alpha;
  ctx.fillStyle = 'rgba(0,0,0,0.22)';
  ctx.beginPath();
  ctx.ellipse(b.feet.x, b.feet.y - b.h * 0.01, b.w * 0.42, b.w * 0.07, 0, 0, Math.PI * 2);
  ctx.fill();
  if (entry.flip) { ctx.translate(b.feet.x, 0); ctx.scale(-1, 1); ctx.translate(-b.feet.x, 0); }
  ctx.drawImage(st.img, st.box.x, st.box.y, st.box.w, st.box.h, b.x, b.y, b.w, b.h);
  ctx.restore();
  return b;
}

function polygon(r, pts) {
  pts.forEach((q, i) => { const p = toScreen(r, q); i ? ctx.lineTo(p.x, p.y) : ctx.moveTo(p.x, p.y); });
  ctx.closePath();
}

function drawLayer(r, l, all, img) {
  ctx.save();
  ctx.beginPath();
  if (l.mask) {
    polygon(r, l.mask);
    ctx.clip();
  } else {
    ctx.rect(r.x, r.y, r.w, r.h);
    all.filter(o => o.mask && o.plane === l.plane).forEach(o => polygon(r, o.mask));
    ctx.clip('evenodd');
  }
  ctx.drawImage(img, r.x, r.y, r.w, r.h);
  ctx.restore();
}

async function draw() {
  const dpr = window.devicePixelRatio || 1;
  canvas.width = canvas.clientWidth * dpr;
  canvas.height = canvas.clientHeight * dpr;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.fillStyle = '#2b2f36';
  ctx.fillRect(0, 0, canvas.clientWidth, canvas.clientHeight);
  const r = rect();
  ctx.drawImage(await plane('background'), r.x, r.y, r.w, r.h);

  const all = layers();
  const images = {};
  for (const l of all) images[l.plane] = await plane(l.plane);
  const items = [];
  for (const l of all) items.push({ z: l.depth, layer: true, draw: () => (ui.layers || l.plane === 'foreground') && drawLayer(r, l, all, images[l.plane]) });
  hits = [];
  for (const e of lineup) {
    items.push({ z: depthAt(e.at[1]), draw: () => hits.push({ entry: e, ...drawSticker(r, e, e.at, 1) }) });
  }
  if (selected && ui.ghosts) {
    for (const z of [S.stand.near, S.stand.far]) {
      items.push({ z, draw: () => drawSticker(r, selected, [selected.at[0], groundAt(z)], 0.4) });
    }
  }
  // Far to near; at the same depth the layer first, so what stands at a
  // tree is in front of it.
  items.sort((a, b) => b.z - a.z || (b.layer ? 1 : 0) - (a.layer ? 1 : 0));
  items.forEach(i => i.draw());
  hits.reverse();

  // Where stickers may stand.
  ctx.save();
  ctx.setLineDash([6, 6]);
  ctx.strokeStyle = 'rgba(255, 211, 77, 0.55)';
  for (const z of [S.stand.near, S.stand.far]) {
    const y = toScreen(r, [0, groundAt(z)]).y;
    ctx.beginPath(); ctx.moveTo(r.x, y); ctx.lineTo(r.x + r.w, y); ctx.stroke();
  }
  ctx.restore();
  const h = selected && hits.find(x => x.entry === selected);
  if (h) {
    ctx.strokeStyle = '#4b9bff';
    ctx.lineWidth = 2;
    ctx.strokeRect(h.x - 3, h.y - 3, h.w + 6, h.h + 6);
  }
  panel();
}

// MARK: Panel

const pct = x => (x * 100).toFixed(1) + '%';
function panel() {
  const sel = document.getElementById('sel');
  const sizeIn = document.getElementById('size'), sizeNum = document.getElementById('sizeNum');
  document.getElementById('floor').value = floor;
  document.getElementById('floorNum').textContent = pct(floor);
  if (!selected) {
    sel.textContent = 'Nothing selected.';
    sizeIn.disabled = sizeNum.disabled = true;
  } else {
    const id = selected.sticker, s = sizes[id], z = depthAt(selected.at[1]);
    const front = drawnHeight(s, S.stand.near), back = drawnHeight(s, S.stand.far);
    sel.innerHTML = `<b>${id}</b> (${stickers[id].size || 'no class'}) · size <b>${s.toFixed(3)}</b><br>`
      + `here: depth ${z.toFixed(2)}, ${pct(drawnHeight(s, z))} of the art's height<br>`
      + `front ${pct(front)} · back ${pct(back)}<br>`
      + `pinch: ${pct(back)} – ${pct(front)}, starts at ${pct((front + back) / 2)}`;
    sizeIn.disabled = sizeNum.disabled = false;
    sizeIn.value = Math.log(s);
    if (document.activeElement !== sizeNum) sizeNum.value = s.toFixed(3);
  }
  for (const b of document.querySelectorAll('#tray button')) {
    b.classList.toggle('placed', lineup.some(e => e.sticker === b.dataset.id));
    b.classList.toggle('sel', !!selected && selected.sticker === b.dataset.id);
  }
  const save = document.getElementById('save');
  save.classList.toggle('dirty', dirty);
  save.textContent = dirty ? 'Save *' : 'Save';
  for (const k of ['ghosts', 'layers', 'wide']) document.getElementById(k).classList.toggle('on', ui[k]);
}

function changed() { dirty = true; document.getElementById('status').textContent = ''; draw(); }
function setSize(id, s) { sizes[id] = Math.min(Math.max(s, 0.01), 3); changed(); }

// MARK: Input

const tray = document.getElementById('tray');
for (const st of data.stickers) {
  const b = document.createElement('button');
  b.dataset.id = st.id;
  const c = document.createElement('canvas');
  c.width = c.height = 56;
  const s = stickers[st.id], k = 52 / Math.max(s.box.w, s.box.h);
  c.getContext('2d').drawImage(s.img, s.box.x, s.box.y, s.box.w, s.box.h, (56 - s.box.w * k) / 2, (56 - s.box.h * k) / 2, s.box.w * k, s.box.h * k);
  b.append(c, st.id);
  b.onclick = () => {
    selected = lineup.find(e => e.sticker === st.id);
    if (!selected) {
      selected = { sticker: st.id, at: [0.5 + (Math.random() - 0.5) * 0.2, 0.28], flip: false };
      lineup.push(selected);
      dirty = true;
    }
    draw();
  };
  tray.append(b);
}

document.getElementById('all').onclick = () => {
  const missing = data.stickers.filter(st => !lineup.some(e => e.sticker === st.id));
  const rows = [0.22, 0.33, 0.43], per = Math.ceil(missing.length / rows.length);
  missing.forEach((st, i) => {
    const row = Math.floor(i / per), col = i % per;
    lineup.push({ sticker: st.id, at: [0.08 + 0.84 * (col + 0.5) / per, rows[row]], flip: false });
  });
  if (missing.length) changed();
};

let drag = null;
canvas.addEventListener('pointerdown', e => {
  const r = rect(), x = e.offsetX, y = e.offsetY;
  const h = hits.find(b => x >= b.x && x <= b.x + b.w && y >= b.y && y <= b.y + b.h);
  selected = h ? h.entry : null;
  if (h) {
    const feet = toScreen(r, h.entry.at);
    drag = { dx: feet.x - x, dy: feet.y - y };
    canvas.setPointerCapture(e.pointerId);
  }
  draw();
});
canvas.addEventListener('pointermove', e => {
  if (!drag || !selected) return;
  selected.at = fromScreen(rect(), e.offsetX + drag.dx, e.offsetY + drag.dy);
  changed();
});
canvas.addEventListener('pointerup', () => { drag = null; });
canvas.addEventListener('wheel', e => {
  if (!selected) return;
  e.preventDefault();
  setSize(selected.sticker, sizes[selected.sticker] * Math.exp(-e.deltaY * 0.0015));
}, { passive: false });
window.addEventListener('keydown', e => {
  if (e.target.tagName === 'INPUT' || !selected) return;
  const id = selected.sticker;
  if (e.key === '+' || e.key === '=') setSize(id, sizes[id] * 1.03);
  else if (e.key === '-') setSize(id, sizes[id] / 1.03);
  else if (e.key === 'f' || e.key === 'F') { selected.flip = !selected.flip; changed(); }
  else if (e.key === 'Delete' || e.key === 'Backspace') { lineup = lineup.filter(x => x !== selected); selected = null; changed(); }
  else if (e.key.startsWith('Arrow')) {
    const d = e.shiftKey ? 0.01 : 0.002;
    selected.at[0] += e.key === 'ArrowLeft' ? -d : e.key === 'ArrowRight' ? d : 0;
    selected.at[1] += e.key === 'ArrowDown' ? -d : e.key === 'ArrowUp' ? d : 0;
    changed();
  } else return;
  e.preventDefault();
});
document.getElementById('size').oninput = e => selected && setSize(selected.sticker, Math.exp(+e.target.value));
document.getElementById('sizeNum').onchange = e => selected && +e.target.value > 0 && setSize(selected.sticker, +e.target.value);
document.getElementById('floor').oninput = e => { floor = +e.target.value; changed(); };
for (const k of ['ghosts', 'layers', 'wide']) document.getElementById(k).onclick = () => { ui[k] = !ui[k]; draw(); };

document.getElementById('save').onclick = async () => {
  const status = document.getElementById('status');
  const res = await fetch('/api/sizes', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sizes, floor, lineup }),
  });
  if (res.ok) { dirty = false; status.style.color = '#8c8'; status.textContent = 'Saved to space.json'; }
  else { status.style.color = '#e88'; status.textContent = await res.text(); }
  panel();
};
// ?all=1&sel=fox starts that way (for pictures of the page).
const params = new URLSearchParams(location.search);
if (params.get('all') === '1') document.getElementById('all').onclick();
if (params.get('wide') === '1') ui.wide = true;
if (params.has('sel')) selected = lineup.find(e => e.sticker === params.get('sel')) || null;
window.addEventListener('beforeunload', e => { if (dirty) e.preventDefault(); });
window.addEventListener('resize', draw);
await draw();
