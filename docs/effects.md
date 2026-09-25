# Effects

Small, charming things that happen while a story plays. Two kinds, two
closed libraries:

- **Sticker effects** — one placed sticker does something: a sparkle, a
  wobble, a glow, a fade. Twelve of them.
- **Canvas effects** — the weather or the light changes over the whole
  scene: fog, rain, sunshine, a rainbow, night falling, the lights going low,
  and their counterparts indoors, in space and under the sea. Each suits
  one or more pack `setting`s (see "Canvas effects").

This is the reference for **authoring** them (story tooling, hand-written
packs) and the contract the app implements.

Machine-readable twin: [`effects/effects.json`](effects/effects.json) — same
names, defaults and parameter lists, pinned to the compiled library by a
test. Tooling should read that file rather than parse this one.

## The model in five rules

1. **Effects only exist in play mode.** Nothing runs while the child arranges
   the canvas. When play ends (audio finishes, the child stops it, or leaves),
   the canvas snaps back to exactly what the child placed — and the weather
   clears.
2. **Sticker effects are deltas on the child's placement.** A `pulse` on a
   sticker the child scaled to 1.7× beats from 1.7×; an effect never sets
   absolute values. Canvas effects never touch stickers at all.
3. **Every sticker effect is a closed cycle** (starts and ends at the
   placement), which is why `repeat` and `loop` are free. The two exceptions,
   `fade-in` and `fade-out`, are one-way and have their own rule (`hold`).
   A canvas effect is a single envelope: it builds up, stays, clears.
4. **A trigger whose sticker is not on the canvas simply does not fire.** The
   story is authored once; which effects happen depends on what the
   child placed — and on the stickers the story brings in when it first
   names them ("Entrances"), which are on the stage from then on. Write stories that still make sense when half the effects
   are silent, and never make a narration beat depend on an effect. (Canvas
   effects always fire — but the same rule of never depending on them holds.)
5. **Unknown content is ignored, never fatal.** An unknown effect name is
   skipped with a log line; a pack authored against a future library plays
   with fewer effects.

## The sticker library (12 effects, closed)

`i` is the trigger's `intensity` (default 0.6). At `intensity: 0` every effect
is visually identical to no effect. Anchors and easing are fixed per effect —
they are what make a wobble a wobble — and are not authorable.

### Motion

| Effect | What it looks like | Good for | Default cycle | Reduce Motion |
|---|---|---|---|---|
| `pulse` | One gentle size beat about the centre. | "Look at this one" — the sticker being talked about. | 0.5 s | runs at ≤0.3 |
| `wobble` | Tilts side to side (±8°·i) around its **base**. | Reactions: surprise, laughter, a sneeze, being bumped. | 0.6 s | runs at ≤0.3 |
| `shake` | Fast, small horizontal tremble (±4 %·i of its width, ~12 per second). | Shivering, nerves, giggling, an engine. | 0.5 s | dropped |
| `hop` | One arc up (½·i of its height) and back down. | Joy, a jump, hello. `repeat: 2–3` for bouncing. | 0.6 s | dropped |
| `spin` | One full clockwise turn about the centre. Intensity does not change it (0 disables). | Twirling, dizziness, a tumble. | 0.9 s | dropped |
| `float` | Very slow vertical bob (±6 %·i of height), seamless when looped. | Anything airborne or afloat. Use `"repeat": "loop"`. The only scenery loop: trees and flowers stay still. | 3.0 s | dropped |

### Opacity and colour

| Effect | What it looks like | Good for | Default cycle | Reduce Motion |
|---|---|---|---|---|
| `fade-in` | Appears from nothing. **One-way.** | Arrivals, waking up. Pair with `sparkle`. | 0.6 s | full |
| `fade-out` | Fades away. **One-way.** | Leaving, hiding, falling asleep. `hold: true` keeps it gone. | 0.6 s | full |
| `glow` | A soft bloom rises around the sticker and falls away. `color` default `#FFF3C4`. | Magic, warmth, a wish, the sun. `hold: true` keeps the bloom on. | 1.0 s | full |
| `tint` | A colour washes over the sticker and drains away. `color` **required**. | Blushing (pink), cold (blue), cross (red). White + `duration: 0.2` is a flash. | 0.8 s | full |

### Particles

| Effect | What it looks like | Good for | Default cycle | Reduce Motion |
|---|---|---|---|---|
| `sparkle` | A shower of twinkles above the sticker. `color` default warm gold `#FFD166`. | Delight, magic, treasure, a good idea. | 1.0 s | runs at ≤0.4 |
| `hearts` | A few hearts drift up. | Friendship, a hug, kindness. | 1.2 s | runs at ≤0.4 |

