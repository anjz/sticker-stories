# stickeranim — live stickers (frame animations) with the OpenAI Images API

Produces a sticker's live animations — the frog backflips and catches a
fly, the owl blinks and looks around — as sprite sheets the app plays
over the placed sticker, and declares them in the manifest
(`docs/pack-format.md`, "Live animations": every pack ships ten animated
stickers, with small, unhurried motions). Today only the developer
effects gallery plays them (Settings → Developer → Effects gallery →
*Live*); stories cannot trigger them yet. Dev-time only; the API key is
`OPENAI_API_KEY` in `tools/.env`.

```sh
cd tools
go run ./author/stickeranim render  -pack ../packs/forest -dry-run   # prints the prompts
go run ./author/stickeranim render  -pack ../packs/forest [-only frog,owl] [-parallel 3]
go run ./author/stickeranim install -pack ../packs/forest -bump
go run ./packager validate ../packs/forest
```

## anim.json (`tools/author/art/<packID>/anim.json`)

Reads `art.json` next to it for the pack style, the sticker's prompt and
the sticker settings (border, margin, finish), so the frames come out as
the same printed vinyl as the sticker.

- `columns` (4) and `maxSheet` (4096 px): the assembled sheet's layout and
  size cap (frames are downscaled uniformly to fit).
- `animations[]`: `id`, `sticker`, a one-line `description` of the whole
  animation, `base` — what stays still while the character moves ("the
  lily pad", "the ground under its feet") — and:
  - `sheets[]`: one API call each. `columns` × `rows` cells of equal size
    at `size` (`3072x1536` with a 4×2 grid gives 768 px cells), and one
    `frames[]` text per cell: the pose at that moment. Keep a sheet to
    about eight frames; the model keeps the order and the character but
    loses precision beyond that. Say what must *not* be in a frame yet
    (frame 8 first came back with the fly and the tongue because the
    description mentioned them), and say what stays put ("feet planted",
    "tail still"). An optional `hint` adds guidance to that one sheet's
    prompt (a size or framing correction after a bad result) and changes
    only that sheet's fingerprint.
  - `hold[]`: seconds per frame across all sheets (default 1/12 s each).
    The first and last frames are the crossfade with the still sticker.
  - `restFrames[]`: 1-based frames that show the sticker's own pose. They
    take the sticker's real raw art (from `stickerart`'s `out/`), so the
    animation starts and ends on exactly the sticker instead of a
    redrawing of it. They are also what keeps the whole animation at one
    size (see Registration): **give every sheet a rest-pose frame** — the
    usual shape is sheet 1 starting "exactly as in the reference" and the
    last sheet ending "exactly as frame 1".
  - `restFromSticker` (default true): false keeps the generator's own
    drawing in the rest frames instead of the sticker's art (they still
    set the sheets' sizes). The app then dissolves the still sticker into
    the drawing over the first and last frames' holds (give them ~0.45 s),
    so a character redrawn with slightly different proportions changes
    smoothly instead of cutting one frame in; the cost is a brief
    double outline during the dissolve. Forest uses it for the ladybug.
  - `normalize` (default false): rescale every frame so its base keeps
    the first frame's width. Only for a base object that is the widest
    thing at the bottom in every pose — the frog's lily pad, the owl's
    perch. Feet, a curling body or spread wings make the measure jump
    and a frame pop in size; the model's own drift is a percent or two,
    so leaving it off is the safe default.

## What `render` does

1. **Sheets.** Each sheet is one `images/edits` call: the sticker's raw
   art as the reference (downscaled), the previous sheet as a second
   reference so the next one carries on from it, transparent background.
   The prompt lists the frames and the rules (same scale, the base in the
   same place, nothing crossing a cell boundary, no grid lines or numbers).
   About $0.07 per sheet at `high`.
2. **Registration.** The sheet is cut where it is emptiest near each
   nominal grid line (the model places its grid only roughly; a rabbit
   whose feet sit a little past the line is kept whole), each cell is
   cleaned (`stickerimg.Clean`), slivers of a neighbour's art on the cell
   edge are dropped, and the frame is anchored on its *base row*: the
   widest row of alpha in the bottom 45 % of the art (a lily pad, a body
   on its feet). Every frame is placed so that row's centre and the
   art's bottom coincide. **Sheet scale:** the model draws each sheet at
   its own scale (Forest's sheets came out up to 10 % apart, while cells
   within one sheet agree to a percent or two), so every sheet is scaled
   as a whole to match the first one, comparing their rest-pose cells by
   area (the same pose, so the area is a fair measure); the sticker's art
   for the rest frames is sized to the first rest-pose cell the same way.
   A sheet without a rest frame keeps the previous sheet's scale. The log
   prints the per-frame scales. With `normalize` each frame is also
   scaled so the base keeps its width. `<id>.onion.png` overlays every
   frame so the registration can be checked by eye — the base should be
   one crisp outline.
3. **Finish.** Each frame gets the pack's white border and vinyl finish at
   the frames' scale, offline, so playing them costs nothing extra. The
   drop shadow is not baked: the app blurs the whole sheet once into a
   half-resolution shadow sheet and swaps the sticker's shadow per frame.
4. **Output** in `out/anims/`: `<sticker>.<id>.png` (the lossless sheet,
   frames left to right then top to bottom) and `<sticker>.<id>.json`:

   | Key | Meaning |
   |---|---|
   | `sheet` | pack-relative path of the sheet as installed (`.webp`) |
   | `frame` | one frame's size in px |
   | `columns`, `count` | layout |
   | `rest` | the first frame's bordered art within a frame, as fractions (top-left origin) |
   | `stickerBox` | the same art within the sticker image, as fractions |
   | `hold` | seconds per frame |

   The app scales and offsets the frames so `rest` lands on `stickerBox`
   over the placed sticker (`StickerAnimation.swift`).

Everything is fingerprinted like `stickerart`: a prompt change regenerates
that sheet only (sheets are independent, so fixing sheet 1 keeps a good
sheet 2; `-force` redoes all), a timing, finish or `restFrames` change only
re-assembles the kept raws.

## Install

Encodes each sheet into `packs/<id>/anims/<sticker>.<id>.webp` (lossy
WebP at quality 90 with lossless alpha, like every pack image —
`docs/pack-format.md`, "Image formats"; a 16-frame sheet is about 1 MB),
copies its sidecar JSON next to it, adds the sidecar to the sticker's
`animations` in the manifest and validates before writing (rule 12
checks the sidecar strictly). `-bump` increments the pack version.
Encodes are cached by source hash in `out/anims/render.json`.

## Known limits (prototype)

- Frames come from 768 px cells, about the resolution of the 768 px
  sticker itself.
- One 16-frame sheet is ~2848×3232 px: ≈37 MB as a texture (plus a
  quarter of that for its shadow sheet) whatever the file size, since an
  image decodes to RGBA before the GPU can draw it. Fine for one or two
  stickers; a pack full of them would want smaller frames or on-demand
  loading.
- The still sticker's own drawing and the generator's redrawing of it
  differ slightly, which is why `restFrames` exist.
