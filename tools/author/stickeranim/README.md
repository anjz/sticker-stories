# stickeranim — live stickers (frame animations) with the OpenAI Images API

Produces every sticker's live animations as sprite sheets the app plays
over the placed sticker, and declares them in the manifest
(`docs/pack-format.md`, "Live animations"): each sticker gets an
**action** — the snail hides in its shell, the frog catches a fly — that
stories cue (`{snail:live}`, or `{snail:live hold}` on its pause pose and
`{snail:live resume}` later), and a **move** — its walk, hop, crawl,
flight or sprout — that plays while a story brings it into the scene.
Small, unhurried, smooth motions. Dev-time only; the API key is
`OPENAI_API_KEY` in `tools/.env`. The developer gallery plays any
animation (Settings → Developer → Effects gallery → *Live*, with
*hold*/*resume* buttons; or launch with `-effectsGallery -liveDemo
snail.hide`).

```sh
cd tools
go run ./author/stickeranim render  -pack ../packs/forest -dry-run   # prints the prompts
go run ./author/stickeranim render  -pack ../packs/forest [-only frog,owl] [-parallel 3]
go run ./author/stickeranim install -pack ../packs/forest [-only frog,owl] -bump
go run ./packager validate ../packs/forest
```

## anim.json (`tools/author/art/<packID>/anim.json`)

Reads `art.json` next to it for the pack style, the sticker's prompt and
the sticker settings (border, margin, finish), so the frames come out as
the same printed vinyl as the sticker. A sticker whose prop `stickerart`
removed (`prop` in art.json) is drawn from its art without it
(`<id>.noprop.png`), and the prompt says the prop is gone.

- `columns` (6) and `maxSheet` (4096 px): the assembled sheet's layout and
  size cap (frames are downscaled uniformly to fit). `stickerPx` (512):
  the frames are drawn at the scale of a sticker this big — plenty on
  screen, and a sheet's texture memory goes with its square (a 24-frame
  action of ~520 px frames is ~23 MB decoded).
- `animations[]`: `id`, `sticker`, `kind` (`action`, the default, or
  `move`; one move per sticker), a one-line `description` of the whole
  animation (it also goes into the pack sidecar, where story authors read
  what the animation shows; add `story` with a plain version when the
  description carries drawing instructions), `base` — what stays put
  while the character moves ("the swirly shell", "its feet") — and:
  - `sheets[]`: one API call each. `columns` × `rows` cells of equal size
    at `size` — **4×3 at `3072x2304`** (twelve 768 px cells) is the
    working shape — and one `frames[]` text per cell: the pose at that
    moment. The model keeps order and character well within a sheet of
    twelve. Say what must *not* be in a frame yet (a fly that has not
    arrived), and what stays put. **Every sheet after the first starts
    with exactly the pose the one before ends with** ("exactly as the
    last frame of the previous sheet"): the sheets are scaled to each
    other on that shared pose. An optional `hint` adds guidance to that
    one sheet's prompt (a correction after a bad result — the bird that
    turned to face the viewer) and changes only that sheet's
    fingerprint.
  - `hold[]`: seconds per frame across all sheets (default 1/12 s each).
    **Smooth is about 10–12 frames a second**: 0.07–0.1 s per frame while
    something moves, each frame a small step on from the one before, and
    longer holds only on poses the eye should rest on. An action is
    typically 24 frames over 2–4 s; a walk cycle 8 frames at ~0.08 s.
    An action's first and last frames are the dissolve from and back to
    the still sticker (give them ~0.3 s).
  - `restFrames[]`: 1-based frames that show the sticker's own pose. They
    take the sticker's real raw art (from `stickerart`'s `out/`), so the
    animation starts and ends on exactly the sticker, and they pin the
    registration (below). An action's are its first and last frames; a
    move's are frame 1 (the anchor onto the sticker; never played) and
    its last (where it settles).
  - `pause` (actions): `{"frame": 12, "shows": "the snail hidden inside
    its shell"}` — the 1-based frame the action can stop on and stay,
    and what it shows, for story authors. Pick a pose worth staying in
    (hidden, asleep, watching, singing a long note) and end sheet 1 on it,
    so sheet 2 starts from it. Most actions have one.
  - `loop`, `facing`, `stride`, `hops` (moves): `loop` is the 1-based run
    of frames repeated while the character travels (frames 2–9 of a
    12-frame sheet; frames 10–12 bring it to rest); `facing` the way the
    frames travel (`left`/`right`, the way the sticker faces — the app
    mirrors a visitor that has to come the other way); `stride` how far
    one loop carries it in sticker widths (the app slides it at that
    pace); `hops` that the loop is a hop drawn in place (the app adds the
    arc, one per loop). A move without `loop` (a flower's sprout) plays
    once: frame 1 is the rest pose (the anchor), frames 2… grow to it.
    The prompt asks for moves drawn in place, as on a treadmill, and
    small in their cells so a stretched leap stays inside.
  - `register`: how frames are laid on each other — `feet` (the default:
    each frame matched on the one before, its bottom kept on one ground
    line), `body` (matched both ways: a flight, or the snail whose body
    vanishes into its shell) or `base` (the old base-row anchor).
  - `restFromSticker` (default true): false keeps the generator's own
    drawing in the rest frames instead of the sticker's art.
  - `normalize` (default false, `base` only): rescale every frame so its
    base keeps the first frame's width.

## What `render` does

1. **Sheets.** Each sheet is one `images/edits` call: the sticker's raw
   art as the reference (downscaled), the previous sheet as a second
   reference so the next one carries on from it, transparent background.
   The prompt lists the frames and the rules (same scale, the base in the
   same place, nothing crossing a cell boundary, no grid lines or numbers).
   About $0.07 per sheet at `high`.
2. **Registration.** The sheet is cut where it is emptiest near each
   nominal grid line (the model places its grid only roughly), each cell
   is cleaned (`stickerimg.Clean`) and slivers of a neighbour's art on
   the cell edge are dropped. **Sizes** come only from pairs of frames
   that show the same pose, because matching two different poses favours
   the bigger one: the sticker's art is sized to the first generated
   rest cell, each later sheet is scaled so its first frame matches the
   frame before it (`SheetsContinue`), and a sheet that ends on the rest
   pose is brought back to the sticker's size gradually from where it
   began (the model shrank the snail's shell 15 % over one sheet).
   **Places** come from matching each frame on the one before
   (`stickerimg.Align`, a shift only), with the bottom kept on one ground
   line (`feet`) or not (`body`); a move's loop is closed (the shift from
   its last frame back into its first is spread over the loop) and every
   later rest frame — the sticker's art again — is pinned onto frame 1,
   the chain's error spread over the frames before it, so nothing pops
   at the end. `<id>.onion.png` overlays every frame to check it by eye.
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
   | `kind`, `pause`, `loop`, `facing`, `stride`, `hops` | as in anim.json (0-based frames) |

   The app scales and offsets the frames so `rest` lands on `stickerBox`
   over the placed sticker (`StickerAnimation.swift`).

Everything is fingerprinted like `stickerart`: a prompt change regenerates
that sheet only (sheets are independent, so fixing sheet 1 keeps a good
sheet 2; `-force` redoes all), a timing, finish or `restFrames` change only
re-assembles the kept raws.

## Install

Encodes each sheet into `packs/<id>/anims/<sticker>.<id>.webp` (lossy
WebP at quality 90 with lossless alpha, like every pack image —
`docs/pack-format.md`, "Image formats"; a 24-frame action is about 1 MB,
a move about 0.45 MB), copies its sidecar next to it, declares exactly
the animations anim.json lists in the stickers' `animations` (one taken
out of anim.json leaves the pack, sheet and sidecar — stories that still
cue it fail validation until they are updated) and validates before
writing. `-only` copies in just those animations or stickers (the rest
keep what the pack has); `-bump` increments the pack version. Encodes
are cached by source hash in `out/anims/render.json`.

## Known limits

- The generator redraws the character: its frames are the same design but
  not the sticker's exact drawing (the frog came out a little wider).
  The rest frames and the app's dissolve hide the change at the start
  and end; ask for "exactly the reference's proportions" in a `hint` if
  one drifts too far.
- Frames come from 768 px cells, drawn out at `stickerPx`.
- A sheet decodes to width × height × 4 bytes whatever its file size; a
  story loads only the actions it cues and the moves of the stickers it
  brings in.
