# Sticker effects — implementation plan (Phase 0)

Status: **awaiting review** before Phase 1 starts. The design spec this plan
implements lives in the conversation that produced it; the authoring-facing
reference will be `docs/effects.md` (written in Phase 1 alongside the engine
and kept in sync from then on).

This document answers one question: how does the spec's target design map
onto the code that already exists, and where does it have to deviate?

## 1. What the repo already has (and what it does not)

| Spec concept | Repo today | Verdict |
|---|---|---|
| Sticker instance ID | `StickerNode.instanceID: UUID`, mirrored as `PlacedSticker.id` | ✅ use as-is (`StickerInstanceID = UUID`) |
| Placed transform ("base") | `StickerNode.baseScale` is the resting scale (lift/settle animations are relative to it); position and `zRotation` are written directly on the node | ⚠️ extend, see §3.2 |
| Per-frame hook driven by the audio clock | None. `CanvasScene` has no `update(_:)` override; editing uses fire-and-forget `SKAction`s | ➕ add `CanvasScene.update(_:)` that ticks the runner |
| Audio clock | `AudioFileNarrator` wraps `AVAudioPlayer` but the `Narrator` protocol exposes only `state`/`narrate`/`stop` | ➕ add a read-only playback time to the `Narrator` seam (§3.4) |
| Word-cue sidecar JSON | **Does not exist.** Stories carry `text` + `audio` per language; there is no timing data of any kind | ➕ Phase 3 needs a trigger carrier (§3.6). Cue resolution from text stays out of the app, as the spec wants |
| Sticker tags | None in the manifest (`docs/pack-format.md`) | Address triggers by sticker ID; every placed instance of that ID is a target (spec §4.4 "convenience" form). Tags can be added later, additively |
| Play/edit mode boundary | `PlaybackController.Phase` (`idle / choosing / playing / finished`), owned by `StoryScreen` next to the scene | ✅ Phase transitions are the on/off entry points |
| Accessibility settings | `AppSettings` (parent settings, UserDefaults) with one setting today | ➕ `calmMode` goes here; Reduce Motion read from UIKit |
| Testable core | `StickerStoriesKit` (pure Swift, builds on macOS, Swift Testing) | ✅ evaluator, runner, trigger parsing, policy all go here |

## 2. Module placement

The rule is the repo's existing one: platform-independent logic in the Kit,
SpriteKit/AVFoundation/UIKit adapters in the app target.

```
StickerStoriesKit/Sources/StickerStoriesKit/Effects/
  EffectName.swift          the closed enum of 15 names + category
  EffectDefinition.swift    per-effect curves (fixed anchor + easing), defaults
  EffectOptions.swift       repeatCount, duration, intensity, color, hold  (+ RGBA)
  EffectDelta.swift         the 7-field delta + compose rules + identity
  EffectEvaluator.swift     pure: ([ActiveEffect], t) -> [UUID: EffectDelta]
  StickerEffectsRunner.swift owns ActiveEffect[], play/stop/stopAll, ease-back,
                            retirement; ticked with a time, never a clock
  EffectPolicy.swift        Reduce Motion / calm mode as a transform over options
  EffectTrigger.swift       declarative form: decoding, clamping, non-fatal skips
  EffectTransformMath.swift anchor conversion + rotate/scale-about-pivot maths
StickerStoriesKit/Tests/StickerStoriesKitTests/
  EffectEvaluatorTests.swift, EffectRunnerTests.swift,
  EffectTriggerTests.swift, EffectTransformMathTests.swift

app/StickerStories/Effects/
  EffectApplier.swift       writes deltas onto StickerNode each frame; P4 restore
  PlaybackClock.swift       audio time + CACurrentMediaTime interpolation
  EmitterCoordinator.swift  the three SKEmitterNodes, budget, seek/pause  (Phase 2)
  emitters.json             emitter tuning data                            (Phase 2)
  GlowMaskCache.swift       pre-blurred alpha masks, one per sticker       (Phase 2)
  EffectsGalleryView.swift  DEBUG-only gallery                              (Phase 3)
```

