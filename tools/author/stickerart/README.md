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

## What `render` does

1. **Style sheet** from `style` + `styleSheet` with the generation model.
   Open `out/stylesheet.png` and approve it: every other image uses it as a
   reference, and a new sheet re-renders everything.
2. **Stickers** with the edits model, the style sheet as reference, and a
   transparent background, four at a time. Each result is trimmed to its
   alpha, given the baked-in white border, padded and resized to
   `stickerSize`; the raw API output is kept as `<id>.raw.png`.
3. **Scene planes**, one call each, painted directly at the wide 3072×1536
   size with the prompt asking for a complete composition in the central
   4:3 area; the base 2048×1536 rendition is cut from that centre, so the
   two match pixel for pixel with no seam. The **foreground** is painted
   over the finished background (sent downscaled as a reference) with a
   transparent background.

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
