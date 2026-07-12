# Architecture

## System overview

```
┌──────────────────────────────────────────────────────────────┐
│ App target: StickerStories (SwiftUI + SpriteKit, iOS 18+)    │
│                                                              │
│  StickerStoriesApp ─ RootView                                │
│    ├─ SpriteView(CanvasScene)      ← the heart: sticker play │
│    ├─ Play button + playback HUD   (SwiftUI overlays)        │
│    └─ Grown-Ups button → ParentalGateView → GrownUpsView     │
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
   `stickerID`, normalized position (0–1 in canvas space), layer, z-order,
   scale, rotation. It is produced by the scene on demand and consumed by story
   selection. It never references SpriteKit types and serialises to JSON.

4. **Story selection** (`BundledStoryProvider`): a story is a candidate when its
   `requiredStickers` are all on the canvas. Score = optional-sticker matches
   + manifest weight − recently-played penalty. Weighted-random pick among the
   top candidates (injectable RNG for deterministic tests). Stories with no
   required stickers are always candidates, so play never fails.

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
  a back button guarded by a child-friendly confirmation (the canvas starts
  fresh on re-entry — restoring it is a roadmap item). No grown-ups access
  from here.
- **Grown-Ups area** — reachable only via More stories → parental gate.
  Contains the store and, behind a gear button, parent settings
  (`AppSettings`: language override; persisted in UserDefaults).

Routing is a simple two-case screen enum in `RootView` — no NavigationStack.

## Localization

Multilingual from day one — currently **en-US** and **es-ES**:

- **App UI**: `Localizable.xcstrings` (source `en`, translation `es`). iOS
  resolves the UI language from device settings / the per-app language
  setting; SwiftUI `Text`/`Label` literals localize automatically. A parent
  can also **override the language in-app** (Grown-Ups → gear → Language):
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
