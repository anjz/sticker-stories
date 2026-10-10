# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = [
#   "mflux==0.17.5",
#   "numpy",
#   "pillow",
#   "scipy",
#   "pyobjc-framework-Vision",
#   "pyobjc-framework-Quartz",
# ]
# ///
"""Local image server for the art tools (stickerart, stickeranim, uiart).

Speaks the subset of the OpenAI Images API the tools use —
POST /v1/images/generations (JSON) and POST /v1/images/edits (multipart:
image[] references, an optional mask) — and answers with b64 PNGs, so the
tools' `-local` flag only swaps the client's base URL. The model is loaded
once and kept warm; requests are served one at a time (one GPU). The server
exits on its own after `idleMinutes` without a request.

What the hosted API does that a diffusion model does not, done here:
- transparent backgrounds: the picture is drawn on a plain background and
  cut out (Apple Vision's subject lifting, plus a flood fill from the edges
  for anything Vision drops), the edge colour decontaminated;
- masks (transparent = paint): inpainting by latent blending — every step
  the kept area is reset to the original at that noise level — and the
  result laid over the original only inside the (feathered) mask;
- sizes: drawn at the quality profile's pixel budget, then resized to the
  requested size;
- prompts: the tools write for the hosted model; transparency wording is
  turned into the matte background here.

Dev-time only. See README.md next to this file.
"""

import argparse
import base64
import hashlib
import io
import json
import math
import queue
import os
import random
import re
import sys
import threading
import time
import traceback
from email.parser import BytesParser
from email.policy import HTTP
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

# ---------- config ----------

DEFAULT_PROFILE = {"steps": 4, "maxPixels": 1048576}


def load_config(path):
    with open(path) as f:
        cfg = json.load(f)
    cfg.setdefault("listen", "127.0.0.1:7865")
    cfg.setdefault("idleMinutes", 15)
    cfg.setdefault("qualities", {})
    cfg.setdefault("matte", {})
    cfg["matte"].setdefault("background", [255, 255, 255])
    cfg["matte"].setdefault("tolerance", 24)
    cfg.setdefault("references", {})
    cfg["references"].setdefault("maxPixels", 1048576)
    cfg.setdefault("inpaint", {})
    cfg["inpaint"].setdefault("feather", 12)
    cfg["inpaint"].setdefault("minSteps", 8)
    m = cfg["model"]
    m["path"] = os.path.expanduser(m.get("path") or "")
    return cfg


def profile(cfg, quality, overrides=None):
    """A quality's settings: steps, maxPixels (the drawing's pixel budget),
    refMaxPixels, inpaintSteps, maskReference, drawLarger. A request's
    `local` field overrides any of them (experiments; the tools never send
    it)."""
    q = cfg["qualities"]
    p = dict(DEFAULT_PROFILE)
    p["refMaxPixels"] = cfg["references"]["maxPixels"]
    p["inpaintSteps"] = cfg["inpaint"]["minSteps"]
    p["maskReference"] = cfg["inpaint"].get("reference", "blank")
    p.update(q.get(quality) or q.get("high") or {})
    p.update(overrides or {})
    return p


# ---------- model ----------


