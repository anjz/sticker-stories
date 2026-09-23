# Pack format

A **pack** is a versioned, self-contained directory of assets. It is the single
contract between the content pipeline (`tools/`, Go) and the app (Swift). Both
sides validate independently: the Go `packager` refuses to assemble an invalid
pack, and the Swift `PackLoader` refuses to load one.

Packs are **multilingual**: every user-facing string and every narration file
exists once per supported language. A pack declares its languages; the app
picks the best match for the device (see "Language resolution" below).

## Directory layout

```
<packID>/
  manifest.json
  art/
    background.webp       # full-canvas back plane (sky, hills…)
    foreground.webp       # full-canvas front plane (trees, mushrooms…), alpha where see-through
    background-wide.webp  # optional: wider rendition for wide windows (iPhone), same height
    foreground-wide.webp  # optional: its front plane; declared together with the above
  stickers/
    <stickerID>.webp      # sticker art, alpha background, white border baked in
  anims/
    <stickerID>.<animID>.webp  # live animation: sprite sheet ("Live animations" below)
    <stickerID>.<animID>.json  # its sidecar, declared in stickers[].animations
  audio/
    <lang>/<storyID>.m4a           # pre-rendered narration, AAC, one folder per language
    <lang>/<storyID>.effects.json  # optional effect triggers (sticker + canvas) for that narration
```

The `audio/<lang>/…` layout is a convention, not a rule — audio paths are
whatever the manifest declares, but keep the convention so packs stay
navigable.

### Image formats

Every image is a **PNG or a WebP** (rule 11) — the two formats the app
decodes natively through ImageIO, so nothing else may appear in a pack.
Ship **WebP, lossy at quality 90 with a lossless alpha channel**: on
painted art the colour error is below what the eye picks up while files
come out ~85 % smaller than PNG, and the lossless alpha keeps a sticker's
die-cut edge pixel-exact. `stickerart install` and `stickeranim install`
produce exactly that from the lossless PNGs kept in their `out/`; PNG
remains valid for placeholders and hand-made packs. Measured on Forest:
42 MB of PNG → 6 MB of WebP.

Sizes: stickers are **768×768** — a sticker is drawn at 16 % of the world
height and pinches to at most 2×, so even a 13" iPad shows one at ~660 px
and 1024 was oversampled. Scene planes stay at their full size
(2048×1536 base, 3072×1536 wide): they are scaled *up* to cover a 13"
iPad's screen, so there is nothing to give away there.

Note that a smaller file is not a smaller texture: whatever the format,
an image decodes to width × height × 4 bytes of RGBA before the GPU can
draw it. Formats decide download size; pixel counts decide memory.

### Art safe area

`background` and `foreground` share one aspect ratio, designed for iPad
(Forest placeholder: 4:3, 2048×1536); their frame is the coordinate system
stickers are saved in. The app scales the art to cover the window and
never letterboxes:

- **Windows wider than the art** are **centre-cropped top and bottom**,
  never panned. On an iPad in landscape that is a few percent per edge.
- **Windows narrower than the art** (portrait, Split View) show the full
  height and let the child pan sideways over the rest.
- **Wide art** (`backgroundWide` / `foregroundWide`) is how a pack avoids a
  heavy crop on tall iPhones: paint the same scene wider (2:1 is a good
  target: on an iPhone that leaves ~4 % cropped per edge instead of ~20 %)
  with the base composition centred, and export the centre as the base art.
  The app picks the rendition to draw so that **a landscape window never
  pans**: among renditions no wider than the window it takes the one that
  crops least, as long as the crop stays within 30 % of the height; only a
  window narrower than every rendition (portrait, Split View) pans, using
  the rendition that pans least. In practice: iPads keep the base art
  (≤ 7 % cropped), 19.5:9 phones use the wide art (~8 % cropped), 16:9
  phones use the base art (25 % cropped). Stickers always use the base
  frame, so the same arrangement appears on every device (positions in the
  wide margins fall outside 0…1 and that is fine).
- Keep skies, ground lines and anything the child needs inside the central
  **~70 %** of the art's height: that is what survives the largest crop the
  app will make before it switches to a wider rendition, and the sticker
  tray (top) and the play controls (bottom) sit over those bands anyway.
  Paint the bands, but keep them quiet — nothing the picture needs. A
  sticker placed in a top/bottom band while in portrait is hidden in
  landscape until they rotate back.
