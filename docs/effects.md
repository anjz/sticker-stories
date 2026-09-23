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
   story is authored once; which effects happen depends entirely on what the
   child placed. Write stories that still make sense when half the effects
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
too. Considered for it and turned down (2026-09): `nightlight` (stars
turning on a bedroom wall), `aurora` in space, thunder and lightning
(flashes are a light-sensitivity risk and storms frighten small children),
a "zero gravity" effect that floats every sticker (canvas effects never move
stickers; `float` does that per sticker), and effects that belong to one
pack only. Character animation is a later, separate system that will share
the clock but not this vocabulary.

## Sticker effect parameters (the whole surface)

| Key | Required | Default | Meaning |
|---|---|---|---|
| `effect` | yes | | One of the 12 names above. |
| `sticker` | yes | | Sticker ID from the manifest. Every placed instance is affected. |
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
| `snow` | outdoors | Soft snowflakes drift down at different sizes and speeds; the light turns a little cooler and brighter. | Winter, a snow day, the first flakes, a quiet hush. `intensity` is a few flakes to a thick flurry. | 12 s | 2 / 2.5 s | runs at ≤0.4 |
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
| `planetrise` | space | A big banded planet with a glowing rim rises slowly from behind the scenery, lighting the scene from below. | Arriving somewhere, a new day in space, "look at that planet!". Builds slowly — cue it a beat early. | 12 s | 3 / 3 s | full |
| `comet` | space | A comet with a long glowing tail glides slowly across the sky behind the scenery. | A visitor, following something, a slow moment of wonder. Calmer than `shootingstars`. | 12 s | 1.5 / 2 s | full |
| `sunrays` | underwater | Shafts of sunlight slant down through the water from the surface and sway slowly. | A bright, happy day under the sea, swimming up towards the light, the sun coming out above. | 10 s | 2 / 2 s | full |
| `ripples` | underwater | A net of rippling light plays over the whole scene, brightest near the sea floor. | Shallow water, a sunny lagoon, calm and playful. Layers nicely with `sunrays`. | 12 s | 2 / 2 s | full |
| `deepwater` | underwater | The water darkens to a deep blue, most of all toward the edges and the surface. | Diving deeper, exploring, bedtime under the sea. Never darkness as a threat. Builds slowly — cue it a beat early. | 12 s | 2.5 / 2.5 s | full |
| `glowplankton` | underwater | Tiny blue-green lights twinkle and drift slowly through the water. | A little magic in the dark sea, a night swim. Lovely layered over `deepwater`. | 12 s | 2 / 2 s | runs at ≤0.4 |
| `current` | underwater | A gentle current sweeps specks, wisps and bits of green across the scene from left to right. | Swimming along, being carried away, a whoosh under the sea. `intensity` is a drift to a strong current. | 8 s | 1.2 / 1.5 s | runs at ≤0.4 |
| `sandcloud` | underwater | A cloud of sand swirls up from the sea floor and slowly settles again. | Something stirs, hide and seek, a big fish swishing past, digging in the sand. | 6 s | 1.5 / 2.5 s | runs at ≤0.4 |
| `seasnow` | underwater | Soft pale specks drift slowly down through the water, with a faint haze. | Quiet, hush, drifting, the deep and still sea. Builds slowly — cue it a beat early. | 14 s | 2.5 / 2.5 s | full |

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
because each narration has its own timing. One `triggers` list carries both
kinds: an entry whose `effect` is a sticker effect targets a `sticker`; one
whose `effect` is a canvas effect has none.

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
  without a colour, sticker keys on a canvas effect, and a canvas effect
  that does not suit the pack's `setting` are all errors. The app is
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
- Canvas effects are **occasional**: only when the story's weather or light
  genuinely changes, at most one or two per story, in a minority of a
  pack's stories. Most stories have none. They should never be a substitute
  for the stickers reacting.
- Every language needs its own file; only the `at` values should differ.

### Inline cues in story text (authoring format)

Stories are authored with cues inline in the text
(`tools/author/stories/FORMAT.md`), so authors think in words, not seconds:

```
The fox gave an enormous {fox:wobble x3} {fox:sparkle} sneeze.
Plip, plop — {canvas:rain 0.7 14s} here comes the rain.
```

A cue fires on the word that follows it; `canvas:` is the reserved target
for canvas effects and `sfx:` for sound effects (which are mixed into the
audio, never triggers). The text may also carry Eleven v3 audio tags
(`[whispers]`) for the narrator. Step 2 of the authoring pipeline
(`storyaudio`) resolves each cue's `at` from the narration's word
timestamps and carries the word as `cue`, emitting the sidecar above. The
app never parses text.

## Accessibility and calm mode

- **Reduce Motion** (system setting) is observed live: `shake`, `hop`,
  `spin` and `float` do not run, nor does the canvas effect `warp`; `pulse` and `wobble` run at
  intensity ≤0.3; particles and the canvas effects that fall or drift
  (`rain`, `snow` and the others marked in the canvas table) at ≤0.4;
  fades, `glow`, `tint` and the other canvas effects (slow washes of light)
  run in full because they carry story meaning.
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
art, for tuning.