class Flux2KleinBackend:
    """FLUX.2 [klein] (4B or 9B, distilled) on MLX through mflux's model
    components, with our own loop: references capped in size (mflux encodes
    them at the output size), masked inpainting, a text-token budget."""

    def __init__(self, m):
        from mflux.models.common.config.model_config import ModelConfig
        from mflux.models.flux2.variants import Flux2KleinEdit

        configs = {
            "flux2-klein-4b": ModelConfig.flux2_klein_4b,
            "flux2-klein-9b": ModelConfig.flux2_klein_9b,
        }
        if m["name"] not in configs:
            raise SystemExit(f"model.name {m['name']!r}: this backend runs {sorted(configs)}")
        t = time.time()
        self.model = Flux2KleinEdit(
            quantize=m.get("quantize"),
            model_path=m["path"] or None,
            model_config=configs[m["name"]](),
            lora_paths=m.get("loras") or None,
            lora_scales=m.get("loraScales") or None,
        )
        self.max_tokens = int(m.get("maxTextTokens", 512))
        log(f"loaded {m['name']} from {m['path'] or 'the Hugging Face cache'} in {time.time() - t:.0f}s")

    def encode_text(self, prompt):
        from mflux.models.flux2.model.flux2_text_encoder.prompt_encoder import Flux2PromptEncoder

        return Flux2PromptEncoder.encode_prompt(
            prompt=prompt,
            tokenizer=self.model.tokenizers["qwen3"],
            text_encoder=self.model.text_encoder,
            num_images_per_prompt=1,
            max_sequence_length=self.max_tokens,
            text_encoder_out_layers=(9, 18, 27),
        )

    def encode_image(self, img):
        """RGB PIL image (dimensions multiples of 16) → packed, normalised
        latents and the (unpacked) latent grid shape."""
        from mflux.models.common.vae.vae_util import VAEUtil
        from mflux.models.flux2.latent_creator.flux2_latent_creator import Flux2LatentCreator
        from mflux.models.flux2.variants.edit.flux2_klein_edit_helpers import _Flux2KleinEditHelpers as H
        from mflux.utils.image_util import ImageUtil

        enc = VAEUtil.encode(vae=self.model.vae, image=ImageUtil.to_array(img), tiling_config=self.model.tiling_config)
        enc = H.crop_to_even_spatial(H.ensure_4d_latents(enc))
        enc = Flux2LatentCreator.patchify_latents(enc)
        enc = H.bn_normalize_vae_encoded_latents(enc, vae=self.model.vae)
        return enc

    def generate(self, prompt, width, height, steps, seed, refs, init=None, mask=None):
        """refs: RGB PIL images (already sized); init + mask (latent-grid
        float array, 1 = paint) for inpainting. Returns an RGB PIL image."""
        import mlx.core as mx
        from mflux.models.common.schedulers.flow_match_euler_discrete_scheduler import FlowMatchEulerDiscreteScheduler as S
        from mflux.models.flux2.latent_creator.flux2_latent_creator import Flux2LatentCreator as L

        prompt_embeds, text_ids = self.encode_text(prompt)
        latents, latent_ids, lh, lw = L.prepare_packed_latents(seed=seed, height=height, width=width, batch_size=1)
        noise = latents
        ref_lat, ref_ids = None, None
        if refs:
            packed, ids = [], []
            for i, r in enumerate(refs):
                enc = self.encode_image(r)
                packed.append(L.pack_latents(enc))
                ids.append(L.prepare_grid_ids(enc, t_coord=10 + 10 * i))
            ref_lat, ref_ids = mx.concatenate(packed, axis=1), mx.concatenate(ids, axis=1)
        clean = keep = None
        if init is not None:
            enc = self.encode_image(init)
            clean = L.pack_latents(enc)
            keep = mx.array(1.0 - mask.reshape(1, -1, 1)).astype(clean.dtype)

        timesteps, sigmas = S.get_timesteps_and_sigmas(image_seq_len=lh * lw, num_inference_steps=steps)
        tr = self.model.transformer
        n = latents.shape[1]
        for i in range(steps):
            if ref_lat is not None:
                hidden = mx.concatenate([latents, ref_lat], axis=1)
                ids = mx.concatenate([latent_ids, ref_ids], axis=1)
            else:
                hidden, ids = latents, latent_ids
            v = tr(hidden_states=hidden, encoder_hidden_states=prompt_embeds, timestep=timesteps[i], img_ids=ids, txt_ids=text_ids, guidance=None)
            v = v[:, :n]
            latents = latents + (sigmas[i + 1] - sigmas[i]).astype(latents.dtype) * v.astype(latents.dtype)
            if clean is not None:
                s = sigmas[i + 1]
                known = (1 - s) * clean + s * noise
                latents = keep * known + (1 - keep) * latents
            mx.eval(latents)

        packed = latents.reshape(1, lh, lw, latents.shape[-1]).transpose(0, 3, 1, 2)
        decoded = self.model.vae.decode_packed_latents(packed)
        arr = np.array(decoded.astype(mx.float32))[0].transpose(1, 2, 0)
        arr = np.clip((arr + 1) / 2, 0, 1)
        return Image.fromarray((arr * 255 + 0.5).astype(np.uint8), "RGB")


# ---------- images ----------


