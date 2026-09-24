# uiart — the app's own art, as alternatives to pick from

Makes the art that belongs to the app rather than to a pack — the main
screen's **background**, the **"Sticker Stories" title**, the **store
tile** (the menu's More stories card), every pack's **cover** and the
**hand** of the canvas's gesture hints — as a
few alternatives each, and installs the one you choose.
Dev-time only; needs `OPENAI_API_KEY` in `tools/.env`.

```sh
cd tools
go run ./author/uiart render                    # 4 candidates of everything missing
go run ./author/uiart render -only title -more 2   # two more titles, keeping the others
go run ./author/uiart render -only cover:forest -fresh  # archive the old covers, start over
go run ./author/uiart pick background 3
go run ./author/uiart pick title 2
go run ./author/uiart pick store 4
go run ./author/uiart pick cover:forest 1
```

## The prompts: `author/art/app/ui.json`

- `style` is prepended to every prompt, so the pieces belong together
  (keep it close to the packs' style).
- `candidates` (default 4) is how many alternatives `render` makes.
- `background` / `title` / `store` / `cover`: a `size` and a `prompt`
  each. The title also takes the exact `text` to letter; covers take extra
  direction per pack under `cover.packs.<packID>`.

The tool adds the rules that must always hold: no text in the background
or covers (the app writes pack names), the exact spelling and a
transparent background for the title, no borders.

## What `render` does

- **Background** and **title**: text-to-image (`gpt-image-2.5-flare`); the
  title on a transparent background.
- **Covers**: one per pack in `../packs`, drawn with the pack's own art as
  references (`gpt-image-2.5-sunburst`): its style sheet (the characters
  and the look) and its scene, both from `author/art/<pack>/out/`, so the
  cover belongs to the pack. The prompt names the pack and its manifest
  `description`.
- **Store tile**: drawn with up to 4 of the packs' finished stickers
  (`author/art/<pack>/out/stickers/`, taken in turn from every pack) as
  references, so the tile's stickers share the packs' style.
- Candidates land in `author/art/app/out/<asset>/<n>.png` (covers in
  `out/cover-<pack>/`), with **`choices.png`**: all of them side by side,
  numbered left to right, top to bottom; transparent art on a checkerboard.
- Existing candidates are kept: `render` only fills the missing numbers up
  to `-count`. `-more N` adds N after the last one (after a prompt tweak,
  say); `-fresh` moves the current set into `old/<timestamp>/` first.
- `-dry-run` lists what would be generated; `-parallel` (default 4) images
  run at once. About $0.04–0.08 per image at `high` (a store tile, with
  its sticker references, about $0.10), so a full round is about a dollar.

## What `pick` installs

| Asset | Goes to | Notes |
|---|---|---|
| `background` | `app/StickerStories/Art/menu-background.webp` | Bundled with the app. |
| `title` | `app/StickerStories/Art/menu-title.webp` | Trimmed to the lettering (with a small margin), alpha kept. |
| `store` | `app/StickerStories/Art/menu-store.webp` | The More stories card; without it the card keeps its gradient and gift. |
| `hand` | `app/StickerStories/Art/hint-hand.webp` | The pointing hand of the canvas's gesture hints (`CanvasHintDemo`). Trimmed to the art with no margin: the app takes the topmost point as the fingertip, so the finger must point straight up. |
| `cover:<pack>` | `packs/<pack>/art/cover.webp` | Sets the manifest's `cover` (`docs/pack-format.md`), bumps the pack version, validates. |

Everything is written as WebP (lossy q90, lossless alpha), like the packs'
art. Picking again replaces the previous choice.

## Sizes and cropping

- The background is wide (3072×1536) and gets cropped to every screen
  shape, from a portrait iPad to a 2.2:1 phone; the prompt keeps the middle
  calm (the pack cards sit there) and the top centre open (the title).
- Covers are square (1024×1024), with the characters in the middle: the
  menu shows them nearly square, the store wider, both cropping the edges.
