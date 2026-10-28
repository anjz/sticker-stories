# localimage — the art tools on a local model

`stickerart`, `stickerrig` and `uiart` draw with the OpenAI Images API.
With `-local` they draw on this Mac instead, with an open image model, at
no cost per image. Everything else stays the same: the same art.json and
rig files, prompts, fingerprints, post-processing and outputs.

```sh
cd tools
go run ./author/stickerart  render -pack ../packs/forest -only owl -options 4 -local
go run ./author/stickerart  render -pack ../packs/forest -only owl -local
go run ./author/uiart       render -only title -local
```

The first `-local` run starts the server (`server.py`, through `uv`, which
installs its Python packages on first use) and waits for it. The server
stays up for the next runs with the model loaded, and exits after
`idleMinutes` without a request. Its log is
`$TMPDIR/stickerstories-localimage.log`; `pkill -f "server.py --config"`
stops it. Needs `uv` (`brew install uv`) and Apple silicon. With the
default 8-bit model it holds about 10 GB.

## config.json

| Key | Meaning |
|---|---|
| `listen` | the server's address (`127.0.0.1:7865`) |
| `idleMinutes` | exit after this long without a request (0: never) |
| `cacheLimitGB` | MLX's buffer cache. Uncapped, it grows to twice the weights and pushes the rest of the Mac into swap |
| `model.name` | `flux2-klein-4b` (or `flux2-klein-9b`) |
| `model.path` | a local diffusers folder (`~` is expanded); empty downloads from Hugging Face |
| `model.quantize` | `8` (default: same pictures as bf16, 9.9 GB instead of 16 GB), `4`, or `null` for bf16 |
| `model.maxTextTokens` | prompt tokens the text encoder reads (512) |
| `model.loras`, `model.loraScales` | optional LoRA files, for a pack style trained later |
| `qualities.<q>` | what `-quality <q>` means locally: `steps`, `maxPixels` (the drawing's pixel budget; the result is resized to the size asked for), `refMaxPixels` (references are resized to this), `inpaintSteps` |
| `references.maxPixels` | default reference size |
| `matte` | the plain `background` colour transparent images are drawn on, and the colour `tolerance` of the cut-out |
| `inpaint` | `feather` of the mask's edge (px at 1024), `minSteps`, and `reference`: what the model sees of the area it repaints (below) |

Every setting that changes the pictures goes into the fingerprint, as the
model's ID `local:<name>:<hash>`. That includes the quality's profile, the
matte, inpainting and the model options; it excludes `path` and
`listen`. Changing them redraws what they drew. The OpenAI model is part of
the fingerprints too, so **switching to `-local` counts as a new model**:
everything a run would draw shows as changed. Use `-dry-run` and `-only`
to add local art to a pack drawn by OpenAI without redrawing the rest.

## What the server does that the hosted model does itself

The server speaks the part of the Images API the tools use
(`/v1/images/generations` and `/v1/images/edits`, multipart with
`image[]` and `mask`), on mflux's MLX implementation of FLUX.2 with its
own sampling loop:

- **References** are encoded at `refMaxPixels`, not at the output size as
  mflux does: a 768 px style sheet would otherwise cost as much as the
  drawing.
- **Transparent backgrounds**: the model draws on plain white, and the
  subject is cut out with Apple Vision's subject lifting (on-device,
  0.2 s). A flood fill from the edges adds back anything Vision dropped:
  a fern beside a stump. The white is then
  decontaminated from the edges. The tools' "fully transparent background"
  becomes "plain flat white background" in the prompt; FLUX would draw a
  checkerboard otherwise.
- **Masks** (transparent = repaint): inpainting by latent blending. Every
  step resets the kept area to the original at that noise level, and the
  result is laid over the original inside the feathered mask only. What
  the model sees of the repainted area is a hint the tools send
  (`maskReference`): `blank` for a prop to remove, since shown the branch
  it draws it again; `original` for a face, which keeps the face disc's
  colour. Scene edits and outpainting use the config's default (`blank`).
- **Prompts**: "the first/second attached image" becomes "image 1/2", the
  names FLUX.2 knows references by.

The tools send these hints in a `local` field that only the local client
sends (`openai.ImageRequest.Hints`). A request's `local` field can override
any quality setting, which is handy for experiments:
`{"steps": 8, "maxPixels": 1638400, "drawLarger": true}`.

## The Owl, measured (M5 Pro, 48 GB, 8-bit)

| Step | Time |
|---|---|
| a sticker, 1024 px, style sheet as reference | ~23 s |
| prop removal / a face (masked, 1024 px) | ~30 s |
| an animation frame (768 px, 2 references) | ~17 s (~11 s with one) |
| the whole Owl: 4 candidates, prop, 4 faces, 2 animations | ~14 min |

Settings tried, with what was kept:

- **4 steps.** 8 steps is no better (the model is distilled for 4) and
  sometimes adds a white outline of its own.
- **1 MP for a sticker.** 1.6 MP costs +50 % for nothing visible.
- **8-bit.** Same pictures as bf16.
- **The tools' prompts as they are.** Putting the subject first changes
  nothing; the style sheet as reference matters a lot.

Prompt lessons for this model:

- Say colours outright: "a tawny owl" came out olive five times in six
  because of the style's "mossy greens".
- It follows concrete words, not negations.

Face and prop boxes (art.json) are measured on each drawing, so re-measure
them for a redrawn sticker.

## Another model later

`server.py` has one backend class (`Flux2KleinBackend`): load, encode
text and images, and a sampling loop. Klein 9B is a config change
(`model.name`; mind its non-commercial licence, while 4B is Apache-2.0).
Another family (Qwen-Image-Edit, Z-Image) needs a class like it with the
same `generate()`. Everything around it stays: sizes, the matte,
inpainting by blending, the API and the tools.
