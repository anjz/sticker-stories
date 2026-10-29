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
    sky.webp              # optional: where the background is open sky ("Sky" below); sky-wide.webp for the wide art
  stickers/
    <stickerID>.webp      # sticker art, alpha background, white border baked in
    <stickerID>.<expr>.webp  # optional face variant ("Expressions" below)
  anims/
    <stickerID>.<animID>.json  # live animation sidecar, declared in stickers[].animations
    <stickerID>.rig.json   # the sticker's puppet: its rig ("Puppets" below)
    <stickerID>.rig.webp   # the puppet's parts (atlas)
  audio/
    <lang>/<storyID>.m4a           # pre-rendered narration, AAC, one folder per language
    <lang>/<storyID>.effects.json  # optional triggers (sticker, canvas, live, face) for that narration
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
die-cut edge pixel-exact. `stickerart install` and `stickerrig install`
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
- **Windows narrower than the art** (portrait, Split View, a narrow
  phone) show the full height and let the child pan sideways over the
  rest; a story there plays on the whole art and the camera follows it
  (`docs/stage3d.md`, "Narrow windows").
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
- **Framing elements at the edges** (a building, a big rock at the side)
  must not grow on phones: widening the foreground by continuing an
  element the base art cuts at its edge makes it fill a third of a phone
  screen. Paint the wide foreground on its own instead, with the same
  elements at *its* edges at the same size (`stickerart`'s
  `scene.foregroundWideOwn`; say, a building and a mast) — the wide
  foreground is then not the base one widened, and a place on those
  elements gets its own wide areas (`features[].wideAreas`, "Features").
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
- **Space packs paint no moving sky and no light of their own.** The art
  is a calm, dark starry sky with distant, unlit stars and whatever
  scenery the pack needs (planets, moons, a rocket pad), in plain
  daylight, but **never comets, a band of the Milky Way, the Sun or its
  glare, beams of light, clouds of dust or a bright planet rim on the
  horizon** — the space canvas effects draw those (and the night).
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
  "features": {
    "pond": {
      "description": "the small pond with lily pads, right of the middle of the meadow",
      "areas": [{ "x": [0.57, 0.74], "y": [0.3, 0.37] }]
    },
    "meadow": {
      "description": "the open grass of the meadow",
      "areas": [{ "x": [0.1, 0.9], "y": [0.16, 0.36] }]
    }
  },
  "stickers": [
    {
      "id": "mushroom",
      "name": { "en-US": "Mushroom", "es-ES": "Seta" },
      "image": "stickers/mushroom.webp",
      "stage": { "entrance": "grow", "on": ["meadow"] }
    },
    {
      "id": "frog",
      "name": { "en-US": "Frog", "es-ES": "Rana" },
      "image": "stickers/frog.webp",
      "animations": ["anims/frog.catch-fly.json", "anims/frog.hop.json"],
      "stage": { "entrance": "hop", "on": ["pond", "meadow"] }
    }
  ],
  "stories": [
    {
      "id": "shy-mushroom",
      "requiredStickers": ["mushroom"],
      "optionalStickers": ["fox", "frog"],
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
| `layers` | [object] | **Optional.** The scene's planes between the background and the foreground, far to near ("Layers" below): each `{ "id", "image", "imageWide" }` — a lowercase id (not `background` or `foreground`), a PNG or WebP plane of the base art's size, and the same on the wide art exactly when the pack has wide art. |
| `sky` | object | **Optional.** Where the background is open sky ("Sky" below): `{ "image", "imageWide" }` — a PNG or WebP mask of the background (alpha = sky), and the wide background's exactly when the pack has wide art. Made by `stickerart install` (or `stickerart sky`); without one, sky effects are not clipped. |
| `space` | object | **Optional.** The scene as a place with depth ("Space" below): `horizon`, `ground`, `back`, `stand`, `floor`, `layers` (the planes at their depths), `places` (features in space), `sizes` (every sticker's) and `edit` (how big they are while the child edits). |
| `cover` | string | **Optional.** Pack-relative path to the pack's cover art (PNG or WebP, must exist): what its tile shows in the main menu and the store. Made with `uiart` (`tools/author/uiart`); without one the app composes the tile from the background and a few stickers. No text in it — the app writes the name. |
| `world` | object | **Optional.** The physics of the pack's world for particle effects ("World" below): `gravity` (relative to Earth's: 1 on Earth, 0.17 on the Moon; 0–2) and `ground` (`#RRGGBB`, the colour dust is kicked up from). Either may be left out; the app fills it from the `setting`. |
| `staging` | object | **Optional.** How stories stage the stickers they bring in and move ("Staging" below): `layer` (`foreground`, the default, or `background`) and `anchor` (`centre`, the default, or `feet`). |
| `stickers[].id` | string | Lowercase `a-z0-9-`, unique within the pack. `all` is reserved (triggers use it for every sticker). |
| `stickers[].name` | {lang: string} | Display/accessibility name per language. |
| `stickers[].image` | string | Pack-relative path to a PNG or WebP file; must exist. |
| `stickers[].animations` | [string] | **Optional**, default none. Pack-relative paths to live-animation sidecars (`.json`, "Live animations" below); each must exist and validate. |
| `stickers[].expressions` | {expr: string} | **Optional**, default none. Face variants by expression id (`happy`, `sad`, `sleeping`, `surprised`…): pack-relative PNG or WebP images with exactly the sticker's size and outline ("Expressions" below). The sticker's own `image` is the `normal` face. |
| `narrationPacks` | {lang: string} | **Optional.** Per language, the Apple-hosted asset pack that carries that language's narration audio instead of the pack itself (`docs/asset-delivery.md`): `"<pack>-narration-<language>-<hash>"`, the hash taken over that language's audio, written by `storyaudio install`. Inside the asset pack each file sits at `<asset pack id>/<audio path>`. A language without one keeps its audio in the pack. |
| `features` | {id: object} | **Optional.** Named places in the art where stickers can land ("Features" below): each has a `description` (for story authors) and `areas`, a non-empty list of `{ "x": [min, max], "y": [min, max] }` in fractions of the base art, each area optionally with `"facing": "left"` or `"right"` — a place a character faces into, the area holding its **front** rather than its centre (a woodpecker's beak on the bark of a trunk) — optionally `words` — how each language's stories name the place (`{ "en-US": ["pond", "water"], "es-ES": ["charca", "agua"] }`, single words; storycheck warns when a sentence puts a character there with no move taking it there; the app ignores them) — optionally `"air": true` for open air (the sky: nothing sits there; story validation keeps flyers from resting in it, the app ignores it) — optionally `edge`, a non-empty list of areas like `areas` (no `facing`) where a character that does not go into the place stands beside it: the grass at the pond's edge — and optionally `wideAreas`, a non-empty list of areas like `areas` used instead of them when the wide art is drawn, with x allowed from −0.5 to 1.5 (the wide side bands, still in fractions of the base art), for a place on a foreground element the wide art paints at its own edge ("Features" below) — and optionally `from`, `"left"` or `"right"`: the side of the screen the place runs on past (the open sea, when the beach closes the other side), so whatever comes into it from off screen comes from that side and whatever leaves it goes that way, never sliding in over the sand. |
| `stickers[].stage` | object | **Optional**, default grow in `x` 0.1–0.9, `y` 0.18–0.45. Where the sticker belongs in the scene and how it comes in when a story names it and the child has not placed it ("Stage" below): `entrance` is `hop`, `fly` or `grow`; `on` lists `features` in order of preference; `area` (`{ "x": [min, max], "y": [min, max] }`, fractions of the base art) is where it lands when none of them is on screen. At least one of `on` and `area`. |
| `stickers[].size` | string | **Optional**, default none. How big the character is next to the others: `huge` (a rocket), `big` (a deer, a bear), `medium` (a fox, a rabbit), `small` (a bird, a mouse) or `tiny` (a ladybug). A story moving it beside another scales it so the two keep the ratio of their classes (relative sizes 1.6, 1, 0.75, 0.55, 0.4, on the longest side of the drawing; `docs/effects.md`, "Movement"), and a story that invites it (a visitor) brings a big one in at 1.3× a sticker's default size and a tiny one at 0.8× — or, for a sticker drawn at its size (`content`), as drawn, a huge one bigger at the front of the scene than by the horizon (`docs/effects.md`, "Entrances"); without one it keeps its size. |
| `stickers[].content` | object | **Optional.** Where the drawing sits in the sticker's image, `{ "x": [min, max], "y": [min, max] }` in fractions of the image, origin bottom-left — for a sticker **drawn at its size** ("Drawn size" below); written by `stickerart install`. Absent: the drawing fills the image (Forest). |
| `stickers[].door` | object | **Optional.** Where someone going to the sticker stands — the foot of a lander's ladder, a ship's elevator, a rover's door — `{ "x", "y" }` in fractions of the image, origin bottom-left: a walker a story sends to it (`{man:go to lander}`) stands there, its feet on that point, in front of it; the next one goes beside. Absent: everyone goes beside. Copied from `art.json` by `stickerart install`. |
| `stories[].id` | string | Unique within the pack. |
| `stories[].requiredStickers` | [string] | The stickers the story is about: it is a candidate when at most one of them is missing from the canvas (and at least one is present), and preferred when all are. Empty ⇒ fallback story. Every ID must be declared in `stickers`. |
| `stories[].optionalStickers` | [string] | Sticker IDs that raise the match score when present. Declared in `stickers`; no overlap with `requiredStickers`. |
| `stories[].weight` | number | Base selection weight, > 0. Default 1.0. |
| `stories[].tags` | [string] | Free-form variety tags (e.g. `gentle`, `funny`). |
| `stories[].localizations` | {lang: object} | One block per language (see below). |
| `…localizations[].title` | string | Short story title in that language (parent-facing; not read to the child). |
| `…localizations[].text` | string | Full story text in that language. **Required** — the portable representation for future TTS/LLM narrators. |
| `…localizations[].audio` | string | Pack-relative path to that language's pre-rendered narration; must exist — in the pack, or, for a language with a narration pack, in that asset pack (below). |
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
    the sky masks, every `stickers[].image`) ends in `.png` or `.webp`
    ("Image formats").
12. Every `stickers[].animations` entry is a `.json` file inside the pack.
    The packager validates the sidecar **strictly** (unknown keys, a
    `sticker` other than the declaring one, an empty `description`, an
    `id` the sticker already uses, no `puppet`,
    a `stickerBox` outside the unit square, a `kind` other than `action`/`move`,
    a second move for one sticker without a `loop`, a `pause` on a move
    or a `perched`, `place` or `props` on a move, `props` on an action without a `pause`, a prop named otherwise than lowercase words joined by hyphens or outside −2–3 of the image, a `place` naming no feature, an area `facing` other than left/right or on a stage area, a `pause` outside the middle frames or without `shows`, a `loop`, `facing`,
    `stride`, `hops`, `flies`, `hovers`, `stays`, `waterline`, `away` or `rest`
    on an action, any of them or `on` or `faces` on a move without a loop, a loop
    outside the keys or starting on key 0, a
    looping move without `facing` left/right or with a `stride` outside
    0–5, `hops` with `flies`, `hovers` without `flies`, `stays` or
    `waterline` without `on`, a `waterline` outside 0–1 (1 excluded), an
    `on` (a move's or an action's) naming no feature, an `away` or a
    `rest` that is not another looping move of the same sticker, a `rest`
    without `stays`, a `faces` other than `left`/`right`, an `effects`
    entry with an effect other than `surf-wave`, a frame outside the keys
    or an intensity outside 0–1 are
    errors); the app checks the file exists and reads it **leniently**
    (an undecodable sidecar is skipped with a log, never fatal; a pause
    or loop it cannot use is dropped). The `puppet` is checked against its
    rig, which is read strictly too ("Puppets": the atlas exists, every
    bone comes after its parent, slots hang on bones and show the rig's
    parts, faces and the idle blink name real attachments; keys are at
    least two, with holds in 0.02–5 s, known eases, bones and attachments
    of the rig, stretches not 0 and at most 4 either way — the sidecar's
    `pause`, `loop` and `particles` count its keys; `wings` only on a
    move that flies, naming bones of the rig); the app skips a sidecar
    whose puppet does not decode or has fewer than two keys.
13. Every `stickers[].expressions` key is lowercase `a-z0-9-` and not
    `normal`; every value is an image inside the pack (`.png` or `.webp`)
    that exists. No sticker is called `all`.
14. A `stickers[].stage`, when present, has an `entrance` of `hop`,
    `fly` or `grow`, and `on` (declared `features`, no repeats) and/or an
    `area` whose `x` and `y` are each `[min, max]` with
    0 ≤ min < max ≤ 1.
    A `stickers[].size`, when present, is `huge`, `big`, `medium`,
    `small` or `tiny`; a `stickers[].content`, when present, is valid like
    a stage `area` (within 0…1), without `facing`.
15. Every `features` id is lowercase `a-z0-9-`, differs from every
    sticker id (a move's target, `{frog:go to pond}`, may be either), has a non-empty
    `description` (the packager checks it; the app ignores it) and at
    least one area, each valid like a stage `area`; its `words`, when
    present, are keyed by the pack's languages and are single words; its
    `edge`, when present, is a non-empty list of areas valid like a stage
    `area`, none with `facing`; its `wideAreas`, when present, need the
    wide art (`backgroundWide`) and are a non-empty list of areas valid
    like a stage `area` except that x may run from −0.5 to 1.5; its
    `from`, when present, is `left` or `right`.
16. Every `narrationPacks` key is a declared language and every value a
    lowercase `a-z0-9-` ID, one language each. A language with a narration
    pack is exempt from rule 5 for its audio (only the path is checked),
    and the packager checks its ID still matches its audio — a changed
    recording needs a new asset pack (`storyaudio install` names it).
17. `world`, when present, has a `gravity` from 0 to 2 and a `ground`
    that is a `#RRGGBB` colour (either may be left out).
18. `staging`, when present, has a `layer` of `foreground` or `background`
    and an `anchor` of `centre` or `feet` (either may be left out); a
    sticker's `door` has `x` and `y` from 0 to 1.
19. Every `layers` entry has a lowercase `a-z0-9-` id, unique, not
    `background` or `foreground`; its `image` is a PNG or WebP inside the
    pack; its `imageWide` is one too, present exactly when the pack has
    wide art.
20. `space`, when present: `horizon` inside 0…1, `ground` below it,
    0 < `stand.near` < `stand.far` ≤ `back`, `floor` from 0 up to 1,
    `edit.spread` above 0 and at most 1, `edit.minimum` 0–200. Its
    `layers` have unique lowercase ids and depths in (0, `back`], show
    `foreground` or a declared `layers` id (`art`), with at most one
    piece per plane without a `mask`, and put every plane (the
    foreground and each `layers` entry) at a depth. Its `places` are
    declared `features`, each exactly one of `ground`, `air` or `lines`
    (`wideLines` only beside `lines`; lines on the space's layers,
    `facing` left or right). Ground polygons (and footprints) lie below
    the horizon and in front of `back`; every point is within x −0.5…1.5,
    y 0…1; polygons have at least 3 points, lines 2. `sizes` name
    declared stickers, every sticker has one, each above 0 and at most 5.
21. `sky`, when present: its `image` is a PNG or WebP inside the pack;
    its `imageWide` is one too, present exactly when the pack has wide
    art.

## Stage

Stories name stickers the child may not have placed. So that what the
narrator says is what the child sees, every sticker a story names comes
into the scene on the word that first names it, if it is not on the
canvas already (the story's `enter` triggers, `docs/effects.md`,
"Entrances"), and leaves again when the story ends. Its `stage` says
where it belongs and how it arrives:

| `entrance` | For | What it does |
|---|---|---|
| `hop` | things that walk, crawl or hop | Hops in from the nearer side of the screen, from somewhere on its own ground, to its spot. Walking up the scene (away from the viewer) it starts a little bigger and shrinks to its size; walking down it starts smaller and grows — the meadow has depth. |
| `fly` | things that fly | Floats in from the nearer side, a little higher up, with a gentle bob and tilt, and settles on its spot. |
| `grow` | things that do not move (plants, objects) | Fades in and grows from small where it stands, with a little overshoot. |

Where it lands is `on`, a list of the pack's **features** in order of
preference, and/or an `area` of its own; both are about the sticker's
**centre**, in fractions of the base art with the origin at the
bottom-left — the space saved positions use. The app goes down the list
and takes the first feature with a free spot the window shows — the
freest one, farthest from every sticker already there, earlier visitors
included; a feature off screen or full is skipped. A window narrower than
the art plays the story on all of it across, and its camera follows the
story, so every feature counts there (`docs/stage3d.md`, "Narrow
windows"). Then the `area`. When every choice is crowded
it takes any spot in the first one on screen. Under Reduce Motion or
calm mode every entrance is a plain fade-in. A sticker without a stage
grows in the default area.

Match the stage to what the sticker's art shows:

- walkers, crawlers and still things on the ground (`meadow` in Forest);
- free flyers — drawn in mid-air (the bee, the butterfly) — in the sky;
- birds drawn **perched** on something land on the matching feature
  when there is one (Forest's bird and owl on the trees' `branches`, the
  woodpecker on a `trunk`), and in the sky otherwise;
- **insects** drawn on a leaf or a blade of grass (the firefly, the
  ladybug) land on the ground — a leaf floating in mid-sky looks wrong;
- anything that belongs somewhere specific goes there first (the frog:
  `["pond", "meadow"]`).

`stickerart` copies each sticker's `stage` from `art.json` on install.

## Features

`features` names the places in the pack's art that stickers can land
on: the pond, the trees' branches, their trunks, the meadow, the open
sky. They are measured on the finished art (draw a grid over the base
background with the foreground on top) and describe where a sticker's
**centre** sits when it is on that place — for a bird perching on a
branch, a little above the branch line. A feature may have several areas
(one per tree). The app keeps each to the part on screen: the top and
bottom bands are cropped away on wide windows, which is why stages list a
fallback (a narrow window shows everything across, its camera following
the story). Story authors read the descriptions (`storycheck
-plan` prints them with the stickers that land on each) so the words put
a sticker where the child will see it. `stickerart` copies them from
`art.json` (`scene.features`) on install. A feature marked `air` is open
air — the sky: a flyer there is flying, with nothing to sit on, so a
story lands it somewhere else (on a flower, on the meadow, on a branch)
before it plays an action marked `perched` ("Live animations"); stages
never fall back to it for a character that stands or sits.

A feature may have an **`edge`**: areas beside it where a character that
does not belong *in* it stands — Forest's pond has three banks (left,
right, and the grass in front of the water). A story that sends a
character to the place (`{mouse:go to pond}`) takes it into the place
when its `stage` lands there or the move it goes by lands there (its
`on`: the frog hops in, the duckling swims in `by swim`); anyone else
stops at the edge, close enough to touch the water — the mouse, the
beaver, the duckling waddling up. Without an `edge` everyone goes in.
Measure the edge like the areas: where a character's centre sits so it
stands at the water, seen whole. Story validation treats every walker
and flyer as able to be at a place with an edge, so a sentence that puts
one by the pond needs a move there.

A place on a foreground element that the wide art paints at its own edge
(a building's door, at the left edge of every screen) is
somewhere else on each rendition, so it carries **`wideAreas`**: the
areas the app uses instead of `areas` while it draws the wide art, in the
same base-art fractions — which on the wide art run from about −0.25 to
1.25, so a hatch at the phone's left edge sits at x ≈ −0.2. Measure them
on the wide composite the same way (a grid over it, converted to base
fractions: `x_base = (x_wide × wideWidth − (wideWidth − baseWidth) / 2) /
baseWidth`). Places in the background (the pad, the crater) are the same
on both renditions and need none.

## Drawn size

A pack drawn from now on draws each sticker **at its size class's share
of its square image**, centred, with the rest of the image left empty:

| `size` | Longest side of the drawing (border included) |
|---|---|
| `huge` | 94 % |
| `big` | 84 % |
| `medium` | 72 % |
| `small` | 60 % |
| `tiny` | 50 % |

So stickers dropped from the tray already look roughly their size next to
each other, and the empty room around a drawing is where its animations
reach — dust, sparks, a raised arm — without the sticker ever shrinking
to make room. `stickerart` draws to these
(`sizeInArt` in `art.json`) and its install writes each sticker's
`content`; the app then:

- fits the image into a **bigger box** (21 % of the art's height instead
  of 16 %), so a medium sticker comes out the size every sticker of an
  older pack has;
- places, spaces and scales stickers by their **drawings**, not their
  boxes (feet on the same line, side by side, fitting on screen);
- takes a touch only **on the drawing** (at least 44 points across, so a
  tiny one is still easy to grab), never on the room around it;
- brings visitors in as drawn, a huge one by the scene's depth
  (`docs/effects.md`, "Entrances").

A pack without `content` keeps the old behaviour throughout.

## World

`world` is what particle effects (`docs/effects.md`, `dust-puff`, `spray`,
`sparks`) need to know about the place: how strongly things fall and what
the ground is made of. The same `dust-puff`'s grains then hang and arc
slowly as grey dust on the Moon and drop at once as brown soil in a
forest (its cloud billows out sideways and a little up either way).

```json
"world": { "gravity": 0.17, "ground": "#A9A6A1" }
```

Left out (or a part of it), it comes from the `setting`:

| `setting` | `gravity` | `ground` |
|---|---|---|
| `outdoors`, `none` | 1 | `#9C7B55` (soil) |
| `indoors` | 1 | `#BDB2A2` (a floor's dust) |
| `space` | 0.17 (the Moon) | `#A9A6A1` (grey dust) |
| `underwater` | 0.15 (sinking slowly) | `#D9C9A0` (sand) |

A space pack set in orbit, with no ground at all, sets `gravity` to 0.

## Staging

`staging` says how the pack's stories put on stage the stickers they
bring in (entrances) and move (`docs/effects.md`, "Movement"):

```json
"staging": { "layer": "background", "anchor": "feet" }
```

- **`layer`** — `foreground` (the default, Forest): visitors and movers
  play in the sticker layer in front of the foreground art, and a flyer
  goes in front of everyone as it takes off. `background`:
  they come in, travel and land in the layer **behind** the foreground
  art, so the scene's near elements — a habitat, the rocks in front —
  pass in front of a lander on the pad or a rover crossing the plain, as
  they would. A sticker the child put in the front layer goes back there
  while it moves, and returns to its own layer when the story ends.
- **`anchor`** — `centre` (the default): a feature's areas hold a
  sticker's centre ("Features"). `feet`: on every feature that is not
  open air (`air`), the areas hold the **bottom of the drawing** — where
  it stands — so a lander, a supply pod and an astronaut sent to the
  same pad all stand on it, whatever their size; open air still holds
  centres. Measure such areas as ground lines: where feet go. It needs
  the stickers' `content` ("Drawn size") to know where each drawing's
  feet are; without it, the bottom of the image.

## Layers

A scene can be painted in more than two planes: the far background, the
foreground nearest the viewer, and `layers` between them — Forest's trees
at the meadow's edges and the reeds at the far side of its pond. Each is a
transparent plane the size of the base art (and of the wide art), painted
over everything behind it (`stickerart`, `scene.layers` in `art.json`).

- **While the child edits the canvas** the layers are drawn with the
  background: behind both sticker layers, as if they were painted into it.
  The child's choice stays the same two: on top of everything, or just
  behind the foreground.
- **While a story plays** each plane stands at its depth (`space`, below):
  a sticker behind the reeds is hidden by them, one in front of a trunk
  is drawn over it.

## Space

`space` is the scene as a place with depth: a camera looking level at a
ground, fitted to the painted art (`tools/author/scenespace`, which fits
it in `author/art/<pack>/space.json` and shows it in 3D; `stickerart
install` copies it here). Every point on the art has a depth, every
sticker a size there, and every plane of the scene stands at its depth.

**Units.** x (across), y (height above the ground) and z (depth from the
eye) are in **art heights at depth 1** — the depth of the nearest
foreground plane. Points on the art are fractions of the base art, origin
bottom-left, as everywhere else in the manifest.

| Field | |
|---|---|
| `horizon` | Art y of the eye line. Read it off a round thing lying on the ground: a pond `h` tall and `w` wide (art heights) centred at art y `v` puts it at about `v + h / w`. |
| `ground` | Art y of the ground at depth 1 (usually 0: the art's bottom edge). |
| `back` | Depth of the backdrop, where the ground ends and the painted distance begins. |
| `stand` | `{ "near", "far" }`: the depths stickers stand at. |
| `floor` | **Optional**, default 0. The smallest height a sticker is drawn at (art heights), so a tiny one far away stays easy to see. |
| `layers` | The planes at their depths: `{ "id", "art", "depth", "mask", "footprint", "wide" }` — `art` is the plane shown (`foreground` when absent, or a `layers` id); `mask`, a polygon of art points, cuts a piece of the plane (two trees at different depths), one piece per plane may be the rest; `footprint`, a polygon of feet positions, is ground nothing walks on (a trunk's roots); `wide` holds another `depth`, `mask` and `footprint` for the wide art when the piece is painted elsewhere there. |
| `places` | Features (the same ids) in space, exactly one of: `ground` — a polygon of feet positions, `water: true` for water (and `shallow: true` with it for shallow, clear water — a rock pool — where whoever belongs in it sits on the bottom, seen whole, and nobody floats at a waterline); `air` — `{ "area": polygon, "depth": [near, far] }`, open air; `lines` — `[{ "layer", "points", "facing" }]`, where feet (a branch) or a front (`facing`: the bark of a trunk) go on a layer, at its depth, with `wideLines` for the wide art. |
| `sizes` | Every sticker's drawn height at depth 1, in art heights. |
| `edit` | **Optional.** `{ "spread", "minimum" }`: how big stickers are while the child edits the canvas (below). Without it they are at their sizes. |

**The camera.** The eye is `horizon − ground` above the ground. The
ground seen at art y `v` is at depth `z = (horizon − ground) / (horizon − v)`;
a point `(x, y, z)` shows at `u = 0.5 + x / (aspect · z)`,
`v = horizon + (y − (horizon − ground)) / z`, where `aspect` is the base
art's width over its height. A sticker of size `s` standing at depth `z`
is `s / z` tall — never below `floor`, nor above its own size when that is
smaller than the floor. Sizes are set against each other on the scene
(`scenespace`'s sizing page), so every sticker keeps its size next to
every other at any depth.

**While the child edits** there is no depth: a sticker starts halfway
between its height at the front and at the back of `stand`, and a pinch
takes it between those two. With `edit`, the differences are softened and
the smallest kept big enough to see and pick up on any screen:

- `spread` (above 0, at most 1): a sticker's height `h` becomes
  `H · (h / H)^spread`, `H` the biggest sticker's, which stays as it is.
  1 changes nothing; 0.6 makes a bee about twice as big next to the bear.
- `minimum` (points, 0–200): none is drawn smaller on the screen than
  this — the square root of its drawing's width × height, so a long, low
  one is not stretched tall — measured on the art as the device shows it
  (the base art's height in points), so it bites on phones and small
  windows.
- A pinch then takes it at least from 0.7× to 1.5× (or its front-to-back
  range when that is wider), never under the minimum.

A story still draws every sticker at its size for its depth: as it
starts, the child's stickers ease to those sizes, and back when it ends.

## Sky

`sky` says which part of the background is **open sky**, so the canvas
effects that live in the sky — the moon and stars, clouds, the rainbow,
a comet, the Milky Way (`docs/effects.md`, "Canvas effects") — are drawn
only there and never over the treetops, ridges, buildings or planets
painted into the background. It is worked out from the art when the art
is installed, never guessed by the app:

- `art/sky.webp` (and `art/sky-wide.webp` for the wide background): a
  mask at **half the background's size**, white, its **alpha** the sky —
  255 in open sky, 0 on the scenery, a soft edge of a few pixels set a
  pixel inside the sky.
- **How it is found** (`stickerimg.SkyMask`): a colour flood fill from
  the top edge. It spreads to each neighbour whose colour is a small step
  from the pixel it comes from (a painted edge is a jump in colour; the
  sky's gradient never is) and still looks like this sky — close to the
  top edge's colour (by 18 plus a quarter of that colour's brightness: a
  blue sky pales towards the horizon, a black one stays black, so a
  planet's night side against it is not sky) or a pale, unsaturated
  cloud. Whatever it closes round without reaching the bottom edge — a
  painted cloud, a star — is sky too; whatever stands on the ground
  (trees, a ridge, the Earth behind the ridge, a lighthouse) reaches the
  bottom through what it stands on.
- `stickerart install` makes the masks from the backgrounds it installs;
  `stickerart sky -pack <dir> [-preview <dir>]` remakes them for an
  installed pack and can write each background with its sky tinted, to
  check by eye.

The app also uses the mask for snow: the ground it settles on is what is
not sky (with a `space`, up to the ground's far edge), with a cap along
the top of the painted scenery where it meets the sky.

## Expressions

A sticker with a face can carry **face variants**: the same sticker with
another expression — `happy`, `sad`, `sleeping`, `surprised` in the Forest
pack. Stories change a sticker's face with an expression trigger
(`docs/effects.md`, "Faces"): it has no duration, the face stays until the
next change, and the story's end puts every sticker back to `normal`.

Each variant is made by `tools/author/stickerart` from the sticker's own
raw art: only the face is repainted (the API edits a masked area, and only
that area is laid back over the raw), and it is finished exactly like the
sticker, so it has **the sticker's exact size and outline** and the app
swaps it in place with a short crossfade. A pack may give any subset of
stickers any subset of expressions; stories may only ask a sticker for a
face it has (the storycheck and packager check this), while an `all`
change skips stickers without that face.

## Live animations

Every sticker carries animations: short runs of keyframes its puppet
plays ("Puppets" below) that bring it to life. Two kinds (`kind`):

- an **action** — what the character does at a moment of a story: the
  snail hides in its shell, the frog catches a fly, the bear cub yawns and
  nods off. Stories cue it on the words that tell it (`docs/effects.md`,
  "Live animations"). Most actions have a **pause key** (`pause`): the
  pose they can stop in and stay — the snail tucked in its shell, the
  bear cub asleep — for as long as the story needs, until the story
  resumes it or ends.
- a **move** — how the character gets about: a walk or a waddle, a hop,
  a crawl, a flight, a plant sprouting. It plays while a story brings the
  sticker into the scene or moves it (`docs/effects.md`, "Entrances",
  "Movement"): a **loop** of keys repeated while it travels, then a few
  keys that bring it to rest in its sticker pose. A plant's sprout has
  no loop and plays once. A character that gets about more than one way
  has a move for each — the ladybug crawls and flies, the duckling
  waddles and swims: its **first** declared move is its usual way, and
  any other plays only when a story names it (`"by": "fly"` on an
  entrance or a move trigger), so what the words say and what the screen
  shows agree.

**Every pack gives every sticker one action and one move** (the authoring
target, like the story count; not a validation rule), and a second move
to a character that plainly gets about two ways. A puppet's animations
cost no image generation, so every sticker gets **many actions** — a
jump, a nod, a wave, a little dance, whatever its body can do and
stories are likely to tell ("Puppets"). The motions are small and
unhurried — nothing fast, nothing that reaches far from the sticker.

Each animation is a sidecar declared in `stickers[].animations`, holding
the keys of the sticker's puppet made by `tools/author/stickerrig`
("Puppets"). The keys are the animation's frames: `pause`, `loop` and
`particles` count them, 0-based:

| Key | Meaning |
|---|---|
| `id`, `sticker` | the animation's id (unique per sticker) and the sticker it belongs to (must match the declaring sticker) |
| `kind` | `action` (the default when absent) or `move` |
| `description` | one plain sentence saying what the animation shows ("the snail pulls its head and eye stalks into its shell, waits, then slowly peeks out"), for story authors; required, ignored by the app |
| `stickerBox` | the sticker's drawing within its image, as fractions of the image (top-left origin) |
| `props` | actions with a `pause` only, optional: what the character holds out in the paused frame, by name, and where it is then — `{ "kite": { "x": 0.204, "y": -0.618 } }`, fractions of the sticker image with a top-left origin like `stickerBox`, anywhere from −2 to 3 (the girl's kite flies far above her). While the action is held, a story can send a flyer to it (`"prop"` on a move trigger, `docs/effects.md`, "Movement"); `stickerrig` writes it from the rig's `props` |
| `place` | actions only, optional: feature ids the action happens at (the woodpecker's tap: `["trunks"]`). Before it plays, the app takes the character to the nearest spot on one (its front on a `facing` area, facing it) unless it is there already — wherever a child put it — and the action waits until it arrives; storycheck errors on a story that took it elsewhere first |
| `perched` | actions only, optional: `true` when the character sits on something in it (the butterfly folding its wings to rest, the owl dozing off); stories land a flyer before they play it, never in a feature marked `air` (checked by storycheck; the app ignores it) |
| `faces` | actions and moves with a loop, optional: `left` or `right`, the way the character faces on screen while the action plays (the surfer riding a wave: `right`, the way the wave rolls). The app turns the whole puppet to it as the action starts — mirroring it as needed, whatever way it faced — and back as it ends; never the head alone (`docs/stage3d.md`, "In the water"). On a move, the way it faces and goes on screen: a move `to` or `away` without a way of its own goes a little that way (a place: its part a few widths over on that side), and it faces so there and resting — the surfer always paddles out right to left and rides the waves left to right, the way Beach's sea and waves run |
| `idle` | actions only, optional: `true` for a small, gentle action (a look around, an ear flick, a sniff) the app plays now and then on its own while a story leaves the character be — never while it moves, holds a pose, sleeps or hovers — so everyone on the stage looks alive (`docs/stage3d.md`, "Alive at rest") |
| `pause` | actions only, optional: `{ "frame": 11, "shows": "the snail tucked inside its shell" }` — the 0-based key the action can stop on (not the first or last) and what it shows, for story authors |
| `loop` | moves only, optional: `{ "from": 1, "to": 8 }` — the keys (0-based, both included; after key 0, the rest pose) repeated while the character travels; the keys after it bring it to rest. Without it the move plays once (a sprout) |
| `facing` | moves with a loop: `left` or `right`, the way the keys travel (the app mirrors a sticker that has to come in the other way) — always the way the art faces (its face turned that way, its toes pointing there), since the app also reads the first move's `facing` as the art's; a move against it walks backwards (`stickerrig check` warns) |
| `stride` | moves with a loop: how far one loop carries the character, in multiples of the sticker's width (above 0, at most 5), so it travels at the pace of its legs |
| `hops` | moves with a loop, optional: `true` when the loop is a hop drawn in place; the app lifts the character in an arc once per loop |
| `flies` | moves with a loop, optional: `true` when the loop is a flight; the app glides the character along with a gentle bob and stops it beside others at their height (not with `hops`) |
| `hovers` | moves with `flies`, optional: `true` when the flight can hold still in the air (a bee, a butterfly): resting in the air, it stays put with a gentle bob, its loop going. Without it the character cannot hover (a bird, an owl): the app keeps it flying a slow loop round its spot, turning as it goes, for as long as the story leaves it in the air (`docs/stage3d.md`, "In the air") |
| `on` | moves with a loop, optional: feature ids (`features` above) a story that brings the character in this way lands it on, in order of preference — the duckling swimming in lands on the pond; empty for its `stage`'s. **Actions**, optional: the places the action is done in (the surfer riding a wave: `["sea"]`). While a move that `stays` keeps the character in water, an action whose `on` does not name that water does not play its body: the move's loop goes on and the action shows only its face — the eye, mouth and brow attachments its keys swap, over the move's pose (the surfer laughs as he paddles on). One whose `on` names it plays as usual; out of the water every action does (`docs/stage3d.md`, "In the water") |
| `away` | moves with a loop, optional: the id of another of the sticker's looping moves, played instead while a leg this way goes away from the viewer — deeper into the scene more than across it — showing the character's back (`paddle`'s `"paddle-out"`). Resting there, or coming back, it plays this move |
| `rest` | moves with `stays`, optional: the id of another of the sticker's looping moves, played instead of this one's loop while the character rests where this way keeps it — the surfer sits on his board waiting for a wave rather than paddling on the spot (`paddle`'s `"wait"`). It faces as that move says |
| `stays` | moves with a loop and `on`, optional: `true` when the character stays in its element once this way has taken it into one of `on` — the surfer out on the waves, a pelican afloat: the app keeps the loop going where it is instead of settling into the sticker pose, which would stand it on the water (`docs/effects.md`, "Movement"). A perch place in its `on` (bark) is one the character takes to that way whenever it gets there, by any way, and keeps it while there: the woodpecker's `cling` (`docs/stage3d.md`, "Moves") |
| `waterline` | moves with a loop and `on`, optional: how deep the character floats while it is in water among `on` (a feature `water` in the space, "Space"), as a fraction of its drawing's height from its feet — the duckling swimming, `0.3`: its feet and the bottom of its belly are under water. Whatever it does there (swims, quacks, naps), the app hides that part of it and its shadow, sinking it in as it enters and out as it leaves, and draws a ripple where it meets the water (`docs/stage3d.md`, "In the water"). Packs with a space only |
| `particles` | optional: bursts the keys fire as they first come on show — `[{ "frame": 6, "effect": "dust-puff", "x": 0.5, "y": 0.86, "intensity"?: 0.5, "color"?: "#RRGGBB" }]`: the 0-based key, a particle effect (`dust-puff`, `spray`, `sparks` or `bubble-puff`, `docs/effects.md`), the point of the **sticker image** it comes from (fractions, top-left origin like `stickerBox`; −0.5–1.5 so a flame's tip can be just outside), and optional intensity (0–1) and colour. A landing's dust, a touchdown, a splash: the art never draws particles itself (`docs/pack-art.md`). The physical ones follow the pack's `world` ("World"); bubbles rise and play wherever the animation plays — an action, an entrance, a move — but not under Reduce Motion or calm mode, where live animations don't play |
| `effects` | optional: sticker effects the keys start on the character as they first come on show — `[{ "frame": 5, "effect": "surf-wave", "intensity"?: 0.7 }]`: the 0-based key and the effect (only `surf-wave`, `docs/effects.md`: the wave rising behind the surfer as he stands up on his board, so a ride always has its wave), with an optional intensity (0–1). One already running on the character (a story's own `{surfer:surf-wave}`) is not started again; on land the wave draws nothing |
| `puppet` | required: the animation as keyframes for the sticker's puppet ("Puppets" below) — `{ "rig": "anims/owl.rig.json", "keys": [...] }`, at least two keys. A move that `flies` can name its `"wings"?: ["wingL", "wingR"]`: bones of the rig its flight keeps going — with every bone hanging on them and their slots — whatever else the character does while it is in the air (it talks, laughs or holds a pose and its wings beat on) |

An action's first and last keys (a move's first) are the puppet at rest,
which matches the sticker's own art, so the app can dissolve from the
still sticker into the puppet and back. A move's first key is only that
anchor; it plays from the second.

Stories play actions: the authoring cue `{snail:live}` becomes a trigger
`{ "at", "sticker": "snail", "animation": "hide" }` in the story's effects
sidecar (`docs/effects.md`, "Live animations"), `{snail:live hold}` and
`{snail:live resume}` the same with `"mode": "hold"` / `"resume"`; the
packager checks them against the actions the sticker declares (and
`hold`/`resume` against its pause key). A move is never cued on its
own: entrances and moves (`{fox:go to rabbit}`) play it, the usual one
unless the cue names another (`{ladybug:go on flower by fly}` becomes
`"by": "fly"`, checked against the sticker's moves). The developer effects gallery plays any. A story loads
only the puppets it plays.

## Puppets

An animated sticker has a **puppet**: its drawing cut into parts —
body, head, wings, feet, eyes, beak — hanging on a skeleton, which the
app moves. An animation is a handful of keyframes (data), and a new one
costs no image generation. `tools/author/stickerrig` makes the puppet
from sheets the image model draws from the sticker's own art (the
parts, the face pieces). This is the only way stickers animate: each
animation is a sidecar whose `puppet` keys are its frames — its
`pause`, `loop` and `particles` count keys.

The rig (`anims/<stickerID>.rig.json`):

| Key | Meaning |
|---|---|
| `sticker`, `atlas` | the sticker it belongs to; the pack-relative image (PNG or WebP) every part is cut from |
| `size` | the side of the square the coordinates are in: the sticker image's, so the puppet scales with the placed sticker. Coordinates are its pixels, top-left origin, y down; turns are degrees clockwise |
| `parts` | `{ name: { "rect": [x, y, w, h], "border": [x, y, w, h], "pad": n } }`: where each part's art is in the atlas, and its **border silhouette** — the part grown by the sticker's die-cut border, white, `pad` px larger on every side. All the borders are drawn under all the art, which gives the posed puppet the sticker's border (the union of the grown parts is the grown union) |
| `bones` | `[{ "id", "parent"?, "x", "y" }]`: the skeleton, each bone after its parent (the first is the root), at its joint at rest |
| `slots` | `[{ "id", "bone", "default", "attachments": { name: { "part", "x", "y", "w", "h", "rotate"?, "flip"?, "shade"? } } }]`, back to front: what each bone carries and the art it can show — a box at rest (turned `rotate` about its centre), mirrored with `flip`, darkened by `shade` 0–1 (the far wing). The attachment `none` shows nothing |
| `faces` | optional: the sticker's expressions as attachments, `{ "sleeping": { "eyeL": "closed", "eyeR": "closed" } }`, so a face cue changes the puppet's face |
| `idle` | optional: `{ "breathe": bone, "blink": { slot: attachment } }` — how it keeps alive between animations (a slow swell of that bone; a blink every few seconds when the face does not set those slots) |

A key (`puppet.keys[]`) is `{ "hold", "ease"?, "bones"?, "slots"? }`:
each named bone's change from rest — `r` (turn), `x`, `y` (shift), `sx`,
`sy` (stretch, 1 when absent; negative mirrors the bone, so the root going from `sx` 1 to −1 turns the character round like a card) — while bones not named stay at rest; the
attachments slots show from this key on (a slot not named shows the
face's, then its default); `hold`, the seconds from this pose to the next
(0.02–5); and `ease`, how it gets there: `inOut` (the default), `in`,
`out`, `linear` or `step`. Turns, shifts and stretches ease between keys;
attachments swap on their key. A move's loop goes round from its last
key back to its first.

Once a story has the puppet take over from the still sticker (dissolving
in over it), it stays on show — idling between animations,
showing the story's faces — until the story ends, so the still art and
the puppet hand over once rather than at every cue. The drop shadow is
the puppet's own, posed with it.

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
  optional `cover` added (additive, no bump); optional
  `stickers[].stage` and `features` added (additive, no bump); optional
  `features[].wideAreas` added (additive, no bump); optional
  `features[].from` and sidecar `stays` added (additive, no bump);
  sidecar `hovers` and `puppet.wings` added 2026-10-14 (additive, no
  bump); size class `huge`
  and optional `stickers[].content` added (additive, no bump); optional
  `world` added (additive, no bump); optional sidecar `particles`
  added (additive, no bump); the live
  animation sidecar gained optional `kind`, `pause`, `loop`, `facing`,
  `stride` and `hops`, and live triggers an optional `mode` (additive,
  no bump); optional `narrationPacks` added (additive, no bump);
  2026-10: optional `staging` and `stickers[].door` added (additive, no
  bump); optional sidecar `puppet` and puppet rigs added (additive, no
  bump); sidecars without a sheet, played by the puppet alone (an
  older build skips them; no bump); 2026-10-17: optional sidecar
  `away` (moves) and `faces` (actions), and `on` on actions (additive,
  no bump); 2026-10-26: sprite sheets removed — a sidecar's `puppet` is
  required and `sheet`, `frame`, `columns`, `count`, `rest`, `hold` and
  the puppet's own `pause`, `loop` and `stride` are gone (no pack used
  them; no bump); 2026-10-29: `faces` on looping moves, and optional
  sidecar `rest` (moves) and `effects` (additive, no bump).
- Any schema change must update this document, the Go validator
  (`tools/internal/manifest`), and the Swift decoder in the **same commit**.
- `version` (pack content revision) is bumped whenever any asset or story in a
  published pack changes; the app treats a higher version of an installed pack
  as a replacement.

## Per-language delivery

A pack's narration is delivered per language as Apple-hosted Background
Assets asset packs, named in `narrationPacks`; the pack itself (manifest,
art, stickers, animations and every language's effect sidecars) ships with
the app. `docs/asset-delivery.md` has the whole design: which language a
user gets at install, switching, fallback and storage.
