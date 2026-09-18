# Sticker Stories — project memory

Sticker-canvas storytelling app for young children (4+): iPad first, iPhone equally
supported, no Mac target in v1. Kids drag stickers from a tray onto a two-layer
SpriteKit canvas; a play button picks one of ~100 pregenerated stories bundled with
the active sticker pack (scored against the canvas contents) and plays its
pre-rendered narration. Fully offline and deterministic after download. Sticker
packs are non-consumable IAPs (~1.99); one "Forest" pack ships bundled and free.

## Tech stack & hard constraints

- **Apple-only, Swift-only.** SwiftUI app shell, SpriteKit canvas (`CanvasScene`),
  StoreKit 2, AVFoundation. Swift 6 language mode. Minimum iOS/iPadOS **18**.
  Landscape-only. Bundle ID `com.anj.stickerstories`.
- **No third-party dependencies in the app target.** Ever. (`tools/` may use them.)
- **Kids Category compliance is non-negotiable**: no analytics, no ads, no data
  collection, no network calls from child-facing flows, purchases and external
  links only behind the parental gate. See `docs/compliance.md`.
- **Pack = versioned bundle** (manifest.json + art + audio). The manifest schema in
  `docs/pack-format.md` is the contract between `tools/` (Go) and the app (Swift);
  both validate it independently.
- **Multilingual from day one** (en-US, es-ES): app strings via
  `Localizable.xcstrings`; pack content (names, story text, narration audio) is
  per-language in the manifest with exact coverage validation; device language
  resolved by `LanguageResolver` with the pack's first language as fallback.
  New user-facing text must be added to the String Catalog with all languages.
- Entitlements: transaction IDs stored locally keyed by pack ID; validated against
  StoreKit 2 on every launch; revoked packs' assets deleted. See `docs/commerce.md`.
- IAP product IDs: `com.anj.stickerstories.pack.<packID>`, future all-access
  `com.anj.stickerstories.allaccess`.

## Build & test commands

```sh
# Core logic tests (fast, macOS host, no simulator)
cd app/StickerStoriesKit && swift test

# Tools tests + pack validation
cd tools && go test ./...
cd tools && go run ./packager validate ../packs/forest

# App build (simulator)
xcodebuild -project app/StickerStories.xcodeproj -scheme StickerStories \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' build
```

## Folder map

- `app/StickerStories/` — app target: SwiftUI shell, SpriteKit scene, StoreKit +
  AVFoundation adapters (platform-coupled code lives here).
- `app/StickerStoriesKit/` — local SwiftPM package: manifest models, `CanvasState`,
  story selection, entitlement logic + all unit tests (platform-independent code
  lives here; also builds on macOS so `swift test` needs no simulator).
- `app/StickerStories/Effects/` + `app/StickerStoriesKit/.../Effects/` — sticker
  effects (play-mode visual polish). Authoring reference `docs/effects.md`;
  machine-readable catalogue `docs/effects/effects.json` (pinned to code by
  tests — edit together). The 15-effect library is closed; see the doc before
  adding anything.
- `packs/<id>/` — pack source content; must always pass `packager validate`.
- `tools/` — Go module (dev-time only): `packager` (validation), `placeholdergen`
  (temporary placeholder assets), `story-gen` + `tts` (stubs for future pipeline).
- `docs/` — deep documentation; reference it, don't duplicate it here.

## Working rules

- Make minimal changes; do not refactor unrelated code.
- When unsure between two approaches, present both and let me choose.
- Never add third-party dependencies to the app target.
- Never weaken Kids Category compliance (no analytics, no network calls from
  child-facing flows, purchases only behind the parental gate).
- Any change to the pack manifest schema must update `docs/pack-format.md` and the
  packager validation in the same commit.
- Preserve the `StoryProvider` / `Narrator` seams and the Codable canvas-state
  model — story sourcing and narration must remain swappable (see
  `docs/architecture.md`, "Future: runtime generation").
- Run tests after changes to story selection, manifest, entitlement, or
  effects code.
- Separate commits per logical change.
