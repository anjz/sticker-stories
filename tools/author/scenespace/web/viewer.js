// The scene with depth (space.json), drawn in 3D: the painted art projected
// from the camera onto a ground, a backdrop and the foreground's layers, so
// the camera view is the picture itself and turning around shows where
// everything is. Coordinates: x right, y up, depth z along −z, in art
// heights at depth 1 (scenespace/space.go).
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

const data = await (await fetch('/api/scene')).json();
const S = data.space;
const A = data.aspect;                     // base art width / height
const eye = S.horizon - S.ground;          // the eye's height above the ground
const stickerByID = Object.fromEntries(data.stickers.map(s => [s.id, s]));
document.getElementById('title').textContent = `scenespace — ${data.pack}`;
if (data.problems.length) {
  const box = document.getElementById('problems');
  box.style.display = 'block';
  box.querySelector('ul').innerHTML = data.problems.map(p => `<li>${p}</li>`).join('');
}

const ui = { pov: true, wide: false, art: true, places: false, layers: false, cast: true, walk: true };
// ?pov=0&places=1&t=4 … starts that way (for pictures of the page).
const params = new URLSearchParams(location.search);
for (const key of Object.keys(ui)) if (params.has(key)) ui[key] = params.get(key) === '1';

// MARK: Space

const groundDepth = v => eye / (S.horizon - v);
// The spot on the ground seen at art point [u, v].
const onGround = ([u, v], y = 0) => { const z = groundDepth(v); return new THREE.Vector3((u - 0.5) * A * z, y, -z); };
// The point at depth z seen at art point [u, v].
const atDepth = ([u, v], z) => new THREE.Vector3((u - 0.5) * A * z, eye + (v - S.horizon) * z, -z);
const drawnHeight = (size, z) => Math.max(size / z, Math.min(S.floor || 0, size));

// A rendition: the art the app draws (base, or wide on phones) — where its
// texture sits over the base frame and how its foreground is cut.
function rendition(wide) {
  const k = wide ? data.wide : 1;
  return {
    wide, k,
    texScale: 1 / k, texOffset: (k - 1) / (2 * k),   // base u → texture u
    halfWidth: (A / 2) * k,                          // half the view's width at depth 1
    image: plane => wide ? data.planes[plane].wide : data.planes[plane].base,
    layers: S.layers.map(l => ({ ...l, plane: l.art || 'foreground', ...(wide && l.wide ? l.wide : {}) })),
    lines: place => (wide && place.wideLines) || place.lines || [],
  };
}

// MARK: Renderer and cameras

const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
renderer.outputColorSpace = THREE.LinearSRGBColorSpace;  // textures pass through as painted
renderer.setPixelRatio(window.devicePixelRatio);
renderer.setScissorTest(true);
document.getElementById('view').appendChild(renderer.domElement);
const world = new THREE.Scene();
const clearColor = new THREE.Color(0x2b2f36);

// The camera the art was painted from: at the eye, looking level, its
// picture exactly the art (the horizon need not be the middle).
const povCamera = new THREE.PerspectiveCamera();
povCamera.position.set(0, eye, 0);
povCamera.lookAt(0, eye, -1);
function fitPOV(r) {
  const n = 0.02;
  povCamera.projectionMatrix.makePerspective(-n * r.halfWidth, n * r.halfWidth, n * (1 - S.horizon), -n * S.horizon, n, 100);
  povCamera.projectionMatrixInverse.copy(povCamera.projectionMatrix).invert();
}

const orbitCamera = new THREE.PerspectiveCamera(45, 1, 0.02, 200);
orbitCamera.position.set(...(params.get('from') || '5.5,4.5,2.5').split(',').map(Number));
const controls = new OrbitControls(orbitCamera, renderer.domElement);
controls.target.set(0, 0.3, -S.back * 0.45);
controls.enableDamping = true;
controls.update();

// MARK: Materials

