# Pack format

A **pack** is a versioned, self-contained directory of assets. It is the single
contract between the content pipeline (`tools/`, Go) and the app (Swift). Both
sides validate independently: the Go `packager` refuses to assemble an invalid
pack, and the Swift `PackLoader` refuses to load one.

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
    <storyID>.m4a         # pre-rendered narration, AAC
```

## manifest.json — schema v1

```json
{
  "schemaVersion": 1,
  "id": "forest",
  "version": 1,
  "displayName": "Forest Friends",
  "theme": "forest",
  "background": "art/background.png",
  "foreground": "art/foreground.png",
  "stickers": [
    { "id": "mushroom", "name": "Mushroom", "image": "stickers/mushroom.png" }
  ],
  "stories": [
    {
      "id": "story-001",
      "title": "The Shy Mushroom",
      "text": "Once upon a time…",
      "audio": "audio/story-001.m4a",
      "requiredStickers": ["mushroom"],
      "optionalStickers": ["fox", "tree"],
      "weight": 1.0,
      "tags": ["gentle"]
    }
  ]
}
```

### Field reference

| Field | Type | Rules |
|---|---|---|
| `schemaVersion` | int | Must be a version the reader supports (currently `1`). Readers must reject unknown versions. |
| `id` | string | Pack identifier: lowercase `a-z0-9-`, unique across the catalogue. Also the IAP product suffix (`com.anj.stickerstories.pack.<id>`). |
| `version` | int | Content revision of the pack, ≥1. Bump on any asset/story change. |
| `displayName` | string | Human-readable name shown to parents. |
| `theme` | string | Free-form theme tag; future prompt context for generated stories. |
| `background` / `foreground` | string | Pack-relative paths; files must exist. |
| `stickers[].id` | string | Lowercase `a-z0-9-`, unique within the pack. |
| `stickers[].name` | string | Display/accessibility name. |
| `stickers[].image` | string | Pack-relative path; must exist. |
| `stories[].id` | string | Unique within the pack. |
| `stories[].title` | string | Short title (parent-facing / debugging; not read to the child). |
| `stories[].text` | string | Full story text. **Required** — it is the portable representation for future TTS/LLM narrators. |
| `stories[].audio` | string | Pack-relative path to pre-rendered narration; must exist. |
| `stories[].requiredStickers` | [string] | Sticker IDs that must all be on the canvas for the story to be a candidate. Empty ⇒ fallback story. Every ID must be declared in `stickers`. |
| `stories[].optionalStickers` | [string] | Sticker IDs that raise the match score when present. Every ID must be declared in `stickers`. No overlap with `requiredStickers`. |
| `stories[].weight` | number | Base selection weight, > 0. Default 1.0. |
| `stories[].tags` | [string] | Free-form variety tags (e.g. `gentle`, `funny`). |

### Validation rules (enforced by BOTH the Go packager and the Swift decoder)

1. `schemaVersion` supported.
2. `id`s well-formed; sticker IDs unique; story IDs unique.
3. Every referenced file (`background`, `foreground`, sticker images, story
   audio) exists inside the pack directory. No path may escape the pack
   (no `..`, no absolute paths).
4. Every sticker ID referenced by a story is declared in `stickers`;
   `requiredStickers` and `optionalStickers` are disjoint.
5. **At least one fallback story** (`requiredStickers` empty) — play must never
   fail regardless of canvas contents.
6. `weight > 0`, `version ≥ 1`, non-empty `displayName`, `text`, `title`.

## Versioning rules

- `schemaVersion` changes only for **structural** changes to the manifest.
  Additive optional fields do not bump it; renames/removals/semantic changes do.
- Any schema change must update this document, the Go validator
  (`tools/internal/manifest`), and the Swift decoder in the **same commit**.
- `version` (pack content revision) is bumped whenever any asset or story in a
  published pack changes; the app treats a higher version of an installed pack
  as a replacement.