Particles already born live out their lifetime after the effect ends; that
is intended. Particle size follows the sticker's rendered size, so sparkles
on a tiny flower are tiny.

### Deliberately not in the library

Removed in 2026-09 and not to be reused (older content that names them is
skipped): `sway` (a slow tilt of trees and flowers — it read as the scenery
wobbling), `blink` (hard-edged flashing) and `puff` (smoke at the feet).

Recorded so nobody re-adds them by accident: entrances/exits beyond fade,
squash and stretch, keyframe authoring, scene shake and parallax,
background-layer targeting, z-order and flip changes, blur, saturation,
brightness, shimmer, halo, composite presets, pack-custom emitters. Weather
and light over the scene are the canvas effects below — that list is closed
too. Removed in 2026-09 and not to be reused: `planetrise` and `seasnow`.
Considered for it and turned down (2026-09): `nightlight` (stars
turning on a bedroom wall), `aurora` in space, thunder and lightning
(flashes are a light-sensitivity risk and storms frighten small children),
a "zero gravity" effect that floats every sticker (canvas effects never move
stickers; `float` does that per sticker), and effects that belong to one
pack only. Character animation — a sticker's own frames — is a separate
system that shares the clock and the trigger file but not this vocabulary
("Live animations" below).

## Sticker effect parameters (the whole surface)

| Key | Required | Default | Meaning |
|---|---|---|---|
| `effect` | yes | | One of the 12 names above. |
| `sticker` | yes | | Sticker ID from the manifest, or `all` for every sticker on the canvas. Every placed instance is affected. |
| `at` | yes | | Seconds into **this language's** narration when the effect starts. |
| `cue` | no | | Free label for authoring traceability (the word it lines up with). The app ignores it. |
| `repeat` | no | `1` | `n` cycles (1–50) or `"loop"` until playback ends. Ignored by `fade-in` / `fade-out`. |
| `duration` | no | per effect | Seconds for **one cycle**, 0.05–30. Total time = `duration × repeat`. |
| `intensity` | no | `0.6` | 0–1. Scales amplitude (and particle birth rate + size), never speed. |
| `color` | no | per effect | `"#RRGGBB"`. Read by `glow`, `tint`, `sparkle` only; required by `tint`. |
| `hold` | no | `false` | Keep the end state until playback ends. `fade-in`/`fade-out`/`glow`/`tint` only. |

### Repeat, stop, hold

- Cycles run back to back; after the last one the sticker is back at its
  placement. There is no autoreverse or direction — a cycle is a cycle.
- A looping effect ends when playback ends. Stopping an effect early eases
  it back over at most 0.25 s; cancelling playback snaps everything back.
- `hold` on `fade-out` keeps the sticker invisible until playback ends (then
  it is restored). Without `hold` a `fade-out` fades back in when it ends.
  `hold` on `glow`/`tint` turns the cycle into a rise to the peak (taking the
  full `duration`) that then stays on.
- Two effects on one sticker at once compose: scale and opacity multiply,
  rotation and offsets add, glow/tint take the max, colours and the pivot go
  to the later-started effect. Two glows never stack into a blowout.

## Canvas effects (closed)

Weather and light over the **whole scene**: they draw over the art and the
stickers (the rainbow, the moon and the stars sit behind the foreground
art, in the sky; the darkness of `night` is over everything) and never
move a sticker. Where a sticker effect is a cycle, a canvas effect is one
**envelope**: it builds up over its ramp-in, stays at full strength, and
clears over its ramp-out — then it is gone. There is no repeat, no colour,
no hold; content controls **`intensity`** (how much: thin or thick fog,
drizzle or downpour) and **`duration`** (how long it stays, ramps
included).

Each canvas effect suits one or more pack **`setting`**s
(`docs/pack-format.md`: `outdoors`, `indoors`, `space`, `underwater` or
`none`). Because these effects *are* the weather and the sky lights, a
pack's art paints none of its own — an outdoors pack paints no sun, moon,
stars, rays, rainbow, rain or mist, and space and underwater packs have
their own list (`docs/pack-format.md`, "Art safe area"). A rain trigger in
an indoors pack is an
error for the packager and is skipped by the app; a `none` pack (abstract
or fantastical places) gets no canvas effects at all.