const textures = {};
const loader = new THREE.TextureLoader();
async function texture(path) {
  if (!textures[path]) {
    textures[path] = await loader.loadAsync(path);
    textures[path].anisotropy = renderer.capabilities.getMaxAnisotropy();
  }
  return textures[path];
}

// The art projected from the eye onto whatever surface it lands on.
function projected(r, map, { mask = null, cutout = false, tint = null } = {}) {
  return new THREE.ShaderMaterial({
    uniforms: {
      map: { value: map }, mask: { value: mask }, useMask: { value: mask ? 1 : 0 },
      horizon: { value: S.horizon }, eye: { value: eye }, A: { value: A },
      texScale: { value: r.texScale }, texOffset: { value: r.texOffset },
      cutout: { value: cutout ? 1 : 0 }, showArt: { value: 1 },
      tint: { value: tint || new THREE.Vector4(0, 0, 0, 0) },
    },
    vertexShader: `
      varying vec3 wp;
      void main() {
        vec4 w = modelMatrix * vec4(position, 1.0);
        wp = w.xyz;
        gl_Position = projectionMatrix * viewMatrix * w;
      }`,
    fragmentShader: `
      uniform sampler2D map; uniform sampler2D mask;
      uniform float useMask, horizon, eye, A, texScale, texOffset, cutout, showArt;
      uniform vec4 tint;
      varying vec3 wp;
      void main() {
        float z = -wp.z;
        if (z < 0.05) discard;
        vec2 t = vec2((0.5 + wp.x / (A * z)) * texScale + texOffset, horizon + (wp.y - eye) / z);
        if (t.x < 0.0 || t.x > 1.0 || t.y < 0.0 || t.y > 1.0) {
          if (cutout > 0.5) discard;
          gl_FragColor = vec4(0.36, 0.38, 0.42, 1.0);
          return;
        }
        vec4 c = texture2D(map, t);
        if (useMask > 0.5) c.a *= texture2D(mask, t).r;
        if (cutout > 0.5 && c.a < 0.5) discard;
        vec3 rgb = showArt > 0.5 ? c.rgb : vec3(0.55 + 0.1 * c.g);
        gl_FragColor = vec4(mix(rgb, tint.rgb, tint.a), 1.0);
      }`,
    side: THREE.DoubleSide,
  });
}

// A layer's piece of its plane, as a texture in the rendition's texture
// space: its mask, or for the rest everything no other mask of the plane
// takes.
function maskTexture(r, layer) {
  const W = 1024, H = Math.round(W / (A * r.k));
  const c = document.createElement('canvas');
  c.width = W; c.height = H;
  const g = c.getContext('2d');
  const poly = pts => {
    g.beginPath();
    pts.forEach(([u, v], i) => {
      const x = (u * r.texScale + r.texOffset) * W, y = (1 - v) * H;
      i ? g.lineTo(x, y) : g.moveTo(x, y);
    });
    g.closePath();
    g.fill();
  };
  if (layer.mask) {
    g.fillStyle = '#000'; g.fillRect(0, 0, W, H);
    g.fillStyle = '#fff'; poly(layer.mask);
  } else {
    g.fillStyle = '#fff'; g.fillRect(0, 0, W, H);
    g.fillStyle = '#000';
    r.layers.filter(l => l.mask && l.plane === layer.plane).forEach(l => poly(l.mask));
  }
  return new THREE.CanvasTexture(c);
}

const layerTints = [0xe0503c, 0x3cb4e0, 0xe0c03c, 0x9c3ce0, 0x3ce07a];

// MARK: Building the scene

let built = null;   // { r, artMaterials, groups, cast }

