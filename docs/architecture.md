# Architecture

## System overview

```
┌──────────────────────────────────────────────────────────────┐
│ App target: StickerStories (SwiftUI + SpriteKit, iOS 18+)    │
│                                                              │
│  StickerStoriesApp ─ RootView                                │
│    ├─ SpriteView(CanvasScene)      ← the heart: sticker play │
│    ├─ Play button + playback HUD   (SwiftUI overlays)        │
│    ├─ More stories card → ParentalGateView → StoreScreen     │
│    └─ Menu gear → ParentalGateView → SettingsView            │
│                                                              │
│  Adapters (platform-coupled):                                │
│    AudioFileNarrator (AVFoundation)                          │
│    StoreKitTransactionProvider, PurchaseService (StoreKit 2) │
│    PackLibrary (bundle + Application Support discovery)      │
├──────────────────────────────────────────────────────────────┤
│ StickerStoriesKit (local SwiftPM package, iOS + macOS)       │
│                                                              │
│  PackManifest (+ validate)   CanvasState (Codable snapshot)  │
│  PackLoader(directory:)      StoryProvider / Narrator seams  │
│  BundledStoryProvider        EntitlementStore (+ protocol    │
│  (scoring algorithm)          TransactionProvider)           │
└──────────────────────────────────────────────────────────────┘
            ▲  manifest schema contract (docs/pack-format.md)
            │
  tools/ (Go, dev-time only): packager validates & assembles packs;
  story-gen and tts produce content offline. Never ships.
```

### Why a local package?

All platform-independent logic (manifest decoding/validation, canvas state,
story selection, entitlement reconciliation) lives in `StickerStoriesKit`, which
also builds for macOS. `swift test` runs on the Mac host — fast, no simulator.
The app target contains only what genuinely needs UIKit/SpriteKit/StoreKit/
AVFoundation. This is our own code, not a third-party dependency.

## Key design decisions

1. **Tray lives inside the SpriteKit scene** (not SwiftUI). Dragging a sticker
   from the tray onto the canvas must be one continuous touch gesture with no
   SwiftUI→SpriteKit handoff. The scene owns all touch handling; SwiftUI owns
   everything that isn't the canvas (play button, HUD, parental areas).