Deviations from the spec's sketch, all naming/boundary only:

- `EffectDelta.anchor` is a Kit-local `EffectAnchor(x:y:)` (top-left origin,
  y down, as the spec defines) rather than `CGPoint`, so the Kit stays free
  of CoreGraphics semantics. The app converts at the boundary.
- `StickerEffectsRunner` is pure (it is *given* `t`), so it lives in the Kit
  and is unit-tested together with the evaluator. The spec's `StickerEffects`
  protocol is what the runner conforms to.
- `EffectApplier` and `EmitterCoordinator` are the only pieces that touch
  SpriteKit and are not unit-tested (they are exercised by the gallery).

## 3. Design decisions that need the reviewer's eye

### 3.1 Canvas is locked during play mode (spec open question 1)

**Recommendation: lock.** While `PlaybackController.phase != .idle`,
`CanvasScene` ignores touches (any in-flight drag/transform is ended as
cancelled when play starts) and `StoryScreen` disables undo/redo/clear. The
tray stays visible but inert.

Why: every editing gesture runs `SKAction`s on scale/alpha that would fight a
per-frame applier, and undo/redo rebuild the sticker nodes outright. Locking
sidesteps all of it and matches the spec's own suggestion for v1. Question 2
(add/remove mid-playback) is then moot; the suggested answer is recorded in
`docs/effects.md` for when the lock is revisited.

### 3.2 The "base" transform: capture per sticker at first effect, not a live read

The spec (§5.1) wants `base(instance)` to be a live read. With the canvas
locked there is nothing that can change it, so the plan is:

- `baseScale` stays the live source for scale (it already exists).
- When the **first** effect starts on a sticker, `EffectApplier` records that
  node's `position`, `zRotation`, `alpha` (and `colorBlendFactor`) as its
  `PlacementSnapshot`; while any effect is active the applier owns those
  properties; when the last effect on that sticker retires (or on `stopAll`)
  the snapshot is written back verbatim and discarded.
- Stickers that never receive an effect are never touched at all — that is
  what makes acceptance criterion 11 ("byte-identical") trivially true.
- On play start the applier also does one normalisation pass over every
  sticker: `removeAllActions()` and `setScale(baseScale)`, `alpha = 1`. A
  child who taps play 50 ms after dropping a sticker would otherwise freeze a
  landing "plop" mid-squash. These are the values the animations converge to
  anyway, so nothing the child chose is altered.

**Alternative** (if you would rather keep the door to an unlocked canvas
open now): give `StickerNode` a `placement` struct (position, rotation,
scale) that *all* editing code writes through, with the applier composing
`placement ⊕ delta` every frame. It is the cleaner model but touches ~12
write sites in `CanvasScene` for no v1 benefit. Not recommended for this
iteration.

### 3.3 Anchors without touching `anchorPoint`

Changing `SKSpriteNode.anchorPoint` shifts the sprite (and its shadow child
and hit-testing) — a wobble would visibly jump. Instead the applier keeps
`anchorPoint` at the centre and applies rotation/scale **about a pivot** by
correcting the position:

```
pivot p  = anchor converted to node-local offset from centre (SpriteKit y-up)
pos' = pos_base + R(rot_base)·p − S·R(rot_base + δrot)·p     (S = scaleMul)
```

This maths lives in `EffectTransformMath` (Kit) with the tests the spec
demands: bottom-centre stays fixed under `wobble`, centre stays fixed under
`spin`, and the y-flip conversion `[0.5, 1.0] → (0, −h/2)` is asserted.

### 3.4 Clock: one property added to the `Narrator` seam

`Narrator` gains `var playbackTime: TimeInterval? { get }` — `nil` unless
narration is playing. `AudioFileNarrator` returns `player.currentTime`. A
future TTS narrator returns elapsed speech time, so the seam stays honest
(`docs/architecture.md` will say so). `PlaybackClock` (app) wraps it:
resync every ~250 ms or when drift exceeds 40 ms, interpolate with
`CACurrentMediaTime` between resyncs, and fall back to a synthetic clock
started at `.playing` when the narrator reports `nil` (audio failed).