async function build() {
  if (built) world.remove(built.root);
  const r = rendition(ui.wide);
  fitPOV(r);
  const root = new THREE.Group();
  const art = new THREE.Group(), places = new THREE.Group(), cast = new THREE.Group();
  root.add(art, places, cast);
  const artMaterials = [];
  const bg = await texture(r.image('background'));
  const far = S.back, width = 2 * r.halfWidth * far * 1.15;

  // The ground, out to the backdrop.
  const ground = new THREE.Mesh(new THREE.PlaneGeometry(width, far - 0.2), projected(r, bg));
  ground.rotation.x = -Math.PI / 2;
  ground.position.set(0, 0, -(far + 0.2) / 2);
  ground.name = 'ground';
  art.add(ground);
  artMaterials.push(ground.material);

  // The backdrop: everything painted beyond the ground's end.
  const top = eye + (1 - S.horizon) * far;
  const backdrop = new THREE.Mesh(new THREE.PlaneGeometry(width, top + 0.2), projected(r, bg));
  backdrop.position.set(0, (top + 0.2) / 2 - 0.1, -far);
  art.add(backdrop);
  artMaterials.push(backdrop.material);

  // The planes in front, each (or each piece) at its depth.
  const legend = [];
  for (const [i, l] of r.layers.entries()) {
    const image = await texture(r.image(l.plane));
    const z = l.depth, w = 2 * r.halfWidth * z * 1.05, lo = eye - S.horizon * z, hi = eye + (1 - S.horizon) * z;
    const tint = new THREE.Color(layerTints[i % layerTints.length]);
    const m = projected(r, image, { mask: maskTexture(r, l), cutout: true, tint: new THREE.Vector4(tint.r, tint.g, tint.b, ui.layers ? 0.45 : 0) });
    m.userData.tint = tint;
    const mesh = new THREE.Mesh(new THREE.PlaneGeometry(w, hi - lo), m);
    mesh.position.set(0, (hi + lo) / 2, -z);
    art.add(mesh);
    artMaterials.push(m);
    legend.push(`<span><i style="background:#${tint.getHexString()}"></i>${l.id} ${z}</span>`);
  }
  document.getElementById('legend').innerHTML = ui.layers ? legend.join('') : '';

  buildPlaces(r, places);
  await buildCast(r, cast);
  world.add(root);
  built = { r, root, art, places, cast, artMaterials, ground };
  applyToggles();
}

function flat(points, color, opacity, y = 0.004) {
  const shape = new THREE.Shape(points.map(p => { const g = onGround(p); return new THREE.Vector2(g.x, -g.z); }));
  const geom = new THREE.ShapeGeometry(shape);
  geom.rotateX(-Math.PI / 2);   // (x, depth) → (x, 0, −depth)
  geom.translate(0, y, 0);
  const g = new THREE.Group();
  g.add(new THREE.Mesh(geom, new THREE.MeshBasicMaterial({ color, transparent: true, opacity, depthWrite: false, side: THREE.DoubleSide })));
  g.add(loop(points.map(p => onGround(p, y + 0.002)), color));
  return g;
}

function loop(points, color, closed = true) {
  const geom = new THREE.BufferGeometry().setFromPoints(closed ? [...points, points[0]] : points);
  return new THREE.Line(geom, new THREE.LineBasicMaterial({ color }));
}

function label(text, position, size = 0.12) {
  const c = document.createElement('canvas');
  c.width = 256; c.height = 64;
  const g = c.getContext('2d');
  g.fillStyle = 'rgba(0,0,0,0.55)'; g.fillRect(0, 0, 256, 64);
  g.fillStyle = '#fff'; g.font = 'bold 34px system-ui'; g.textAlign = 'center'; g.textBaseline = 'middle';
  g.fillText(text, 128, 33);
  const sprite = new THREE.Sprite(new THREE.SpriteMaterial({ map: new THREE.CanvasTexture(c), depthTest: false }));
  sprite.scale.set(size * 4, size, 1);
  sprite.position.copy(position);
  sprite.renderOrder = 10;
  return sprite;
}