- **Outdoors packs paint no weather and no sky lights.** The canvas effects
  (`docs/effects.md`) draw sunshine, rain, fog, a rainbow and night with a
  moon and stars over the scene, so the art itself stays plain daylight:
  soft even light, a clear or lightly clouded sky, **never a sun, a moon,
  stars, sun rays, a rainbow, rain or mist** — a painted moon would show
  twice the moment `night` plays. `stickerart` adds this directive to the
  scene prompts of every outdoors pack.
- **Space packs paint no moving sky.** The art is a calm, dark starry sky
  with distant, unlit stars and whatever scenery the pack needs (planets,
  moons, a rocket pad), but **never shooting stars, comets, a glowing
  nebula, a bright planet rim on the horizon, a sun flare or speed
  streaks** — the space canvas effects draw those.
- **Underwater packs paint no light in the water.** The art is clear,
  evenly lit water, the sea floor and the scenery, but **never sun rays
  from the surface, rippling light patterns, bubbles, glowing specks,
  drifting particles or clouds of sand** — the underwater canvas effects
  draw those.

## manifest.json — schema v2

```json
{
  "schemaVersion": 2,
  "id": "forest",
  "version": 2,
  "languages": ["en-US", "es-ES"],
  "displayName": { "en-US": "Forest Friends", "es-ES": "Amigos del Bosque" },
  "theme": "forest",
  "setting": "outdoors",
  "background": "art/background.webp",
  "foreground": "art/foreground.webp",
  "backgroundWide": "art/background-wide.webp",
  "foregroundWide": "art/foreground-wide.webp",
  "stickers": [
    {
      "id": "mushroom",
      "name": { "en-US": "Mushroom", "es-ES": "Seta" },
      "image": "stickers/mushroom.webp"
    },
    {
      "id": "frog",
      "name": { "en-US": "Frog", "es-ES": "Rana" },
      "image": "stickers/frog.webp",
      "animations": ["anims/frog.backflip-fly.json"]
    }
  ],
  "stories": [
    {
      "id": "shy-mushroom",
      "requiredStickers": ["mushroom"],
      "optionalStickers": ["fox", "tree"],
      "weight": 1.0,
      "tags": ["gentle"],
      "localizations": {
        "en-US": {
          "title": "The Shy Mushroom",
          "text": "Once upon a time…",
          "audio": "audio/en-US/shy-mushroom.m4a",
          "effects": "audio/en-US/shy-mushroom.effects.json"
        },
        "es-ES": {
          "title": "La seta tímida",
          "text": "Érase una vez…",
          "audio": "audio/es-ES/shy-mushroom.m4a"
        }
      }
    }
  ]
}
```

### Field reference

