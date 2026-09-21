# stickerart — pack art with the OpenAI Images API

Produces a pack's stickers and scene planes from prompts, post-processes
them to the pack format (`docs/pack-format.md`), and installs them. Dev-time
only; the API key is `OPENAI_API_KEY` in `tools/.env` (API billing is
separate from a ChatGPT subscription).

```sh
cd tools
go run ./author/stickerart init    -pack ../packs/<id>      # seed art.json from the manifest (new packs)
go run ./author/stickerart render  -pack ../packs/forest -only stylesheet   # approve the look first
go run ./author/stickerart render  -pack ../packs/forest -dry-run
go run ./author/stickerart render  -pack ../packs/forest
go run ./author/stickerart install -pack ../packs/forest -bump
go run ./packager validate ../packs/forest
```

## art.json (`tools/author/art/<packID>/art.json`)

- `style`: the look, inherited by every prompt (medium, line, palette,
  faces, what to avoid).
- `styleSheet`: what the reference sheet shows (a few characters plus a
  scenery swatch on white).
- `stickers[]`: `id`, per-language `name`, and a `prompt` describing the
  subject, pose, expression and facing direction. Keep the whole cast
  facing the same way.
- `scene.background` / `scene.foreground`: the plane behind the stickers
  and the plane in front of them (foreground is transparent everywhere
  except its elements).
- `stickerSize` (1024), `border` (white outline as a fraction of the size,
  0.025) and `margin` (0.03).
- `finish` (optional): the printed-sticker material the post-processing
  bakes in so every pack's stickers feel like the same real vinyl: a
  paper-white die-cut border whose outer rim shades like the cut edge
  (`rimShade` 0.22, `rimWidth` 0.4 of the border), a soft diagonal gloss
  from the upper left (`gloss` 0.11, `glossWidth` 0.16) and a top-lit
  gradient (`lighting` 0.035). The art inside is untouched apart from the
  gloss. All zeros gives a flat white border. The drop shadow is not
  baked in — the app draws it (`StickerNode`), so it can lift with the
  sticker.

## What `render` does

1. **Style sheet** from `style` + `styleSheet` with the generation model.
   Open `out/stylesheet.png` and approve it: every other image uses it as a
   reference, and a new sheet re-renders everything.
2. **Stickers** with the edits model, the style sheet as reference, and a
   transparent background, four at a time. Each result is trimmed to its
   alpha, cleaned (near-opaque alpha made solid, the model's edge tint
   removed), given the baked-in border and finish, padded and resized to
   `stickerSize`; the raw API output is kept as `<id>.raw.png`.
   Generation and finishing are fingerprinted separately: a prompt change
   regenerates a sticker, while a `border`, `margin` or `finish` change
   (or a tool update to the finishing) only re-finishes the kept raw — no
   API call, no cost. `-dry-run` says which.
3. **Scene planes**, one call each, painted directly at the wide 3072×1536
   size with the prompt asking for a complete composition in the central
   4:3 area; the base 2048×1536 rendition is cut from that centre, so the
   two match pixel for pixel with no seam. The **foreground** is painted
   over the finished background (sent downscaled as a reference) with a
   transparent background. Both prompts carry the safe-area directive
   (`docs/pack-format.md`, "Art safe area"): the app crops the top and
   bottom bands on wide screens and lays the sticker tray and the play
   controls over them, so the horizon and everything that matters go in
   the central 70 % of the height, while the bands are still painted —
   quiet, not empty. Your `scene.*` prompts describe the place; the tool
   adds the framing.

Every call's reported token usage is priced at list rates and printed per
image and as a run total, so the real spend is visible. References are
sent downscaled: they only have to convey style, and input image tokens
scale with size.

Everything lands in `out/` (gitignored), keyed by a fingerprint of the
prompts, quality and models, so rerunning only regenerates what changed.
`-only fox,tree`, `-only stylesheet`, `-only scene` narrow a run;
`-quality medium` is cheaper while iterating on prompts.

## Install

Copies `out/stickers/<id>.png` to `packs/<id>/stickers/` and the four
scene planes to `packs/<id>/art/`, updates the manifest's sticker entries
(adding new ids with their names) and art paths, and validates before
writing. Commit the pack afterwards; the PNGs are small enough for plain Git.