function buildPlaces(r, group) {
  // Depth lines on the ground.
  for (let z = 1; z <= S.back; z++) {
    const x = r.halfWidth * z;
    group.add(loop([new THREE.Vector3(-x, 0.003, -z), new THREE.Vector3(x, 0.003, -z)], 0xffffff, false));
    group.add(label(`z ${z}`, new THREE.Vector3(-x * 0.9, 0.05 * z, -z), 0.06 * Math.sqrt(z)));
  }
  // Where stickers may stand.
  for (const z of [S.stand.near, S.stand.far]) {
    const x = r.halfWidth * z;
    group.add(loop([new THREE.Vector3(-x, 0.005, -z), new THREE.Vector3(x, 0.005, -z)], 0xffd34d, false));
  }
  for (const [id, p] of Object.entries(S.places)) {
    if (p.ground) {
      group.add(flat(p.ground, p.water ? 0x3c8cff : 0x50e070, 0.28));
      const c = p.ground.reduce((a, q) => [a[0] + q[0] / p.ground.length, a[1] + q[1] / p.ground.length], [0, 0]);
      group.add(label(id, onGround(c, 0.08), 0.07 * Math.sqrt(groundDepth(c[1]))));
    }
    if (p.air) {
      const [d0, d1] = p.air.depth;
      const nearLoop = p.air.area.map(q => atDepth(q, d0)), farLoop = p.air.area.map(q => atDepth(q, d1));
      group.add(loop(nearLoop, 0x7fe0ff), loop(farLoop, 0x7fe0ff));
      nearLoop.forEach((q, i) => group.add(loop([q, farLoop[i]], 0x7fe0ff, false)));
      const mid = p.air.area.reduce((a, q) => [a[0] + q[0] / p.air.area.length, a[1] + q[1] / p.air.area.length], [0, 0]);
      group.add(label(id, atDepth(mid, (d0 + d1) / 2), 0.25));
    }
    for (const line of r.lines(p)) {
      const layer = r.layers.find(l => l.id === line.layer);
      const pts = line.points.map(q => atDepth(q, layer.depth - 0.02));
      group.add(loop(pts, line.facing ? 0xff9b3c : 0xffe23c, false));
      group.add(label(line.facing ? `${id} (${line.facing})` : id, pts[0].clone().add(new THREE.Vector3(0, 0.15, 0)), 0.1));
    }
  }
  for (const l of r.layers) {
    if (l.footprint) group.add(flat(l.footprint, 0xff4040, 0.45, 0.006));
  }
  // The camera and what it sees, out to the backdrop.
  const corners = [[-(r.k - 1) / 2, 0], [1 + (r.k - 1) / 2, 0], [1 + (r.k - 1) / 2, 1], [-(r.k - 1) / 2, 1]].map(q => atDepth(q, S.back));
  const at = new THREE.Vector3(0, eye, 0);
  corners.forEach(q => group.add(loop([at, q], 0xffffff, false)));
  group.add(loop(corners, 0xffffff));
  const cam = new THREE.Mesh(new THREE.SphereGeometry(0.04), new THREE.MeshBasicMaterial({ color: 0xffffff }));
  cam.position.copy(at);
  group.add(cam);
  group.userData.cameraOnly = [cam, ...group.children.slice(-5)];
}

// MARK: Stickers

const imageCache = {};
async function stickerArt(id) {
  if (imageCache[id]) return imageCache[id];
  const tex = await texture('/pack/' + stickerByID[id].image);
  const img = tex.image;
  // The drawing's box inside the image: feet on the ground, not the
  // image's empty margin.
  const c = document.createElement('canvas');
  c.width = img.width; c.height = img.height;
  const g = c.getContext('2d');
  g.drawImage(img, 0, 0);
  const a = g.getImageData(0, 0, c.width, c.height).data;
  let x0 = c.width, y0 = c.height, x1 = 0, y1 = 0;
  for (let y = 0; y < c.height; y += 2) for (let x = 0; x < c.width; x += 2) {
    if (a[(y * c.width + x) * 4 + 3] > 40) { x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); }
  }
  const t = tex.clone();
  t.repeat.set((x1 - x0) / c.width, (y1 - y0) / c.height);
  t.offset.set(x0 / c.width, 1 - y1 / c.height);
  t.needsUpdate = true;
  return (imageCache[id] = { texture: t, aspect: (x1 - x0) / (y1 - y0) });
}