| Field | Type | Rules |
|---|---|---|
| `schemaVersion` | int | Must be a version the reader supports (currently `2`). Readers must reject unknown versions. |
| `id` | string | Pack identifier: lowercase `a-z0-9-`, unique across the catalogue. Also the IAP product suffix (`com.anj.stickerstories.pack.<id>`). |
| `version` | int | Content revision of the pack, ≥1. Bump on any asset/story change. |
| `languages` | [string] | BCP-47 tags (`xx` or `xx-YY`, e.g. `en-US`), non-empty, no duplicates. **The first entry is the pack's fallback language.** |
| `displayName` | {lang: string} | Human-readable name per language, shown to parents. Keep it within **30 characters** in every language (guidance, not validated): a purchasable pack's name is also its in-app purchase display name in App Store Connect, which caps it there (`docs/commerce.md`, "Product copy"). |
| `description` | {lang: string} | **Optional.** One line per language describing the pack, shown to parents under its name in the store. When present it must cover every declared language (rule 4). Keep it within **45 characters** (guidance, not validated) — for a purchasable pack it should match the in-app purchase description, which App Store Connect caps there. Never counts or promises ("25 stickers", "more coming"). |
| `theme` | string | Free-form theme tag; future prompt context for generated stories. |
| `setting` | string | **Optional**, default `none`. Where the scene takes place: `outdoors`, `indoors`, `space`, `underwater` or `none`. Decides which canvas effects (`docs/effects.md`, "Canvas effects") the pack's stories may use: each effect lists the settings it suits, and `none` allows no canvas effects. Story tooling reads it when authoring. |
| `background` / `foreground` | string | Pack-relative paths to PNG or WebP files that must exist ("Image formats" above). Their frame is the sticker coordinate system ("Art safe area" below). |
| `backgroundWide` / `foregroundWide` | string | **Optional, together or not at all.** Wider renditions (e.g. 2:1) with the **same pixel height** as the base art and the base art **centred** inside. The app draws whichever rendition lets a landscape window avoid panning with the least crop (tall phones get the wide one; iPads keep the base one). Files must exist. |
| `cover` | string | **Optional.** Pack-relative path to the pack's cover art (PNG or WebP, must exist): what its tile shows in the main menu and the store. Made with `uiart` (`tools/author/uiart`); without one the app composes the tile from the background and a few stickers. No text in it — the app writes the name. |
| `stickers[].id` | string | Lowercase `a-z0-9-`, unique within the pack. |
| `stickers[].name` | {lang: string} | Display/accessibility name per language. |
| `stickers[].image` | string | Pack-relative path to a PNG or WebP file; must exist. |
| `stickers[].animations` | [string] | **Optional**, default none. Pack-relative paths to live-animation sidecars (`.json`, "Live animations" below); each must exist and validate. |
| `stories[].id` | string | Unique within the pack. |
| `stories[].requiredStickers` | [string] | The stickers the story is about: it is a candidate when at most one of them is missing from the canvas (and at least one is present), and preferred when all are. Empty ⇒ fallback story. Every ID must be declared in `stickers`. |
| `stories[].optionalStickers` | [string] | Sticker IDs that raise the match score when present. Declared in `stickers`; no overlap with `requiredStickers`. |
| `stories[].weight` | number | Base selection weight, > 0. Default 1.0. |
| `stories[].tags` | [string] | Free-form variety tags (e.g. `gentle`, `funny`). |
| `stories[].localizations` | {lang: object} | One block per language (see below). |
| `…localizations[].title` | string | Short story title in that language (parent-facing; not read to the child). |
| `…localizations[].text` | string | Full story text in that language. **Required** — the portable representation for future TTS/LLM narrators. |
| `…localizations[].audio` | string | Pack-relative path to that language's pre-rendered narration; must exist. |
| `…localizations[].effects` | string | **Optional.** Pack-relative path to that language's effect trigger sidecar — sticker and canvas effects (`docs/effects.md`); must exist and pass strict validation. Omit for no effects. |

### Validation rules (enforced by BOTH the Go packager and the Swift decoder)

1. `schemaVersion` supported (currently 2).
2. `id`s well-formed; sticker IDs unique; story IDs unique.
3. `languages` non-empty, well-formed BCP-47 (`^[a-z]{2,3}(-[A-Z]{2})?$`), no
   duplicates.
4. **Language coverage is exact**: every localized map (`displayName`,
   `description` when present, each `stickers[].name`, each
   `stories[].localizations`) contains a value for
   every declared language and none for undeclared ones. Partial translations
   are a validation error, not a runtime fallback.