Pause/background: the app has no background-audio mode, so audio pauses on
suspend; SpriteKit stops calling `update(_:)` too. On return both resume from
the same audio time, so no special casing.

**Alternative:** a separate `PlaybackClock` protocol that `AudioFileNarrator`
adopts, leaving `Narrator` untouched. Slightly purer, one more type; either
is a small change. Recommend the property.

### 3.5 Effect definitions: Swift-canonical, JSON catalogue exported for tools

The spec asks for the 15 definitions in a bundled JSON data file. The curve
*shapes* (piecewise easing, sine, step, "ease out up / ease in down") cannot
be expressed in JSON without inventing the keyframe mini-language the spec
forbids exposing, and an iOS bundle needs a rebuild to change either way.

**Recommendation:** definitions live in Swift (`EffectDefinition.library`),
and the machine-readable catalogue that future story tools need is
`docs/effects/effects.json` — name, category, one-line description, default
duration, which parameters apply, `hold` support, Reduce-Motion behaviour. A
Kit test loads that file (relative to `#filePath`) and asserts it matches the
compiled library, so it cannot drift. `docs/effects.md` is the human version.

**Alternative:** JSON-canonical as spec'd, loaded via `Bundle.module` at
runtime, with only the *numbers* (amplitude, default duration, default
colour) in JSON and shapes keyed by a `kind`. Keeps "tweak numbers without
touching Swift" but adds a runtime load path and a second validation step.

Emitters (Phase 2) are genuinely parametric data, so `emitters.json` stays a
bundled data file as the spec describes.

### 3.6 Declarative triggers: a per-language sidecar next to the audio

There is no cue sidecar to attach to, and trigger times are per language
(the English and Spanish narrations differ in length). Proposed contract,
additive to manifest schema v2 (no `schemaVersion` bump per
`docs/pack-format.md` rules):

```json
"localizations": {
  "en-US": {
    "title": "…", "text": "…",
    "audio":   "audio/en-US/shy-mushroom.m4a",
    "effects": "audio/en-US/shy-mushroom.effects.json"     // optional
  }
}
```

```json
{
  "schema": 1,
  "triggers": [
    { "at": 3.20, "cue": "sneeze",  "sticker": "fox",  "effect": "wobble", "repeat": 3 },
    { "at": 3.20,                   "sticker": "fox",  "effect": "sparkle", "intensity": 0.8 },
    { "at": 0.00, "cue": "start",   "sticker": "tree", "effect": "sway",   "repeat": "loop" },
    { "at": 41.5, "cue": "flies",   "sticker": "bird", "effect": "fade-out", "hold": true }
  ]
}
```

- `at` is seconds into that language's narration; `cue` is an optional
  authoring label kept for traceability only. The app never resolves cues.
- Future tooling (`tools/story-gen` / `tools/tts`) will turn inline markup in
  the story text plus TTS word timestamps into this file; that pipeline is
  out of scope here and `docs/effects.md` will reserve a section for it.
- Validation is split exactly like the manifest: `packager` rejects a pack
  whose sidecar is malformed, names an unknown effect, references an
  undeclared sticker, or has out-of-range numbers (authoring time, strict).
  The app applies the spec's non-fatal rules at load (skip + log, clamp +
  log, malformed file ⇒ story excluded from selection).
- `Story` (Kit) gains `effectsPath: String?` next to `audioPath`.
  `BundledStoryProvider` excludes a story whose sidecar fails to decode.

**Alternative:** inline the trigger array in the manifest under each
localization. One file, but ~100 stories × 2 languages bloats the manifest
and a malformed trigger array would fail the whole pack, contradicting the
spec's "story excluded, never an error screen".

### 3.7 Hearts (spec open question 3)

