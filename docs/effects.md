# Sticker effects

Small, charming things a placed sticker does while a story plays: a sparkle,
a wobble, a glow, a fade. This is the reference for **authoring** them
(story tooling, hand-written packs) and the contract the app implements.

Machine-readable twin: [`effects/effects.json`](effects/effects.json) — same
names, defaults and parameter lists, pinned to the compiled library by a
test. Tooling should read that file rather than parse this one.

## The model in five rules

1. **Effects only exist in play mode.** Nothing runs while the child arranges
   the canvas. When play ends (audio finishes, the child stops it, or leaves),
   the canvas snaps back to exactly what the child placed.
2. **Effects are deltas on the child's placement.** A `pulse` on a sticker the
   child scaled to 1.7× beats from 1.7×; an effect never sets absolute values.
3. **Every effect is a closed cycle** (starts and ends at the placement), which
   is why `repeat` and `loop` are free. The two exceptions, `fade-in` and
   `fade-out`, are one-way and have their own rule (`hold`).
4. **A trigger whose sticker is not on the canvas simply does not fire.** The
   story is authored once; which effects happen depends entirely on what the
   child placed. Write stories that still make sense when half the effects
   are silent, and never make a narration beat depend on an effect.
5. **Unknown content is ignored, never fatal.** An unknown effect name is
   skipped with a log line; a pack authored against a future library plays
   with fewer effects.

## The library (15 effects, closed)

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
| `float` | Very slow vertical bob (±6 %·i of height), seamless when looped. | Anything airborne or afloat. Use `"repeat": "loop"`. | 3.0 s | dropped |
| `sway` | Very slow tilt (±3°·i) around its base, seamless when looped. | Wind through trees, flowers, grass. Use `"repeat": "loop"`. | 3.5 s | dropped |

### Opacity and colour

| Effect | What it looks like | Good for | Default cycle | Reduce Motion |
|---|---|---|---|---|
| `fade-in` | Appears from nothing. **One-way.** | Arrivals, waking up. Pair with `puff`. | 0.6 s | full |
| `fade-out` | Fades away. **One-way.** | Leaving, hiding, falling asleep. `hold: true` keeps it gone. | 0.6 s | full |
| `blink` | Vanishes and returns, hard-edged, twice per cycle (off-opacity is `1 − i`). | Magic, flicker, a firefly. Capped at 3 flashes/second. | 0.3 s | dropped |
| `glow` | A soft bloom rises around the sticker and falls away. `color` default `#FFF3C4`. | Magic, warmth, a wish, the sun. `hold: true` keeps the bloom on. | 1.0 s | full |
| `tint` | A colour washes over the sticker and drains away. `color` **required**. | Blushing (pink), cold (blue), cross (red). White + `duration: 0.2` is a flash. | 0.8 s | full |

### Particles

| Effect | What it looks like | Good for | Default cycle | Reduce Motion |
|---|---|---|---|---|
| `sparkle` | A shower of twinkles above the sticker. `color` default warm gold `#FFD166`. | Delight, magic, treasure, a good idea. | 1.0 s | runs at ≤0.4 |
| `puff` | A puff of smoke at its feet, behind the sticker. | Landing, appearing, disappearing, dust. | 0.6 s | runs at ≤0.4 |
| `hearts` | A few hearts drift up. | Friendship, a hug, kindness. | 1.2 s | runs at ≤0.4 |

Particles already born live out their lifetime after the effect ends; that
is intended. Particle size follows the sticker's rendered size, so sparkles
on a tiny flower are tiny.

### Deliberately not in the library

Recorded so nobody re-adds them by accident: entrances/exits beyond fade,
squash and stretch, keyframe authoring, scene-level effects (tint, dim,
shake, vignette, parallax), background-layer targeting, z-order and flip
changes, blur, saturation, brightness, shimmer, halo, rainbow, composite
presets, pack-custom emitters. Character animation is a later, separate
system that will share the clock but not this vocabulary.

## Parameters (the whole surface)

| Key | Required | Default | Meaning |
|---|---|---|---|
| `effect` | yes | | One of the 15 names above. |
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

## Trigger file