def fit(w, h, max_pixels, multiple=16, larger=False):
    """The largest size with w:h's aspect within max_pixels, both sides
    multiples of `multiple`; never larger than w×h unless `larger`."""
    s = math.sqrt(max_pixels / float(w * h))
    if not larger:
        s = min(1.0, s)
    gw = max(multiple, int(w * s) // multiple * multiple)
    gh = max(multiple, int(h * s) // multiple * multiple)
    return gw, gh


def flatten(img, bg):
    """RGBA → RGB over the matte colour (transparent pixels become plain
    background, as the model draws it)."""
    img = img.convert("RGBA")
    base = Image.new("RGBA", img.size, tuple(bg) + (255,))
    base.alpha_composite(img)
    return base.convert("RGB")


def vision_mask(img):
    """Apple Vision's foreground instance mask (all instances), float 0–1,
    or None when it finds no subject."""
    import Quartz
    import Vision
    from Foundation import NSData

    buf = io.BytesIO()
    img.save(buf, "PNG")
    raw = buf.getvalue()
    data = NSData.dataWithBytes_length_(raw, len(raw))
    req = Vision.VNGenerateForegroundInstanceMaskRequest.alloc().init()
    handler = Vision.VNImageRequestHandler.alloc().initWithData_options_(data, None)
    ok, err = handler.performRequests_error_([req], None)
    if not ok or not req.results():
        return None
    obs = req.results()[0]
    pb, err = obs.generateScaledMaskForImageForInstances_fromRequestHandler_error_(obs.allInstances(), handler, None)
    if pb is None:
        return None
    Quartz.CVPixelBufferLockBaseAddress(pb, 0)
    try:
        w, h = Quartz.CVPixelBufferGetWidth(pb), Quartz.CVPixelBufferGetHeight(pb)
        bpr = Quartz.CVPixelBufferGetBytesPerRow(pb)
        base = Quartz.CVPixelBufferGetBaseAddress(pb)
        m = np.frombuffer(base.as_buffer(bpr * h), dtype=np.float32).reshape(h, bpr // 4)[:, :w].copy()
    finally:
        Quartz.CVPixelBufferUnlockBaseAddress(pb, 0)
    return np.clip(m, 0, 1)


def matte(img, bg, tol):
    """Cut the subject(s) out of a picture drawn on a plain background.
    Returns RGBA."""
    rgb = np.asarray(img.convert("RGB")).astype(np.float32)
    bgc = np.array(bg, dtype=np.float32)
    dist = np.sqrt(((rgb - bgc) ** 2).sum(-1))
    # Flood fill: background is what connects to the border through
    # near-background pixels.
    near = dist < tol
    lab, _ = ndimage.label(near)
    border = np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))
    border = border[border > 0]
    outside = np.isin(lab, border)
    subject_ff = ~outside

    alpha = None
    try:
        alpha = vision_mask(img)
    except Exception as e:  # Vision unavailable: flood fill only
        log(f"vision: {e}")
    if alpha is None:
        alpha = subject_ff.astype(np.float32)
        alpha = ndimage.gaussian_filter(alpha, 0.7)
    else:
        # Whatever Vision dropped (a fern beside the stump, a frame of a
        # sheet) but the flood fill says is drawn: add it back.
        lab2, n2 = ndimage.label(subject_ff)
        if n2:
            idx = np.arange(1, n2 + 1)
            area = ndimage.sum(np.ones_like(alpha), lab2, idx)
            covered = ndimage.sum(alpha > 0.5, lab2, idx)
            min_area = 0.0004 * alpha.size
            missed = idx[(area > min_area) & (covered < 0.2 * area)]
            if len(missed):
                add = ndimage.gaussian_filter(np.isin(lab2, missed).astype(np.float32), 0.7)
                alpha = np.maximum(alpha, add)
        # Vision's soft edge spills onto plain background: pixels that are
        # background and connect to the border go.
        alpha = np.where(outside & (dist < tol * 0.5), 0, alpha)
    # Decontaminate: remove the background colour mixed into edge pixels.
    a = alpha[..., None]
    with np.errstate(divide="ignore", invalid="ignore"):
        fg = np.where(a > 0.02, (rgb - (1 - a) * bgc) / np.maximum(a, 1e-3), rgb)
    fg = np.clip(fg, 0, 255)
    out = np.dstack([fg, alpha * 255]).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


# ---------- prompts ----------


ORDINALS = ["first", "second", "third", "fourth"]


def adapt(prompt, transparent, bg_name, nrefs=0):
    """The tools write for the hosted model; say what this one draws, and
    name the references the way FLUX.2 knows them (image 1, image 2…)."""
    for i, o in enumerate(ORDINALS):
        prompt = re.sub(rf"(?i)\bthe {o} attached image\b", f"image {i + 1}", prompt)
    if nrefs:
        prompt = re.sub(r"(?i)\bthe attached (style sheet|image|picture|reference)\b", r"the \1 in image 1", prompt)
    if transparent:
        p = re.sub(r"(?i)\b(a |an )?fully transparent background\b", f"a plain flat {bg_name} background", prompt)
        p = re.sub(r"(?i)\bfully transparent\b", f"plain flat {bg_name} background", p)
        p = re.sub(r"(?i)\btransparent\b", f"plain {bg_name}", p)
        p += f"\n\nPlain flat {bg_name} background everywhere around the drawing: no shading, no texture, no shadow on it."
        return p
    return re.sub(r"(?i)\btransparent\b", "empty", prompt)


# ---------- requests ----------


class Server:
    """MLX work happens on one thread (its GPU stream belongs to the thread
    that made it): the model is loaded there and every request queues for
    it."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.last = time.time()
        self.busy = 0
        self.jobs = queue.Queue()
        ready = threading.Event()
        threading.Thread(target=self.worker, args=(ready,), daemon=True).start()
        ready.wait()

    def worker(self, ready):
        import mlx.core as mx

        # MLX keeps freed buffers for reuse; uncapped, that cache grows to
        # twice the weights and pushes everything else on the Mac to swap.
        mx.set_cache_limit(int(float(self.cfg.get("cacheLimitGB", 2)) * (1 << 30)))
        self.backend = Flux2KleinBackend(self.cfg["model"])
        ready.set()
        while True:
            kw, done = self.jobs.get()
            try:
                done.append(("ok", self.render(**kw)))
            except Exception as e:
                traceback.print_exc()
                done.append(("err", e))
            finally:
                mx.clear_cache()
                done.ready.set()

    def submit(self, **kw):
        done = Done()
        self.jobs.put((kw, done))
        done.ready.wait()
        kind, val = done[0]
        if kind == "err":
            raise val
        return val

    def render(self, *, prompt, size, quality, background, references, mask, seed, overrides=None):
        cfg = self.cfg
        prof = profile(cfg, quality, overrides)
        w, h = (int(x) for x in size.lower().split("x")) if size and size != "auto" else (1024, 1024)
        transparent = background == "transparent"
        bg = cfg["matte"]["background"]
        bg_name = cfg["matte"].get("name", "white")
        steps = int(prof["steps"])
        gw, gh = fit(w, h, int(prof["maxPixels"]), larger=bool(prof.get("drawLarger")))

        refs_in = [Image.open(io.BytesIO(r)) for r in references]
        refs_in = [r.convert("RGBA") for r in refs_in]
        refs = []
        rmax = int(prof["refMaxPixels"])
        for r in refs_in:
            rw, rh = fit(r.width, r.height, rmax, larger=True)
            refs.append(flatten(r, bg).resize((rw, rh), Image.LANCZOS))

        init = lmask = pmask = None
        if mask is not None:
            if not refs_in:
                raise ValueError("a mask needs an image")
            mk = Image.open(io.BytesIO(mask)).convert("RGBA").resize((gw, gh), Image.LANCZOS)
            paint = 1.0 - np.asarray(mk)[..., 3].astype(np.float32) / 255.0
            init = flatten(refs_in[0], bg).resize((gw, gh), Image.LANCZOS)
            # Latent grid is 1/16 of the pixels; grow the area a little so
            # the edge is repainted, not just its inside.
            lm = Image.fromarray((paint * 255).astype(np.uint8)).resize((gw // 16, gh // 16), Image.BOX)
            lmask = (np.asarray(lm).astype(np.float32) / 255.0 > 0.02).astype(np.float32)
            lmask = ndimage.binary_dilation(lmask, iterations=1).astype(np.float32)
            steps = max(steps, int(prof["inpaintSteps"]))
            pmask = paint
            # The image as the model sees it: as it is ("original"), with
            # the area to repaint blanked so it does not copy what is
            # there — the prop it is asked to remove ("blank") —, or not at
            # all, the kept area coming in only through the latents ("none").
            mode = prof["maskReference"]
            if mode == "none":
                refs = refs[1:]
            elif mode == "blank":
                r0 = refs[0]
                pm = Image.fromarray((paint * 255).astype(np.uint8)).resize(r0.size, Image.LANCZOS)
                refs[0] = Image.composite(Image.new("RGB", r0.size, tuple(bg)), r0, pm)

        seed = int(seed) if seed is not None else random.randrange(1 << 31)
        p = adapt(prompt, transparent, bg_name, len(refs))
        t = time.time()
        img = self.backend.generate(p, gw, gh, steps, seed, refs, init=init, mask=lmask)
        secs = time.time() - t

        if (gw, gh) != (w, h):
            img = img.resize((w, h), Image.LANCZOS)
        if transparent:
            out = matte(img, bg, float(cfg["matte"]["tolerance"]))
        else:
            out = img.convert("RGBA")
        if pmask is not None:
            # Only the masked area changes: the original everywhere else.
            orig = refs_in[0].resize((w, h), Image.LANCZOS)
            pm = Image.fromarray((pmask * 255).astype(np.uint8)).resize((w, h), Image.LANCZOS)
            f = float(cfg["inpaint"]["feather"]) * w / 1024.0
            pm = np.asarray(pm.filter(ImageFilter.GaussianBlur(f / 2))).astype(np.float32)[..., None] / 255.0
            o = np.asarray(orig).astype(np.float32)
            n = np.asarray(out).astype(np.float32)
            out = Image.fromarray((pm * n + (1 - pm) * o + 0.5).astype(np.uint8), "RGBA")
        if not transparent:
            out = out.convert("RGB")
        buf = io.BytesIO()
        out.save(buf, "PNG")
        meta = {"prompt": p, "seed": seed, "seconds": round(secs, 1), "steps": steps, "drawn": f"{gw}x{gh}", "references": [f"{r.width}x{r.height}" for r in refs], "masked": mask is not None}
        log(f"{w}x{h} drawn {gw}x{gh}, {steps} steps, {len(refs)} ref(s){', masked' if mask is not None else ''}{', transparent' if transparent else ''}, seed {seed}: {secs:.0f}s")
        return buf.getvalue(), meta


class Done(list):
    def __init__(self):
        super().__init__()
        self.ready = threading.Event()


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def handler_for(srv):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def reply(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path.rstrip("/") in ("/health", "/v1/health"):
                m = srv.cfg["model"]
                return self.reply(200, {"ok": True, "model": m["name"], "busy": srv.busy})
            self.reply(404, {"error": {"message": "not found"}})

        def do_POST(self):
            srv.busy += 1
            srv.last = time.time()
            try:
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n)
                ctype = self.headers.get("Content-Type", "")
                if self.path.endswith("/images/generations"):
                    req = json.loads(body)
                    files = {}
                elif self.path.endswith("/images/edits"):
                    req, files = parse_multipart(ctype, body)
                else:
                    return self.reply(404, {"error": {"message": "not found"}})
                refs = files.get("image[]", []) + files.get("image", [])
                mask = (files.get("mask") or [None])[0]
                png, meta = srv.submit(
                    prompt=req.get("prompt", ""),
                    size=req.get("size", "1024x1024"),
                    quality=req.get("quality", "high"),
                    background=req.get("background", "auto"),
                    references=refs,
                    mask=mask,
                    seed=req.get("seed"),
                    overrides=json.loads(req["local"]) if isinstance(req.get("local"), str) else req.get("local"),
                )
                self.reply(200, {"created": int(time.time()), "data": [{"b64_json": base64.b64encode(png).decode()}], "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0}, "local": meta})
            except ValueError as e:
                self.reply(400, {"error": {"message": str(e)}})
            except Exception as e:
                traceback.print_exc()
                self.reply(500, {"error": {"message": f"{type(e).__name__}: {e}"}})
            finally:
                srv.busy -= 1
                srv.last = time.time()

    return H


def parse_multipart(ctype, body):
    msg = BytesParser(policy=HTTP).parsebytes(b"Content-Type: " + ctype.encode() + b"\r\n\r\n" + body)
    fields, files = {}, {}
    for part in msg.iter_parts():
        name = part.get_param("name", header="content-disposition")
        data = part.get_payload(decode=True)
        if part.get_filename() is not None:
            files.setdefault(name, []).append(data)
        else:
            fields[name] = data.decode()
    return fields, files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    a = ap.parse_args()
    cfg = load_config(a.config)
    host, port = cfg["listen"].rsplit(":", 1)
    srv = Server(cfg)
    httpd = ThreadingHTTPServer((host, int(port)), handler_for(srv))
    idle = float(cfg["idleMinutes"]) * 60

    def watchdog():
        while True:
            time.sleep(15)
            if idle > 0 and srv.busy == 0 and time.time() - srv.last > idle:
                log(f"idle for {cfg['idleMinutes']} min, exiting")
                os._exit(0)

    threading.Thread(target=watchdog, daemon=True).start()
    log(f"listening on http://{cfg['listen']}")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