2. **Layering model.** Two art planes ship with the pack and two sticker planes
   interleave with them, giving cheap depth:
   `background art < background stickers < foreground art < foreground stickers`.
   New stickers land on the foreground plane; "send to back" moves one to the
   background plane (behind the pack's foreground art, e.g. behind the trees).

3. **`CanvasState` is a first-class Codable model** — sticker instances with
   `stickerID`, normalized position (0–1 **of the pack's background art**, not
   of the screen), layer, z-order, scale, rotation. It is produced by the
   scene on demand and consumed by story selection. It never references
   SpriteKit types and serialises to JSON.

3a. **World + camera.** The art defines a fixed-aspect world scaled to cover
   the view; sticker positions and sizes are world-relative, so the child's
   arrangement is identical in every orientation and window size (iPadOS 26
   resizable windows, Split View, portrait). Horizontal overflow (portrait,
   Split View, narrow windows) can be panned with one finger on empty space
   (also during playback); the camera is clamped to the world and a one-shot
   drift hints that there is more. Vertical overflow — a view wider than the
   art, i.e. every full-screen landscape case, iPhone especially — is
   centre-cropped and never panned, so pack art keeps nothing important in
   its top and bottom bands. Packs designed for iPad can ship a **wide
   rendition** (`backgroundWide`/`foregroundWide`, same height, base art
   centred); `ArtVariant.select` (Kit, unit-tested) picks the rendition so
   a landscape window never pans — the least-cropping rendition no wider
   than the window, up to a 30 % crop — and a narrower window pans the
   least. iPads keep the base art, tall phones get the wide art. The base frame stays the
   sticker coordinate system either way (`docs/pack-format.md`, "Art safe
   area"). No windowing-mode detection is needed: the rule is purely
   geometric. The tray is a HUD: a plain scene child that follows the camera
   every frame (not a camera child — SpriteKit draws camera descendants
   below world content once the camera is off-centre), laid out to always
   fit fully between the back button and the undo/redo/clear cluster,
   shrinking its items in very narrow windows rather than overlapping them.
   Touches on the pill between stickers scroll the tray, never the world.

4. **Story selection** (`BundledStoryProvider`): a story is a candidate when at
   most one of its `requiredStickers` is missing from the canvas (and at least
   one is present) — stories read fine without any one sticker, and requiring
   all of them left most of a pack unreachable from an ordinary canvas. Score
   = present required + optional-sticker matches × manifest weight, well
   under a full match when one is missing. Candidates are ranked stalest
   first (never played, then longest ago; the app remembers a whole round),
   score second, and the pick is a weighted random among the top few
   (injectable RNG for deterministic tests): the best match is likely first
   on a fresh canvas and every candidate is heard before any repeats. Stories
   with no required stickers are always candidates, so play never fails.

5. **Entitlement enforcement happens at launch** (see `docs/commerce.md`):
   stored pack→transaction records are reconciled against StoreKit 2's current
   entitlements; revoked packs have their local assets deleted. `EntitlementStore`
   is pure logic over a `TransactionProvider` protocol so tests can simulate
   purchases/refunds without StoreKit.

6. **One loading path for all packs.** The bundled Forest pack is a folder
   reference in the app bundle; purchased packs will live in Application
   Support. Both go through `PackLoader(directory:)` — the bundled pack gets no
   special treatment, which keeps the purchased-pack path exercised from day one.

## Navigation

Three surfaces, one door out of the child experience:

- **Main menu** (`MainMenuView`) — the launch screen: one big card per
  available pack (horizontally paged) + a final "More stories" card.
- **Story screen** (`StoryScreen`) — the canvas + playback for one pack, with
  a back button guarded by a child-friendly confirmation, plus small
  undo/redo/clear controls. The canvas persists per pack (one JSON file
  under Application Support per `CanvasStateStore`, loaded when the scene
  first appears) — not required to survive uninstall. Undo/redo is an
  in-memory stack of `CanvasState` snapshots, reset each time the story
  screen is (re)entered; Clear is a deliberate, non-undoable reset (behind
  its own confirmation) that also empties that stack. No grown-ups access
  from here.
- **Store** (`StoreScreen`) — a full-screen section reached only via the
  menu's More stories card → parental gate: the "All Sticker Story Packs"
  bundle as a banner, then the packs as horizontally scrolling tiles (two
  columns always on screen, two rows on a big screen).
- **Parent settings** (`SettingsView`) — a sheet reached only via the gear in
  the menu's top right corner → parental gate (`AppSettings`: language
  override, calm mode; persisted in UserDefaults), plus Restore purchases.

Routing is a simple three-case screen enum in `RootView` (menu, story,
store) — no NavigationStack; the gate and settings are a sheet.

## Localization

Multilingual from day one — currently **en-US** and **es-ES**:

- **App UI**: `Localizable.xcstrings` (source `en`, translation `es`). iOS
  resolves the UI language from device settings / the per-app language
  setting; SwiftUI `Text`/`Label` literals localize automatically. A parent
  can also **override the language in-app** (menu gear → gate → Language):
  `AppSettings.languageOverride` feeds both `LanguageResolver` (narration)
  and an `\.environment(\.locale)` override (UI text, applied at the root and
  re-applied inside each sheet), switching live without relaunch. Keep
  user-facing strings as catalog keys rendered by `Text` — avoid
  `String(localized:)`, which ignores the environment locale.
- **Pack content**: every pack declares `languages` (first = fallback) and
  carries per-language display names, sticker names, and story
  title/text/audio — see `docs/pack-format.md`. `LanguageResolver` (Kit)
  matches `Locale.preferredLanguages` against the pack's languages
  (exact → primary subtag → pack fallback); the resolved tag flows through
  `StoryProvider.story(for:in:language:)` so the chosen `Story` already
  carries the right text and narration file. The `Narrator` seam is
  untouched — it plays whatever `Story` it is given.
- Both mechanisms follow the same device preference, so UI language and
  narration language agree whenever the pack supports the device language.
- Delivery (future): packs ship all languages today; if size ever forces a
  split, keep one download URL per pack + `lang=` query param
  (docs/pack-format.md, "Future: per-language delivery").

**Adding a language** touches four places, each with its own checks:

1. **App UI** — add it to `Localizable.xcstrings` and translate every key
   (no partial languages: the catalog is the whole UI).
2. **Settings** — add it to the language override choices in
   `SettingsView`.
3. **Pack content** — every pack's manifest gains it in `languages` and in
   every localized map (display name within 30 characters, sticker names, story
   title/text/audio); the packager rejects partial coverage
   (`docs/pack-format.md`, rule 4), and the stories need narration in that
   language (`tools/author/`).
4. **Store copy** — the product term, the in-app purchase names and
   descriptions within App Store Connect's limits, in App Store Connect and
   the StoreKit test configuration (`docs/commerce.md`, "Product copy").

## Gesture hints

Two canvas gestures are easy to miss: pinching a sticker (to scale or
turn it) and its layer button. Each has a wordless, ~6 s demo on a
sample sticker (`CanvasHintDemo`): a hand made with `uiart`
(`Art/hint-hand.webp`) pinches the sample bigger and turns it, or taps it
and then the real selection bubble's layer button so it slips behind
the foreground art and back. The scene plays them after 10 s with no
touch (`CanvasHintSchedule`, Kit, tested), outside stories and dialogs,
only for gestures the child has **never** used (app-wide flags in
UserDefaults, `UserDefaultsHintProgress`; local UI state, see
`docs/compliance.md`), each at most once per visit to a pack, both in a
row when both are due. Any touch cancels a demo at once. The sample is
never part of the canvas (not saved, not undoable); it goes where
`HintPlacement` scores best — open ground for the pinch, half over the
foreground art for the layer button. DEBUG: `-hintsDemo` shows both
after 3 s whatever the flags say.

## Effects (play mode)

While a story plays, individual stickers do small things — a wobble, a
sparkle, a glow — and now and then the whole scene changes: rain, fog,
sunshine, a rainbow, the lights going low. Both are driven by per-language
trigger files that ship with the pack. Authoring reference:
`docs/effects.md`; catalogue for tooling: `docs/effects/effects.json`;
design-to-code mapping: `docs/effects-implementation-plan.md`.

- **Effects exist only in play mode.** `StoryScreen` calls
  `CanvasScene.beginPlayMode` when `PlaybackController.phase` becomes
  `.playing` and `endPlayMode` when it leaves it. The scene locks editing,
  builds the runners + applier + emitter coordinator for that story, and
  tears them all down at the end, restoring every touched sticker verbatim
  and clearing the weather. A child who never presses play never sees any
  of it.
- **Kit (`Effects/`)**: the closed library of 12 `EffectDefinition`s, the
  pure `EffectEvaluator` (`(active effects, t) → EffectDelta` per sticker
  instance), `StickerEffectsRunner` (fires triggers, repeat/loop/hold, stop
  ease-back, seek rebuild), `EffectPolicy` (Reduce Motion / calm mode),
  `EffectTransformMath` (content anchors → SpriteKit pivots) and
  `EffectTriggerFile` (lenient sidecar decoding). Beside them the closed
  list of 5 `CanvasEffectDefinition`s, `CanvasEffectEvaluator` (an
  envelope: ramp in, hold, ramp out → strength per effect kind) and
  `CanvasEffectsRunner` (same tick/seek contract; drops triggers that do not
  suit the pack's `setting`). All unit-tested on macOS.
- **App (`Effects/`)**: `PlaybackClock` interpolates `Narrator.playbackTime`
  between resyncs; `EffectApplier` writes deltas onto `StickerNode`s
  (capturing each sticker's base placement on first touch — `snapshot()`
  reads that base, so a mid-effect save never captures a wobble);
  `GlowMaskCache` + `EmitterCoordinator` render glow and particles;
  `emitters.json` holds the emitter tuning; `CanvasEffectLayer` renders the
  canvas effects over the art frame (its own tuning numbers live in the
  file); `EffectsGalleryView` (DEBUG) is the tuning bench for both.
- **Seams kept honest**: `Narrator` gained one read-only property
  (`playbackTime`) — a synthesised narrator reports elapsed speech time and
  everything above it is unchanged. `StoryProvider` is untouched except that
  a story with an unusable sidecar is excluded from selection.

## Future: runtime generation (parked — design for it, don't build it)

v1 is fully pregenerated, but the app may later shift to runtime story
generation (on-device or hosted LLM receiving the canvas state) and on-device
TTS narration. The seams that make that pivot cheap:

- **`StoryProvider`** — input: `CanvasState` snapshot + pack context; output: a
  `Story` (text + narration reference). v1: `BundledStoryProvider` (scoring
  above). Future: a `GeneratedStoryProvider` slots in without touching canvas or
  playback code.
- **`Narrator`** — input: a `Story`; exposes preparing/playing/finished states
  and cancellation. v1: `AudioFileNarrator` plays the pack's pre-rendered file.
  Future: an on-device TTS narrator synthesises from `story.text`. Playback UI
  depends only on the protocol states, never on "an audio file is playing".
- **Stories carry text in the manifest**, not just audio references — the text
  is the portable representation any future narrator or prompt needs.
- **`CanvasState` is already the LLM prompt payload**: sticker IDs, coordinates,
  layer, z-order, scale — cleanly serialisable JSON from day one.

Keep these seams honest but do not over-engineer: two protocols, one concrete
implementation each, one serialisable canvas model. No plugin systems, no
speculative networking layer.