async function makeSticker(id) {
  const size = S.sizes[id];
  const { texture: t, aspect } = await stickerArt(id);
  const geom = new THREE.PlaneGeometry(size * aspect, size);
  geom.translate(0, size / 2, 0);   // feet at the origin
  const body = new THREE.Mesh(geom, new THREE.MeshBasicMaterial({ map: t, alphaTest: 0.5, side: THREE.DoubleSide }));
  const shadow = new THREE.Mesh(new THREE.CircleGeometry(0.5, 32), new THREE.MeshBasicMaterial({ color: 0x000000, transparent: true, opacity: 0.28, depthWrite: false }));
  shadow.rotation.x = -Math.PI / 2;
  const holder = new THREE.Group();
  holder.add(body);
  return { id, size, width: size * aspect, body, shadow, holder, facing: stickerByID[id].facing || 'right' };
}

// Puts a sticker with its feet at p, sized for its depth (the floor keeps
// it from shrinking away), its shadow on the ground beneath it.
function place(s, p, dx = 0) {
  const z = -p.z;
  const grow = drawnHeight(s.size, z) * z / s.size;
  s.holder.position.copy(p);
  if (dx) s.flip = (dx < 0) === (s.facing === 'right') ? -1 : 1;
  s.holder.scale.set(grow * (s.flip || 1), grow, grow);
  s.shadow.position.set(p.x, 0.007, p.z);
  s.shadow.scale.set(s.width * grow * 0.8, s.width * grow * 0.16, 1);
}

// A path at a steady pace through space: further away it crosses less of
// the picture, as it should.
function walker(points, speed) {
  const legs = [];
  let total = 0;
  for (let i = 1; i < points.length; i++) {
    const d = points[i].distanceTo(points[i - 1]);
    legs.push({ a: points[i - 1], b: points[i], from: total, d });
    total += d;
  }
  return t => {
    const at = (t * speed) % total;
    const leg = legs.find(l => at <= l.from + l.d) || legs[legs.length - 1];
    const f = (at - leg.from) / leg.d;
    return { p: leg.a.clone().lerp(leg.b, f), dx: leg.b.x - leg.a.x };
  };
}

async function buildCast(r, group) {
  const movers = [];
  for (const item of S.preview || []) {
    if (!stickerByID[item.sticker] || !S.sizes[item.sticker]) continue;
    const s = await makeSticker(item.sticker);
    group.add(s.holder, s.shadow);
    if (item.at) place(s, onGround(item.at));
    if (item.path) {
      const go = walker(item.path.map(q => onGround(q)), 0.45);
      movers.push(t => { const { p, dx } = go(t); place(s, p, dx); });
    }
    if (item.perch) {
      const line = r.lines(S.places[item.perch])[0];
      const layer = r.layers.find(l => l.id === line.layer);
      const [a, b] = line.points;
      const p = atDepth([(a[0] + b[0]) / 2, (a[1] + b[1]) / 2], layer.depth - 0.05);
      place(s, p);
      s.shadow.visible = false;
    }
    if (item.fly) {
      const go = walker(item.fly.map(q => atDepth(q, item.depth)), 0.6);
      movers.push(t => { const { p, dx } = go(t); p.y += 0.04 * Math.sin(t * 5); place(s, p, dx); });
    }
  }
  group.userData.movers = movers;
}

// MARK: Toggles, input, drawing

function applyToggles() {
  if (!built) return;
  built.artMaterials.forEach(m => {
    m.uniforms.showArt.value = ui.art ? 1 : 0;
    const t = m.userData.tint;
    if (t) m.uniforms.tint.value.set(t.r, t.g, t.b, ui.layers ? 0.45 : 0);
  });
  built.places.visible = ui.places;
  built.places.userData.cameraOnly.forEach(o => (o.visible = !ui.pov));
  built.cast.visible = ui.cast;
  for (const id of ['pov', 'orbit', 'base', 'wide', 'art', 'places', 'layers', 'cast', 'walk']) {
    const on = id === 'orbit' ? !ui.pov : id === 'base' ? !ui.wide : ui[id];
    document.getElementById(id).classList.toggle('on', on);
  }
}