5. Every referenced file (`background`, `foreground`, `cover`, sticker images, every
   localization's audio and effects sidecar) exists inside the pack. No path
   may escape the pack (no `..`, no absolute paths).
6. Story sticker references are declared; `requiredStickers` and
   `optionalStickers` are disjoint.
7. **At least one fallback story** (`requiredStickers` empty) — play must
   never fail regardless of canvas contents.
8. `weight > 0`, `version ≥ 1`; every `displayName`/`name`/`title`/`text`
   value non-empty; `setting`, when present, is one of `outdoors`,
   `indoors`, `space`, `underwater`, `none`.
9. Every declared effects sidecar is valid per `docs/effects.md` ("Trigger
   file"): the packager validates it **strictly** (unknown effect names,
   unknown keys, out-of-range numbers, undeclared stickers and canvas
   effects that do not suit the pack's `setting` are errors); the app
   decodes it **leniently** (skip / clamp / log) so a pack authored against
   a newer library still plays with fewer effects.
10. `backgroundWide` and `foregroundWide` are declared together or not at
    all, and exist when declared. Their pixel dimensions are the pack
    author's responsibility (same height as the base art, base centred).
11. Every image path (`background`, `foreground`, the wide planes, `cover`,
    every `stickers[].image`) ends in `.png` or `.webp` ("Image formats").
12. Every `stickers[].animations` entry is a `.json` file inside the pack.
    The packager validates the sidecar **strictly** (unknown keys, a
    `sticker` other than the declaring one, an empty `description`, an
    `id` the sticker already uses, a missing or non-image sheet,
    a `hold` list that does not match `count`, holds outside 0.02–5 s,
    boxes outside the unit square are errors); the app checks the file
    exists and reads it **leniently** (an undecodable sidecar is skipped
    with a log, never fatal).

## Live animations

A sticker can carry animations: short frame sequences that make it come
alive for a moment — the frog backflips and catches a fly, the owl blinks
and turns its head. **Every pack ships ten animated stickers** (the
authoring target, like the story count; not a validation rule), chosen
among the characters and given small, unhurried motions: a yawn, a
blink, a nibble, a peek. Nothing fast and nothing that travels — a
sticker stays where the child put it, and gentle movement is what reads
well at a few frames per second on a die-cut sticker.

Each animation is a sprite sheet plus a sidecar, made by
`tools/author/stickeranim` and declared in `stickers[].animations`:

| Key | Meaning |
|---|---|
| `id`, `sticker` | the animation's id (unique per sticker) and the sticker it belongs to (must match the declaring sticker) |
| `description` | one plain sentence saying what the animation shows ("the bear cub yawns and stretches its arms up, rubs its eyes…"), for story authors; required, ignored by the app |
| `sheet` | pack-relative path of the sheet (PNG or WebP): `columns` frames per row, `count` frames read left to right then top to bottom, each `frame.width` × `frame.height` px |
| `rest` | the first frame's bordered art within a frame, as fractions of the frame (top-left origin) |
| `stickerBox` | the same art within the sticker image, as fractions of the image |
| `hold` | seconds each frame shows, one entry per frame (0.02–5) |

The frames are registered on the part that stays still (a lily pad, the
feet, a branch), carry the same border and finish as the sticker, and the
first and last frames are the sticker's own art, so the app can crossfade
from the still sticker into the frames and back. The app scales and
offsets the frames so `rest` lands exactly on `stickerBox` over the
placed sticker, and derives the frames' drop shadow from the sheet.

Stories play them: the authoring cue `{bear:live}` becomes a trigger
`{ "at", "sticker": "bear", "animation": "yawn" }` in the story's effects
sidecar (`docs/effects.md`, "Live animations"), which the packager checks
against the animations the sticker declares. The developer effects gallery
plays any of them. A sheet decodes to width × height × 4 bytes of texture
whatever its file size — keep that in mind before adding frames; a story
loads only the sheets it triggers.

## Language resolution (app behaviour)

`LanguageResolver` in StickerStoriesKit matches the device's preferred
languages (`Locale.preferredLanguages`) against the pack's `languages`:

1. exact tag match, case-insensitive (`es-ES` device → `es-ES` pack);
2. else primary-subtag match (`es-MX` device → `es-ES` pack);
3. else the pack's **first declared language**.

The resolved language selects `displayName`, sticker names, and each story's
`localizations` block (title, text, audio) — one language per pack per launch.
App UI strings localize independently via the String Catalog; both follow the
same device preference.

## Versioning rules

- `schemaVersion` changes only for **structural** changes to the manifest.
  Additive optional fields do not bump it; renames/removals/semantic changes
  do. v1 → v2 (2026-07): localization restructure — `languages` added;
  `displayName`, `stickers[].name` became per-language maps; story
  `title`/`text`/`audio` moved into `localizations`. v1 packs are not
  supported (none shipped). 2026-09: optional `localizations[].effects`
  and optional `backgroundWide` / `foregroundWide` added (additive, no
  bump); optional `setting` added (additive, defaults to `none`, no
  bump); `setting` values `space` and `underwater` added (no pack has
  shipped, so no bump); optional `description` added (additive, no bump);
  optional `cover` added (additive, no bump).
- Any schema change must update this document, the Go validator
  (`tools/internal/manifest`), and the Swift decoder in the **same commit**.
- `version` (pack content revision) is bumped whenever any asset or story in a
  published pack changes; the app treats a higher version of an installed pack
  as a replacement.

## Future: per-language delivery (parked)

Packs currently ship with all languages included. If pack size ever makes
that impractical, keep **one download URL per pack** and add a `lang=` query
parameter (e.g. `…/forest.pack?lang=es-ES`) so the server can serve a
language subset — no per-language URL bookkeeping in the manifest.