| Effect | Setting | What it looks like | Good for | Default duration | Ramp in / out | Reduce Motion |
|---|---|---|---|---|---|---|
| `fog` | outdoors | Soft mist drifting slowly across the whole scene. | Early morning, a mystery, hush, something hidden then found. Builds slowly — cue it a beat early. | 12 s | 2.5 / 2.5 s | full |
| `rain` | outdoors | Rain falls over everything; the light cools a little. | Rain in the story: pitter-patter, puddles, sheltering. `intensity` is drizzle to downpour. | 10 s | 1.2 / 1.5 s | runs at ≤0.4 |
| `sunshine` | outdoors | Warm light across the top of the scene, soft shafts drifting down. | The sun comes out, a warm afternoon, waking up, a happy ending after rain. | 8 s | 1.5 / 1.5 s | full |
| `rainbow` | outdoors | A soft rainbow arcs across the sky behind the scenery. | The reward after rain, a wish come true, a wonder everyone looks up at. One per story at most. | 8 s | 2 / 2 s | full |
| `night` | outdoors | Night falls: the scene darkens and a moon glows in the sky. | Evening and bedtime outdoors, the moon coming up, stars, a story that settles to sleep. Never darkness as a threat. Builds slowly — cue it a beat early. | 10 s | 2 / 2 s | full |
| `snow` | outdoors | Soft snowflakes drift down at different sizes and speeds; the top of the sky turns white (behind the scenery) and the light a little cooler and brighter. | Winter, a snow day, the first flakes, a quiet hush. `intensity` is a few flakes to a thick flurry. | 12 s | 2 / 2.5 s | runs at ≤0.4 |
| `sunset` | outdoors | A warm orange-pink glow spreads from the horizon while the top of the sky deepens to violet. | The end of the day, going home, a calm golden moment. Followed by `night` it makes a gentle bedtime. Builds slowly — cue it a beat early. | 10 s | 2.5 / 2.5 s | full |
| `clouds` | outdoors | Big soft clouds drift slowly across the sky behind the scenery; the light dims a little. | A cloudy day, "a cloud shaped like…", the grey before rain, the sun going in. | 12 s | 2.5 / 2.5 s | full |
| `wind` | outdoors | Pale wisps of air sweep across the scene from left to right, with a few specks tumbling along. | A windy day, a kite, something blown away, a whoosh. `intensity` is a breeze to a gust. | 8 s | 1 / 1.5 s | runs at ≤0.4 |
| `fireflies` | outdoors | Tiny warm lights drift and pulse slowly, mostly in the lower half of the scene. | A summer evening, a little magic in the dark, lighting the way. Lovely layered over `night` or `sunset`. | 12 s | 2 / 2 s | runs at ≤0.4 |
| `leaves` | outdoors | Autumn leaves in warm colours flutter down, turning over and drifting sideways. | Autumn, a gust shaking the trees, change, a leaf pile. Only for packs whose scenery has trees. | 10 s | 1.5 / 2 s | runs at ≤0.4 |
| `dimlight` | indoors | The lights go low: the scene darkens toward its edges. | Bedtime, a lamp switched low, a cosy evening, a whispered secret. Never darkness as a threat. | 8 s | 1.5 / 1.5 s | full |
| `windowlight` | indoors | A slanted shaft of sunlight falls across the room from the top left, with dust motes turning slowly in it. | Morning, waking up, a lazy sunny afternoon, the sun coming out while everyone is inside. | 10 s | 2 / 2 s | full |
| `firelight` | indoors | A warm glow from below flickers slowly and gently (never a strobe) while the edges of the room dim. | A fireplace, birthday candles, a cosy evening, telling stories together. Never a fire as a danger. | 10 s | 2 / 2 s | full |
| `rainywindow` | indoors | The room turns cool and grey while faint raindrops trickle down, as if seen through a window. | A rainy day indoors, waiting for the rain to stop, a quiet day inside. | 12 s | 2 / 2 s | runs at ≤0.4 |
| `confetti` | outdoors, indoors, space | A shower of colourful confetti flutters down over the whole scene. | A birthday, a party, a "hooray!", a happy ending. One per story at most. | 6 s | 0.5 / 1.5 s | runs at ≤0.4 |
| `bubbles` | outdoors, indoors, space, underwater | Round bubbles float up from the bottom and wobble as they rise. | Bath time, washing up, blowing bubbles, a party; under the sea, a fish talking or something bubbling up. | 8 s | 1 / 1.5 s | runs at ≤0.4 |
| `shootingstars` | space | Now and then a shooting star streaks across the sky behind the scenery. | Making a wish, wonder, "look!". `intensity` is a single one now and then to a meteor shower. | 10 s | 1 / 1.5 s | runs at ≤0.4 |
| `nebula` | space | Soft purple, pink and teal clouds of light swell and drift across the sky behind the scenery. | A magical place, wonder, drifting far from home, a dreamy moment. Builds slowly — cue it a beat early. | 12 s | 3 / 3 s | full |
| `warp` | space | Stars stretch into streaks rushing out from the centre, in the sky behind the stickers and the scenery. | Blast-off, zooming to a new planet, "whoosh!". Short — a few seconds is plenty. | 4 s | 0.6 / 1 s | does not run |
| `comet` | space | A comet with a long glowing tail glides slowly across the sky behind the scenery. | A visitor, following something, a slow moment of wonder. Calmer than `shootingstars`. | 12 s | 1.5 / 2 s | full |
| `sunrays` | underwater | Shafts of sunlight slant down through the water from the surface and sway slowly. | A bright, happy day under the sea, swimming up towards the light, the sun coming out above. | 10 s | 2 / 2 s | full |
| `ripples` | underwater | A net of rippling light plays over the whole scene, brightest near the sea floor. | Shallow water, a sunny lagoon, calm and playful. Layers nicely with `sunrays`. | 12 s | 2 / 2 s | full |
| `deepwater` | underwater | The water darkens to a deep blue, most of all toward the edges and the surface. | Diving deeper, exploring, bedtime under the sea. Never darkness as a threat. Builds slowly — cue it a beat early. | 12 s | 2.5 / 2.5 s | full |
| `glowplankton` | underwater | Tiny blue-green lights twinkle and drift slowly through the water. | A little magic in the dark sea, a night swim. Lovely layered over `deepwater`. | 12 s | 2 / 2 s | runs at ≤0.4 |
| `current` | underwater | A gentle current sweeps specks, wisps and bits of green across the scene from left to right. | Swimming along, being carried away, a whoosh under the sea. `intensity` is a drift to a strong current. | 8 s | 1.2 / 1.5 s | runs at ≤0.4 |
| `sandcloud` | underwater | A cloud of sand swirls up from the sea floor and slowly settles again. | Something stirs, hide and seek, a big fish swishing past, digging in the sand. | 6 s | 1.5 / 2.5 s | runs at ≤0.4 |