async function set(key, value) {
  const rebuild = (key === 'wide' && ui.wide !== value) || key === 'layers';
  ui[key] = value;
  if (rebuild) await build();
  applyToggles();
}
const buttons = {
  pov: () => set('pov', true), orbit: () => set('pov', false),
  base: () => set('wide', false), wide: () => set('wide', true),
  art: () => set('art', !ui.art), places: () => set('places', !ui.places),
  layers: () => set('layers', !ui.layers), cast: () => set('cast', !ui.cast), walk: () => set('walk', !ui.walk),
};
for (const [id, f] of Object.entries(buttons)) document.getElementById(id).onclick = f;
window.addEventListener('keydown', e => {
  const hide = () => ['panel', 'info'].forEach(id => document.getElementById(id).classList.toggle('hidden'));
  const k = { h: hide, c: () => set('pov', !ui.pov), w: () => set('wide', !ui.wide), a: buttons.art, p: buttons.places, l: buttons.layers, s: buttons.cast, ' ': buttons.walk }[e.key.toLowerCase()];
  if (k) { e.preventDefault(); k(); }
});

// The viewport: the art's shape, letterboxed, in the camera view; the whole
// window when turning around.
function viewport() {
  const W = window.innerWidth, H = window.innerHeight;
  if (!ui.pov) return { x: 0, y: 0, w: W, h: H };
  const ar = 2 * built.r.halfWidth;
  const w = Math.min(W, H * ar), h = w / ar;
  return { x: (W - w) / 2, y: (H - h) / 2, w, h };
}

const raycaster = new THREE.Raycaster();
const info = document.getElementById('info');
renderer.domElement.addEventListener('pointermove', e => {
  if (!built) return;
  const v = viewport();
  const ndc = new THREE.Vector2(((e.clientX - v.x) / v.w) * 2 - 1, -((e.clientY - v.y) / v.h) * 2 + 1);
  raycaster.setFromCamera(ndc, ui.pov ? povCamera : orbitCamera);
  const hit = raycaster.intersectObject(built.ground)[0];
  if (!hit) { info.textContent = 'move the pointer over the ground'; return; }
  const z = -hit.point.z, x = hit.point.x;
  const u = 0.5 + x / (A * z), vv = S.horizon - eye / z;
  info.textContent = `art (${u.toFixed(3)}, ${vv.toFixed(3)})  ·  depth ${z.toFixed(2)}  ·  x ${x.toFixed(2)}  ·  a 0.20 sticker is drawn ${(drawnHeight(0.2, z)).toFixed(3)} tall`;
});

let time = Number(params.get('t') || 0), last = performance.now();
function frame(now) {
  const dt = Math.min((now - last) / 1000, 0.1);
  last = now;
  if (ui.walk) time += dt;
  if (built) {
    built.cast.userData.movers.forEach(m => m(time));
    const W = window.innerWidth, H = window.innerHeight;
    renderer.setSize(W, H, false);
    renderer.setScissor(0, 0, W, H);
    renderer.setViewport(0, 0, W, H);
    renderer.setClearColor(clearColor);
    renderer.clear();
    const v = viewport();
    renderer.setViewport(v.x, H - v.y - v.h, v.w, v.h);
    renderer.setScissor(v.x, H - v.y - v.h, v.w, v.h);
    if (ui.pov) {
      renderer.render(world, povCamera);
    } else {
      orbitCamera.aspect = v.w / v.h;
      orbitCamera.updateProjectionMatrix();
      controls.update();
      renderer.render(world, orbitCamera);
    }
  }
  requestAnimationFrame(frame);
}

renderer.domElement.style.width = '100%';
renderer.domElement.style.height = '100%';
await build();
requestAnimationFrame(frame);
