package main

import (
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"stickerstories/tools/internal/manifest"
)

// runPreview writes one self-contained HTML page per installed puppet
// (out/rigs/<sticker>.preview.html): the puppet at rest beside and over
// the sticker, every face, and every animation playing, with its keys
// laid out — drawn by the same rules the app poses it with.
func runPreview(args []string) error {
	fs := flag.NewFlagSet("preview", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	artDir := fs.String("art", "", "art directory (default author/art/<packID>)")
	only := fs.String("only", "", "comma-separated sticker ids")
	fs.Parse(args)
	c, err := load(*packDir, *artDir, *only)
	if err != nil {
		return err
	}
	for _, r := range c.rigs() {
		rigPath := filepath.Join(c.packDir, "anims", r.Sticker+".rig.json")
		rig, err := manifest.LoadPuppetRig(rigPath)
		if err != nil {
			return fmt.Errorf("%s: not installed (stickerrig install): %w", r.Sticker, err)
		}
		atlas, err := os.ReadFile(filepath.Join(c.packDir, filepath.FromSlash(rig.Atlas)))
		if err != nil {
			return err
		}
		st := c.sticker(r.Sticker)
		sticker, err := os.ReadFile(filepath.Join(c.packDir, filepath.FromSlash(st.Image)))
		if err != nil {
			return err
		}
		type anim struct {
			ID, Kind, Description string
			Puppet                *manifest.AnimationPuppet
		}
		var anims []anim
		for _, rel := range st.Animations {
			a, err := manifest.LoadStickerAnimation(filepath.Join(c.packDir, filepath.FromSlash(rel)))
			if err != nil {
				return err
			}
			if a.Puppet != nil {
				anims = append(anims, anim{a.ID, a.EffectiveKind(), a.Description, a.Puppet})
			}
		}
		data, _ := json.Marshal(map[string]any{
			"rig": rig, "anims": anims,
			"atlas":   "data:image/webp;base64," + base64.StdEncoding.EncodeToString(atlas),
			"sticker": "data:image/webp;base64," + base64.StdEncoding.EncodeToString(sticker),
		})
		page := strings.Replace(previewHTML, "/*DATA*/null", string(data), 1)
		page = strings.ReplaceAll(page, "{{STICKER}}", r.Sticker)
		out := c.out(r.Sticker + ".preview.html")
		if err := os.WriteFile(out, []byte(page), 0o644); err != nil {
			return err
		}
		fmt.Printf("✓ %s\n", out)
	}
	return nil
}

// previewHTML draws a puppet with canvas transforms, by the rules of
// docs/pack-format.md, "Puppets" (the app's PuppetNode does the same).
const previewHTML = `<!doctype html>
<html><head><meta charset="utf-8"><title>{{STICKER}} puppet</title>
<style>
body { background: #6f8f6f; color: #fff; font: 15px -apple-system, system-ui, sans-serif; margin: 24px; }
h2 { margin: 28px 0 8px; font-weight: 600; }
.row { display: flex; gap: 16px; flex-wrap: wrap; align-items: flex-start; }
figure { margin: 0; text-align: center; }
figcaption { font-size: 12px; opacity: .85; margin-top: 4px; }
canvas { background: #86a586; border-radius: 10px; }
.desc { opacity: .85; max-width: 900px; }
</style></head><body>
<h1>{{STICKER}} puppet</h1>
<h2>At rest</h2>
<div class="row" id="rest"></div>
<h2>Faces</h2>
<div class="row" id="faces"></div>
<div id="anims"></div>
<script>
const D = /*DATA*/null;
const rig = D.rig, S = rig.size;
const atlas = new Image(), sticker = new Image();
let loaded = 0;
atlas.onload = sticker.onload = () => { if (++loaded == 2) start(); };
atlas.src = D.atlas; sticker.src = D.sticker;
const bones = {}; rig.bones.forEach(b => bones[b.id] = b);
const ease = { inOut: t => t*t*(3-2*t), "": t => t*t*(3-2*t), in: t => t*t, out: t => 1-(1-t)*(1-t), linear: t => t, step: t => t < 1 ? 0 : 1 };

// A pose: per bone {r, x, y, sx, sy}, per slot the attachment shown.
function poseAt(keys, i, t, face) {
  const a = keys[i], b = keys[i2(keys, i)] || a;
  const e = ease[a.ease || ""](t);
  const out = { bones: {}, slots: {} };
  for (const id in bones) {
    const p = (a.bones||{})[id] || {}, q = (b.bones||{})[id] || {};
    const l = (k, d) => (p[k] ?? d) + ((q[k] ?? d) - (p[k] ?? d)) * e;
    out.bones[id] = { r: l("r", 0), x: l("x", 0), y: l("y", 0), sx: l("sx", 1), sy: l("sy", 1) };
  }
  const faceSlots = (rig.faces || {})[face] || {};
  rig.slots.forEach(s => out.slots[s.id] = (a.slots||{})[s.id] ?? faceSlots[s.id] ?? s.default);
  return out;
}
let i2 = (keys, i) => i + 1;
function restPose(face) {
  const out = { bones: {}, slots: {} };
  for (const id in bones) out.bones[id] = { r: 0, x: 0, y: 0, sx: 1, sy: 1 };
  const f = (rig.faces || {})[face] || {};
  rig.slots.forEach(s => out.slots[s.id] = f[s.id] ?? s.default);
  return out;
}

function draw(ctx, pose, opts = {}) {
  const world = {};
  for (const b of rig.bones) {
    const p = pose.bones[b.id], parent = b.parent ? bones[b.parent] : null;
    const m = parent ? world[b.parent].translate(0, 0) : new DOMMatrix();
    const rx = parent ? b.x - parent.x : b.x, ry = parent ? b.y - parent.y : b.y;
    world[b.id] = m.translate(rx + p.x, ry + p.y).rotate(p.r).scale(p.sx, p.sy);
  }
  const base = ctx.getTransform();
  for (const layer of opts.layers || ["border", "art"]) {
    for (const s of rig.slots) {
      const name = pose.slots[s.id];
      const a = s.attachments[name];
      if (!a) continue;
      const part = rig.parts[a.part], b = bones[s.bone];
      const cx = a.x + a.w / 2 - b.x, cy = a.y + a.h / 2 - b.y;
      const m = base.multiply(world[s.bone]).translate(cx, cy).rotate(a.rotate || 0).scale(a.flip ? -1 : 1, 1);
      ctx.setTransform(m);
      if (layer == "border") {
        const [x, y, w, h] = part.border, kx = a.w / part.rect[2], ky = a.h / part.rect[3];
        ctx.drawImage(atlas, x, y, w, h, -w * kx / 2, -h * ky / 2, w * kx, h * ky);
      } else {
        const [x, y, w, h] = part.rect;
        ctx.filter = a.shade ? "brightness(" + (1 - a.shade) + ")" : "none";
        ctx.drawImage(atlas, x, y, w, h, -a.w / 2, -a.h / 2, a.w, a.h);
        ctx.filter = "none";
      }
    }
  }
  ctx.setTransform(base);
}

function canvas(parent, caption, size = 300, span = 1) {
  const fig = document.createElement("figure"), c = document.createElement("canvas");
  c.width = size * 2 * span; c.height = size * 2; c.style.width = size * span + "px"; c.style.height = size + "px";
  fig.appendChild(c);
  const cap = document.createElement("figcaption"); cap.textContent = caption; fig.appendChild(cap);
  parent.appendChild(fig);
  const ctx = c.getContext("2d");
  return { ctx, c, k: size * 2 / S, span };
}
function frame(v, fn) {
  const { ctx, c, k } = v;
  ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, c.width, c.height);
  ctx.setTransform(k, 0, 0, k, (c.width - S * k) / 2, 0);
  fn(ctx);
}

function start() {
  const rest = document.getElementById("rest");
  frame(canvas(rest, "the sticker"), ctx => ctx.drawImage(sticker, 0, 0, S, S));
  frame(canvas(rest, "the puppet at rest"), ctx => draw(ctx, restPose("normal")));
  frame(canvas(rest, "puppet over the sticker (50 %)"), ctx => { ctx.drawImage(sticker, 0, 0, S, S); ctx.globalAlpha = .5; draw(ctx, restPose("normal")); ctx.globalAlpha = 1; });
  const flick = canvas(rest, "sticker ⇄ puppet, every second");
  setInterval(() => frame(flick, ctx => (Math.floor(Date.now() / 1000) % 2) ? ctx.drawImage(sticker, 0, 0, S, S) : draw(ctx, restPose("normal"))), 100);
  const faces = document.getElementById("faces");
  for (const f of ["normal", ...Object.keys(rig.faces || {}).filter(f => f != "normal")])
    frame(canvas(faces, f, 160), ctx => draw(ctx, restPose(f)));
  const anims = document.getElementById("anims");
  for (const a of D.anims) {
    const sec = document.createElement("div");
    sec.innerHTML = "<h2>" + a.ID + " (" + a.Kind + ")</h2><p class=desc>" + a.Description + "</p>";
    anims.appendChild(sec);
    const row = document.createElement("div"); row.className = "row"; sec.appendChild(row);
    const p = a.Puppet, keys = p.keys;
    // Played as a story would: an action whole (holding its pause a
    // second), a move's loop three times then its settle.
    const seq = [];
    if (p.loop) {
      for (let n = 0; n < 4; n++) for (let i = p.loop.from; i <= p.loop.to; i++) seq.push([i, i == p.loop.to ? p.loop.from : i + 1]);
      seq.pop(); seq.push([p.loop.to, p.loop.to + 1]);
      for (let i = p.loop.to + 1; i < keys.length; i++) seq.push([i, i + 1]);
    } else {
      for (let i = 0; i < keys.length; i++) seq.push([i, i + 1]);
    }
    const holds = seq.map(([i]) => keys[i].hold + (i === p.pause ? 1 : 0));
    const total = holds.reduce((x, y) => x + y, 0) + 0.8;
    const v = canvas(row, "playing (" + total.toFixed(1) + " s a round)", 300, p.loop ? 1.6 : 1);
    const t0 = performance.now();
    (function tick() {
      let t = ((performance.now() - t0) / 1000) % total, j = 0;
      while (j < seq.length && t >= holds[j]) { t -= holds[j]; j++; }
      let pose;
      if (j >= seq.length) pose = poseAt(keys, keys.length - 1, 0, "normal");
      else {
        const [i, n] = seq[j];
        i2 = () => n;
        const hold = keys[i].hold, extra = holds[j] - hold;
        pose = poseAt(keys, i, Math.max(0, t - extra) / hold, "normal");
        i2 = (keys, i) => i + 1;
      }
      frame(v, ctx => draw(ctx, pose));
      requestAnimationFrame(tick);
    })();
    const strip = document.createElement("div"); strip.className = "row"; sec.appendChild(strip);
    keys.forEach((k, i) => frame(canvas(strip, "key " + i + " · " + k.hold + " s" + (i === p.pause ? " · pause" : "") + (p.loop && i >= p.loop.from && i <= p.loop.to ? " · loop" : ""), 110), ctx => draw(ctx, poseAt(keys, i, 0, "normal"))));
  }
}
</script></body></html>
`