- Ramps never eat more than a third of the duration each, so a 3 s effect
  still spends a second at full strength.
- Two canvas effects of the same kind overlapping are one effect at the
  stronger intensity — never a downpour. Different kinds simply stack
  (rain, then sunshine and a rainbow as it clears, is the classic).
- Stopping playback clears everything at once; a story ending naturally
  lets a running effect fade with the audio.

### Canvas effect parameters

| Key | Required | Default | Meaning |
|---|---|---|---|
| `effect` | yes | | One of the names above. A canvas trigger has **no `sticker`**. |
| `at` | yes | | Seconds into this language's narration when the effect starts building up. |
| `cue` | no | | Free authoring label; the app ignores it. |
| `intensity` | no | `0.6` | 0–1. How strong. 0 is visually identical to no effect. |
| `duration` | no | per effect | Seconds the effect stays on, ramps included, 1–120. |

## Trigger file

Each story localization may point at one sidecar next to its audio
(`docs/pack-format.md`, `localizations[].effects`). Times are per language
because each narration has its own timing. One `triggers` list carries five
kinds: an entry whose `effect` is a sticker effect targets a `sticker` (or
`all`); one whose `effect` is a canvas effect has none; one with an
`animation` and no `effect` plays that sticker's live animation, whole or
(`mode`) up to its pause frame or on from it ("Live animations" below); one with an `expression` and no `effect` changes a
sticker's face, or everyone's ("Faces" below); one with `"enter": true`
marks where the story first names a sticker ("Entrances" below); one with
`"go"` moves a sticker ("Movement" below).

`packs/forest/audio/en-US/shy-mushroom.effects.json`:

