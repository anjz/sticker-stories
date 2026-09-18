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
    background.png        # full-canvas back plane (sky, hills…)
    foreground.png        # full-canvas front plane (trees, mushrooms…), alpha where see-through
  stickers/
    <stickerID>.png       # sticker art, alpha background, white border baked in
  audio/
    <lang>/<storyID>.m4a           # pre-rendered narration, AAC, one folder per language
    <lang>/<storyID>.effects.json  # optional sticker-effect triggers for that narration
```

The `audio/<lang>/…` layout is a convention, not a rule — audio paths are
whatever the manifest declares, but keep the convention so packs stay
navigable.

### Art safe area

`background` and `foreground` share one aspect ratio (Forest: 4:3,
2048×1536) and define the canvas "world". The app scales the art to cover
the window and never letterboxes:

- **Wider windows than the art** (every full-screen landscape case) are
  **centre-cropped top and bottom**, never panned. On an iPad in landscape
  about 3–4 % is cut from each edge; on a tall iPhone roughly **20 % from the
  top and 20 % from the bottom**. Keep skies, ground lines and anything
  the child needs to see inside the central ~60 % of the art's height.
- **Narrower windows than the art** (portrait, Split View) show the full
  height and let the child pan sideways over the rest.
- Stickers are placed in art coordinates, so the child's arrangement is the
  same everywhere; a sticker placed in a top/bottom band in portrait is
  hidden in landscape until they rotate back.

## manifest.json — schema v2

```json
{
  "schemaVersion": 2,
  "id": "forest",
  "version": 2,
  "languages": ["en-US", "es-ES"],
  "displayName": { "en-US": "Forest Friends", "es-ES": "Amigos del Bosque" },
  "theme": "forest",
  "background": "art/background.png",
  "foreground": "art/foreground.png",
  "stickers": [
    {
      "id": "mushroom",
      "name": { "en-US": "Mushroom", "es-ES": "Seta" },
      "image": "stickers/mushroom.png"
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
| `displayName` | {lang: string} | Human-readable name per language, shown to parents. |
| `theme` | string | Free-form theme tag; future prompt context for generated stories. |
| `background` / `foreground` | string | Pack-relative paths; files must exist. |
| `stickers[].id` | string | Lowercase `a-z0-9-`, unique within the pack. |
| `stickers[].name` | {lang: string} | Display/accessibility name per language. |
| `stickers[].image` | string | Pack-relative path; must exist. |
| `stories[].id` | string | Unique within the pack. |
| `stories[].requiredStickers` | [string] | Sticker IDs that must all be on the canvas for the story to be a candidate. Empty ⇒ fallback story. Every ID must be declared in `stickers`. |
| `stories[].optionalStickers` | [string] | Sticker IDs that raise the match score when present. Declared in `stickers`; no overlap with `requiredStickers`. |
| `stories[].weight` | number | Base selection weight, > 0. Default 1.0. |
| `stories[].tags` | [string] | Free-form variety tags (e.g. `gentle`, `funny`). |
| `stories[].localizations` | {lang: object} | One block per language (see below). |
| `…localizations[].title` | string | Short story title in that language (parent-facing; not read to the child). |
| `…localizations[].text` | string | Full story text in that language. **Required** — the portable representation for future TTS/LLM narrators. |
| `…localizations[].audio` | string | Pack-relative path to that language's pre-rendered narration; must exist. |
| `…localizations[].effects` | string | **Optional.** Pack-relative path to that language's sticker-effect trigger sidecar (`docs/effects.md`); must exist and pass strict validation. Omit for no effects. |

### Validation rules (enforced by BOTH the Go packager and the Swift decoder)

1. `schemaVersion` supported (currently 2).
2. `id`s well-formed; sticker IDs unique; story IDs unique.
3. `languages` non-empty, well-formed BCP-47 (`^[a-z]{2,3}(-[A-Z]{2})?$`), no
   duplicates.
4. **Language coverage is exact**: every localized map (`displayName`, each
   `stickers[].name`, each `stories[].localizations`) contains a value for
   every declared language and none for undeclared ones. Partial translations
   are a validation error, not a runtime fallback.
5. Every referenced file (`background`, `foreground`, sticker images, every
   localization's audio and effects sidecar) exists inside the pack. No path
   may escape the pack (no `..`, no absolute paths).
6. Story sticker references are declared; `requiredStickers` and
   `optionalStickers` are disjoint.
7. **At least one fallback story** (`requiredStickers` empty) — play must
   never fail regardless of canvas contents.
8. `weight > 0`, `version ≥ 1`; every `displayName`/`name`/`title`/`text`
   value non-empty.
9. Every declared effects sidecar is valid per `docs/effects.md` ("Trigger
   file"): the packager validates it **strictly** (unknown effect names,
   unknown keys, out-of-range numbers and undeclared stickers are errors);
   the app decodes it **leniently** (skip / clamp / log) so a pack authored
   against a newer library still plays with fewer effects.

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
  added (additive, no bump).
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