Each story localization may point at one sidecar next to its audio
(`docs/pack-format.md`, `localizations[].effects`). Times are per language
because each narration has its own timing.

`packs/forest/audio/en-US/shy-mushroom.effects.json`:

```json
{
  "schema": 1,
  "triggers": [
    { "at": 0.0,  "cue": "start",   "sticker": "tree",     "effect": "sway",     "repeat": "loop" },
    { "at": 3.2,  "cue": "sneeze",  "sticker": "fox",      "effect": "wobble",   "repeat": 3 },
    { "at": 3.2,  "cue": "sneeze",  "sticker": "fox",      "effect": "sparkle",  "intensity": 0.8 },
    { "at": 12.5, "cue": "blush",   "sticker": "mushroom", "effect": "tint",     "color": "#FFB3C6" },
    { "at": 41.5, "cue": "flies",   "sticker": "bird",     "effect": "fade-out", "hold": true }
  ]
}
```

- `schema` is an integer; the app rejects a file with a schema it does not
  know (the story is then excluded from selection, never an error screen).
  Adding an effect is **not** a schema change — unknown names are skipped.
- Validation is two-tier. `packager validate` is strict: unknown effect
  names, unknown keys, out-of-range numbers, undeclared stickers, `repeat`
  on a one-way effect, `color`/`hold` on effects that ignore them, and
  `tint` without a colour are all errors. The app is lenient: it skips or
  clamps and logs. A pack that passes the packager never triggers a log.
- Triggers are evaluated in time order; several may share an `at`.

### Authoring guidance

- Lead with meaning, not decoration: one effect per story beat, on the
  sticker the sentence is about. `pulse` when a character is introduced,
  `wobble` when something happens to it, `hop` for joy, `sparkle` for magic.
- Scenery loops (`sway` on trees, `float` on butterflies) at `at: 0` give the
  canvas quiet life for the whole story; keep intensity low (≤0.5).
- Prefer default intensities and durations. `duration` is for pacing an
  effect to the narration (a slow `pulse` on "sloooowly"), not for extremes.
- Never rely on an effect: the sticker may not be on the canvas.
- Never flash more than three times a second, and prefer `glow` to `blink`
  for magic — `blink` is dropped under Reduce Motion.
- Every language needs its own file; only the `at` values should differ.

### Inline cues in story text (authoring format)

Stories are authored with cues inline in the text
(`tools/author/stories/FORMAT.md`), so authors think in words, not seconds:

```
The fox gave an enormous {fox:wobble x3} {fox:sparkle} sneeze.
```

A cue fires on the word that follows it. Step 2 of the authoring pipeline
(not built yet) will resolve each cue's `at` from the narration's word
timestamps and carry the word as `cue`, emitting the sidecar above. The
app never parses text.

## Accessibility and calm mode

- **Reduce Motion** (system setting) is observed live: `shake`, `hop`,
  `spin`, `float`, `sway` and `blink` do not run; `pulse` and `wobble` run at
  intensity ≤0.3; particles at ≤0.4; fades, `glow` and `tint` run in full
  because they carry story meaning.
- **Calm mode** (Grown-Ups → Settings) applies the same policy plus a global
  intensity multiplier of 0.6, for children who are easily overstimulated.
- Flashes (`blink`, white `tint`) are capped at 3 per second regardless of
  settings.

## How it runs (for app work)

`docs/effects-implementation-plan.md` maps the design onto the code. In
short: `StickerStoriesKit/Effects` holds the closed library, a pure
evaluator (`(active effects, t) → delta per sticker instance`), the runner
that fires triggers and handles repeat/loop/hold/stop, and the trigger
decoder — all unit-tested on macOS. The app target applies deltas to
`StickerNode`s every frame from the narrator's playback time
(`Narrator.playbackTime`, interpolated between resyncs), renders glow from a
cached blurred mask, and drives three particle emitters (`sparkles`,
`smoke`, `hearts`) defined in `app/StickerStories/Effects/emitters.json`.
The DEBUG-only gallery (Settings → Effects gallery in debug builds) plays
every effect on a real sticker at three intensities for tuning.