Keep. Once `sparkle` and `puff` exist, `hearts` is one more emitter
definition and one texture; dropping it would change the closed library that
the docs and future tooling commit to.

## 4. Wiring (who calls what)

```
StoryScreen
  playback.phase → .playing(story)   : scene.beginPlayMode(story, clock: PlaybackClock(narrator))
  playback.phase → .idle/.finished   : scene.endPlayMode()      // P4: stopAll + restore, then tear down
CanvasScene
  beginPlayMode: lock touches, build StickerEffectsRunner(triggers, policy),
                 EffectApplier(nodes), EmitterCoordinator; normalise nodes
  update(_:)   : t = clock.now; runner.tick(t) → deltas; applier.apply(deltas);
                 emitters.reconcile(runner.active, t); runner.retire()
  endPlayMode  : applier.restoreAll(); emitters.clearAll(); drop everything; unlock
```

The runner fires triggers itself: on each tick it starts every not-yet-fired
trigger with `at <= t` whose sticker ID has ≥1 placed instance, once per
instance. Seeking is therefore "rebuild active set from triggers at t", which
is what makes criterion 6 hold. Triggers whose sticker is absent are skipped
silently (criterion 12) — no warning-level log.

`PlaybackController` is untouched except that `.playing` now carries a
`Story` with an `effectsPath`.

## 5. Prerequisites (small, done first inside Phase 1)

1. `Narrator.playbackTime` + `AudioFileNarrator` implementation.
2. `CanvasScene`: play-mode lock + `update(_:)` override + begin/end entry
   points. `StoryScreen`: disable history controls while playing.
3. `Story.effectsPath` (nil for every existing story; nothing else changes).

## 6. Phases

**Phase 1 — engine + 12 non-particle effects (no glow).** Kit: names,
definitions, delta, evaluator, runner (repeat / loop / stop-with-ease-back /
hold / retirement), transform maths, policy type (no UI yet). App: applier
for scale, rotation, offset, opacity, tint; clock; scene wiring; P4 restore.
Tests: criteria 1–7, 9, 10, 13 as Kit tests; 8 and 11 as Kit tests over the
applier's snapshot/restore logic factored into a pure helper. `docs/effects.md`
+ `docs/effects/effects.json` written here so the catalogue test exists from
day one. `docs/architecture.md` gets a short "Effects" section.

**Phase 2 — glow + particles.** Glow mask cache (CoreImage blur once per
sticker texture at pack load), additive glow sprite behind each affected
sticker; `emitters.json` + three emitters; textures generated with
CoreGraphics at first use (soft dot, four-point star, heart) so no asset
catalogue changes are needed in the hand-rolled pbxproj — swap for PNGs when
real art lands; `EmitterCoordinator` with seek/pause/budget rules.

**Phase 3 — content + polish.** Sidecar decoding (Kit) + packager validation
(Go, same commit as the `docs/pack-format.md` update); Reduce Motion
observation + `AppSettings.calmMode` (new Settings row, both languages in the
String Catalog); DEBUG-only effects gallery reachable from Settings; one or
two Forest stories get hand-written sidecars so the pipeline is exercised
end to end.

Separate commits per phase step (e.g. "kit: effect definitions + evaluator",
"app: effect applier + clock", "canvas: play-mode lock", …).

## 7. Things the spec asks for that this plan changes

| Spec | Plan | Why |
|---|---|---|
| Definitions loaded from bundled JSON | Swift-canonical, JSON catalogue in `docs/` verified by a test | curve shapes are code; the catalogue still exists for tooling (§3.5) |
| `base(instance)` live read | snapshot at first effect, restored verbatim | canvas locked; untouched stickers stay byte-identical (§3.2) |
| Triggers attached to the word-cue sidecar | new per-language `*.effects.json` with `at` seconds | no cue mechanism exists (§3.6) |
| `anchor: CGPoint` | `EffectAnchor` in Kit, converted in the applier | Kit stays platform-free |
| Emitter textures shipped at 2x/3x | generated with CoreGraphics for now | placeholder-art era; trivially swappable |