```json
{
  "schema": 1,
  "triggers": [
    { "at": 0.0,  "cue": "start",   "sticker": "bird",     "effect": "float",    "repeat": "loop" },
    { "at": 3.2,  "cue": "sneeze",  "sticker": "fox",      "effect": "wobble",   "repeat": 3 },
    { "at": 3.2,  "cue": "sneeze",  "sticker": "fox",      "effect": "sparkle",  "intensity": 0.8 },
    { "at": 8.0,  "cue": "rain",                            "effect": "rain",     "intensity": 0.7, "duration": 14 },
    { "at": 12.5, "cue": "blush",   "sticker": "mushroom", "effect": "tint",     "color": "#FFB3C6" },
    { "at": 24.0, "cue": "sun",                             "effect": "sunshine" },
    { "at": 26.4, "cue": "smiled",  "sticker": "mushroom", "expression": "happy" },
    { "at": 28.0, "cue": "everyone","sticker": "all",      "effect": "hop" },
    { "at": 30.2, "cue": "yawned",  "sticker": "bear",     "animation": "yawn" },
    { "at": 31.0, "cue": "hid",     "sticker": "snail",    "animation": "hide", "mode": "hold" },
    { "at": 38.4, "cue": "peeked",  "sticker": "snail",    "animation": "hide", "mode": "resume" },    { "at": 33.0, "cue": "owl",     "sticker": "owl",      "enter": true },
    { "at": 36.5, "cue": "flew",    "sticker": "bee",      "go": "on", "target": "flower" },
    { "at": 41.5, "cue": "flies",   "sticker": "bird",     "effect": "fade-out", "hold": true }
  ]
}
```

- `schema` is an integer; the app rejects a file with a schema it does not
  know (the story is then excluded from selection, never an error screen).
  Adding an effect is **not** a schema change — unknown names are skipped.
- Validation is two-tier. `packager validate` is strict: unknown effect
  names, unknown keys, out-of-range numbers, undeclared stickers, `repeat`
  on a one-way effect, `color`/`hold` on effects that ignore them, `tint`
  without a colour, sticker keys on a canvas effect, a canvas effect
  that does not suit the pack's `setting`, a live trigger naming an
  action its sticker does not declare (or a move, or carrying effect
  keys), and a `hold`/`resume` on an action without a pause frame are all
  errors. The app is
  lenient: it skips or clamps and logs. A pack that passes the packager
  never triggers a log.
- Triggers are evaluated in time order; several may share an `at`.

### Authoring guidance

- Lead with meaning, not decoration: one effect per story beat, on the
  sticker the sentence is about. `pulse` when a character is introduced,
  `wobble` when something happens to it, `hop` for joy, `sparkle` for magic.
- A `float` loop on anything airborne (butterflies, bees, birds) at `at: 0`
  gives the canvas quiet life for the whole story; keep intensity low
  (≤0.5). Trees and flowers do not move on their own.
- Prefer default intensities and durations. `duration` is for pacing an
  effect to the narration (a slow `pulse` on "sloooowly"), not for extremes.
- Never rely on an effect: the sticker may not be on the canvas.
- Never flash more than three times a second (a white `tint` is a flash);
  prefer `glow` or `sparkle` for magic.
- Canvas effects **follow the words**: whenever the story's text puts
  weather or light into the scene that the setting can show, it is cued
  (`storycheck` warns on a mentioned but uncued one), and never when the
  words don't describe it; at most three per story. They should never be a
  substitute for the stickers reacting.
- Every language needs its own file; only the `at` values should differ.

### Inline cues in story text (authoring format)

Stories are authored with cues inline in the text
(`tools/author/stories/FORMAT.md`), so authors think in words, not seconds:

```
The fox gave an enormous {fox:wobble x3} {fox:sparkle} sneeze.
Plip, plop — {canvas:rain 0.7 14s} here comes the rain.
Bear gave a {bear:live} great big yawn.
Snail {snail:live hold} hid in his shell… and waited… then {snail:live resume} peeked out.
Mushroom {mushroom:face happy} smiled. And {all:face sleeping} everyone fell asleep.
```

A cue fires on the word that follows it; `canvas:` is the reserved target
for canvas effects, `live` the reserved effect that plays a sticker's live
action (`{bear:live}`, `{owl:live blink}` to name one of several, `{snail:live
hold}` / `{snail:live resume}` to stop on its pause frame and go on later),
`face` the reserved effect that changes a sticker's face (`{bear:face
happy}`, `{bear:face normal}`), `enter` the reserved effect that marks a
sticker's first mention (`{owl:enter} Owl`), `all` the reserved target for every
sticker on the canvas (`{all:hop}`, `{all:face sleeping}`) and
`go` the reserved effect that moves a sticker (`{fox:go to rabbit}`,
`{bee:go on flower}`, `{mouse:go under mushroom}`, `{frog:go to pond}`,
`{fox:go away}`, `{fox:go back}`) and `sfx:` for sound effects (which are mixed into the
audio, never triggers). The text may also carry Eleven v3 audio tags
(`[whispers]`) for the narrator. Step 2 of the authoring pipeline
(`storyaudio`) resolves each cue's `at` from the narration's word
timestamps and carries the word as `cue`, emitting the sidecar above. The
app never parses text.

## Live animations

Every sticker carries a **live action**: a short frame sequence drawn from
its own art — the snail hides in its shell, the frog catches a fly, the
bear cub yawns and nods off (`docs/pack-format.md`, "Live animations") —
and a **move** that entrances play ("Entrances" below). Each action's
sidecar says what it shows (`description`), how long it plays (`hold`s,
2–4 s) and, for most, the frame it can pause on (`pause.shows`: "the
snail tucked inside its shell"); `storycheck` lists them.

- Not an effect: no parameters, no repeat. The trigger is
  `{ "at", "cue"?, "sticker", "animation", "mode"? }`.
- **Whole** (no `mode`): from the rest pose through every frame and back.
- **`hold`**: up to the pause frame, and it stays there — for a sentence
  or to the end of the story — until a `resume` for that sticker (or
  another action on it, which takes over).
- **`resume`**: on from the pause frame to the end. After its `hold` the
  frames simply carry on; without one it dissolves in on the pause frame.
- What a sticker shows at any moment is the last live trigger for it up
  to then (`LiveTimeline`, pure: a seek is exact, and a trigger is never
  lost to a slow frame). The story's end brings the still sticker back.
- It plays on every placed instance of the sticker and inherits the
  sticker's placement and any running effect (a `float` loop carries it
  along). Sticker effects that *start* on the same sticker while it moves
  fight it; `storyaudio` warns about them. While it is held on its pause
  frame, effects are fine; a face change waits underneath and shows when
  it resumes (`storycheck` warns).
- A story loads only the sheets its triggers name for stickers on the
  canvas, and the moves of the stickers it brings in, off the main thread
  as play starts, and drops them when it ends. A trigger whose sheet is
  not in yet shows the still sticker until it is.
- Older apps skip the trigger (it has no `effect`) with a log line; an
  app that does not know `mode` plays a `hold` whole. No schema change.

## Faces

Stickers with a face carry expression variants (`docs/pack-format.md`,
"Expressions"): in Forest, `happy`, `sad`, `sleeping` and `surprised`
besides the sticker's own `normal` face. An expression trigger
`{ "at", "cue"?, "sticker": "bear" | "all", "expression": "happy" }`
changes the face from that moment on:

- **No duration.** A face stays until the next change for that sticker (or
  for `all`); `normal` goes back to the sticker's own face. The story's
  end resets every sticker to `normal`.
- **In place.** A variant has exactly the sticker's outline, so the app
  swaps the texture with a 0.25 s crossfade and nothing moves; sticker
  effects keep running on top. During a live animation the frames are on
  show and the new face is there when they hand back.
- **`all`** changes every sticker on the canvas; a sticker without that
  face keeps its own. A later change for one sticker overrides an earlier
  `all`, and vice versa: the face at any moment is the last change up to
  then that names the sticker or `all` (`ExpressionTimeline`, so seeking is
  exact).
- The story loads only the variants it will show for the stickers on the
  canvas, off the main thread at play start; until one is in, that sticker
  keeps its face.
- Faces are not motion: Reduce Motion and calm mode keep them.

## Entrances

A story names stickers the child may not have placed. So that the scene
shows what the narrator says, every featured and supporting sticker has
an **entrance** on the word that first names it: authored `{owl:enter}
Owl woke up`, the trigger `{ "at", "cue"?, "sticker", "enter": true }`,
one per sticker per story, never `all`.

- When play starts, the app looks at the story's entrances. A sticker the
  child already placed ignores its entrance. Every other one is a
  **visitor**: the app picks its spot — the freest place the window shows
  on the first of its manifest `stage`'s features that has room (a bird
  on the trees' branches, else in the sky), or else in its `area`
  (`docs/pack-format.md`, "Stage" and "Features"; `StagePlanner`), or
  any spot there when the canvas is crowded — and keeps it hidden there
  until its entrance.
- At its entrance it comes in as its stage says, playing its **move**:
  `hop` walks (or hops, or crawls) in from the nearer side of the screen
  (bigger or smaller at first as it walks away from or towards the
  viewer), its move's loop going round while it slides at the pace of its
  legs (`stride` sticker widths a loop, 1.2–6 s in all; a hopping move
  rises in one arc per loop) and its last frames settling it into its
  sticker pose as it arrives; `fly` glides in from the nearer side with
  its wings going; `grow` fades in and grows where it stands, or, with a
  sprout move, fades in and sprouts. A sticker whose move travels one way
  and has to come in the other is mirrored for the whole visit. Without a
  move it bounces in as before. Under Reduce Motion or calm mode it
  simply fades in (no frames).
- **Another way in**: a sticker with more than one move comes in its
  usual way (its first move) unless the story names another —
  `{ladybug:enter by fly}`, the trigger's `"by": "fly"`. It then comes in
  that way: a flying move glides in (`fly`), any other walks or hops in
  (`hop`), onto that move's `on` features when it has them (a duckling
  swimming in lands on the pond, a bird hopping in on the meadow), else
  onto its stage's.
- From then on a visitor is on the stage like any placed sticker: its
  effects, faces, live animation and `all` reach it (they compose with the
  entrance while it is still arriving). Cues on a visitor before its
  entrance play on a sticker nobody can see, so authors put the entrance
  first (loops and faces are fine: they carry on once it is in).
- Visitors are never part of the child's canvas: not saved, not undoable,
  and they fade out when the story ends or is stopped (P4 — the canvas
  snaps back to what the child placed).
- Older apps skip the trigger (it has no `effect`) with a log line, so no
  schema change was needed.

## Movement

A story can move any sticker that walks or flies (its manifest `stage`
entrance is `hop` or `fly`; things that grow — a flower, a mushroom — stay
put), placed by the child or visiting, when the words say it goes
somewhere. The trigger is `{ "at", "cue"?, "sticker", "go", "target"?, "by"?, "toward"? }`:

| `go` | `target` | where it goes |
|---|---|---|
| `to` | a sticker | beside it, on the side it comes from, a little overlapping, feet on the same line (a flyer hovers beside it) |
| `to` | a feature | the freest spot on screen in that place of the scene (`docs/pack-format.md`, "Features": the pond, the branches) |
| `on` | a sticker | on top of it: a bee on the flower's head |
| `under` | a sticker | under it, in front of its base: a mouse under the mushroom's cap |
| `away` | — | off the canvas by the nearer side; it is gone until it comes back |
| `back` | — | back to its own spot (where the child put it, or where it came in), in from the side it left by if it went away |

- **It travels as it enters**: walkers walk (their move frames looping)
  at the pace of their legs, hoppers leap once per loop, flyers glide with
  their wings going; it turns to face the way it goes (a squash through
  the turn) and keeps facing that way. The time is not authored: it
  follows the distance and the sticker's gait (0.8–5 s; a flight
  1.2–3.4 s). A move cued while an earlier one (or its entrance) is still
  under way starts when that ends.
- **Where an action happens**: an action with a `place` (the woodpecker
  taps only on a trunk; `docs/pack-format.md`, "Live animations") gets a
  move of its own from the app (`PlacementPlanner`): to the nearest spot
  on that place — on a feature area with `facing`, its front on it (the
  beak on the bark), facing it — unless the sticker is there already,
  just after its last story move before the action; the action waits
  until it arrives. A child's woodpecker put on the meadow flies to a
  trunk before it taps. A story sending a sticker to a place it is at
  already (`{woodpecker:go to trunks}` "on to the next tree") takes it to
  another area of that place. Entrances onto a facing area come in from
  the side that has them arrive facing it.
- **Which way across the screen**: `toward` (`left` or `right`, on `to`
  and `away` only) says the way it goes when the story says — above all
  what the wind carries, which goes right, the way the `wind` canvas
  effect blows: `away` leaves by that side, `to` a place lands on the
  part of it at least a sticker's width that way (or its far end), `to`
  a sticker stands on that side of it. Authored `{leaf:go away right}`.
- **The way the words say**: a sticker that gets about more than one way
  (`docs/pack-format.md`, "Live animations": the ladybug crawls and
  flies, the bird flies and hops, the duckling waddles and swims) goes its
  usual way — its first move — unless the trigger names another with
  `by` (`{ladybug:go on flower by fly}` → `"by": "fly"`): then that
  move's frames play and it travels that way — a flying move glides and
  hovers beside whom it goes to, any other walks or hops on the ground.
  The next move goes the usual way again unless it names one too (so
  `{ladybug:go back by fly}` to fly home); a shuffle to make room goes
  the way the sticker last went.
- **On or under**, the mover is at least 35 % smaller than the sticker it
  goes on or under — at most 65 % of its size (a sticker already that
  small keeps its size) — and going `to` anything else brings it back to
  its own size.
- **They share the spot**: everyone on (or under) the same sticker stands
  in one row centred on it, each overlapping the next by a quarter of the
  narrower one's width — tucked in together, a little squashed, all still
  easy to see. When another comes, the ones already there shuffle over to
  make room (it joins on the side it comes from); when one leaves, the
  rest close up. Near a screen edge the whole row is pushed back in.
  Two going *beside* the same sticker take its two sides, then further
  out.
- **Always wholly on screen**: every place a move ends is pushed in from
  any edge it would cross — on or under a sticker near the edge, that
  means more overlap, never a cut-off sticker. Only `away` leaves.
- **Behind on the way, in front on arrival**: a sticker that sets off goes
  behind the other stickers in its layer, so it passes behind whoever is
  in its way; when it gets to the sticker it goes to — beside it, on it,
  under it — it comes in front of it (in the front sticker layer if
  either of them is there) and stays there. Going `back` it returns to
  its own layer and place in the stack; off the canvas or to a place in
  the scene it stays behind; a friend shuffling over to make room keeps
  its place (`MotionLeg.Stacking`). The layers and order the child made
  come back when the story ends.
- It moves every instance of that sticker on the stage; `to`, `on` and
  `under` go to the nearest instance of the target. A target that is not
  on the stage (never placed, never entered) is skipped, and so is the
  move.
- Effects, faces and live animations keep playing on a moving sticker;
  a live action cued during the travel takes over from the move frames.
- Under Reduce Motion or calm mode it fades out where it is and in where
  it goes (0.8 s), without frames or turning.
- The story's end puts every placed sticker back exactly where the child
  left it (P4); visitors leave.
- Older apps skip the trigger (it has no `effect`) with a log line. No
  schema change.

## Accessibility and calm mode

- **Reduce Motion** (system setting) is observed live: `shake`, `hop`,
  `spin` and `float` do not run, nor does the canvas effect `warp`; `pulse` and `wobble` run at
  intensity ≤0.3; particles and the canvas effects that fall or drift
  (`rain`, `snow` and the others marked in the canvas table) at ≤0.4;
  fades, `glow`, `tint` and the other canvas effects (slow washes of light)
  run in full because they carry story meaning.
- Live animations (whole-body motion: a curl-up, a walk) do not play
  under Reduce Motion or calm mode; the sticker stays still, and a held
  one never shows.
- **Calm mode** (main menu gear → Settings) applies the same policy plus a global
  intensity multiplier of 0.6, for children who are easily overstimulated.
- Flashes (white `tint`) are capped at 3 per second regardless of
  settings.

## How it runs (for app work)

`docs/effects-implementation-plan.md` maps the design onto the code. In
short: `StickerStoriesKit/Effects` holds both closed libraries, a pure
evaluator per kind (`(active effects, t) → delta per sticker instance`;
`(active canvas effects, t) → strength per canvas effect`), a runner per
kind that fires triggers and handles repeat/loop/hold/stop (stickers) or
the envelope and the pack setting (canvas), and the trigger decoder — all
unit-tested on macOS. The app target applies deltas to `StickerNode`s every
frame from the narrator's playback time (`Narrator.playbackTime`,
interpolated between resyncs), renders glow from a cached blurred mask,
drives two particle emitters (`sparkles`, `hearts`) defined in
`app/StickerStories/Effects/emitters.json`, and renders canvas effects in
`CanvasEffectLayer` (a rain emitter, drifting fog sprites, a sky glow with light shafts, a
rainbow arc, a vignette and a moon with a halo, all procedurally textured, sized to the pack's
art frame — the tuning numbers live in that file; every effect added after
the first six is a `CanvasEffectPainter` of its own in `Effects/Canvas/`,
placing its sprites from the timeline time so it needs no emitter). The DEBUG-only gallery
(Settings → Effects gallery in debug builds) plays every sticker effect on
a real sticker at three intensities and every canvas effect over the pack's
art, for tuning. Its sibling, the story gallery (Settings → Story gallery), plays any
story of any installed pack on an empty, unsaved canvas at 1×, 2× or 3×
(`RateNarrator`: the narration through AVAudioEngine, pitch kept; the
canvas follows the narration clock, the scene's actions and particles its
`speed`), in either language — for checking stories and how the stickers
behave in them. Launch arguments `-storyGallery [-storyGalleryPack forest]
[-storyGalleryPlay <story id>] [-storyGallerySpeed 3]` open it on the
simulator.
