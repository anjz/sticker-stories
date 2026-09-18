# Roadmap

## Iteration 1 — runnable core (current)

- [x] Repo scaffold: CLAUDE.md, README, docs/, .gitignore, git history started
- [x] Go tools module: `packager validate` v0 + tests; `placeholdergen`;
      story-gen/tts stubs
- [x] Forest starter pack: manifest v1, 9 placeholder stickers, background +
      foreground art, 10 placeholder stories with `say`-rendered audio,
      passes `packager validate`
- [x] Xcode project (hand-rolled pbxproj, synchronized folders) +
      StickerStoriesKit local package; app builds for iPad & iPhone simulators
- [x] Pack loading layer: manifest decoding + validation (mirrors packager),
      `PackLoader(directory:)`, bundled pack loads via the same path a
      purchased pack will; unit tests
- [x] Canvas: tray → canvas continuous drag & drop, sticker selection with
      outline + drop shadow, send-to-back, delete, landing animation, haptics
- [x] `CanvasState` Codable snapshot model
- [x] Story selection: scoring per docs/architecture.md, recently-played
      deprioritisation, fallback guarantee; unit tests
- [x] Playback: `Narrator` protocol + `AudioFileNarrator`, play button,
      playing-state HUD with stop
- [x] StoreKit 2 scaffolding: `EntitlementStore` + launch reconciliation +
      `Transaction.updates` listener + unit tests; `.storekit` testing config;
      parental gate; Grown-Ups area shell
- [x] PrivacyInfo.xcprivacy; compliance checklist satisfied
- [x] Runs and feels right on iPad **and** iPhone simulators

## Iteration 1.5 — shipped after initial review

- [x] Fix: background-layer stickers selectable again (hit-testing through
      the foreground art plane)
- [x] Larger selection controls + sticker rotation handle (snap-to-upright)
- [x] Parental gate switched to single-digit addition (see docs/compliance.md
      for the strength trade-off note)
- [x] Grown-Ups area redesigned as a canvas-style pack card gallery
- [x] Localization: en-US + es-ES end to end — manifest schema v2
      (per-language pack content + narration, exact coverage validation),
      LanguageResolver device matching, String Catalog for app UI, Spanish
      Forest pack content and `say` narration, es_ES StoreKit product copy

- [x] Main menu (pack cards + gated "More stories"), story back-confirmation
      flow, parent settings (gear in Grown-Ups) with in-app language override
- [x] Canvas persists per pack across leaving the story screen and closing
      the app (`CanvasStateStore`, file-backed); undo/redo (snapshot stack)
      and a confirmed, non-undoable Clear, as small secondary controls

## Iteration 1.6 — sticker effects

- [x] Sticker effects engine: closed library of 15 effects (motion, opacity/
      colour, particles) as deltas on the child's placement, pure evaluator
      + runner in the Kit with tests, play-mode-only pipeline in the scene
      with a hard restore on playback end (`docs/effects.md`)
- [x] Manifest: optional per-language `effects` sidecar; strict packager
      validation, lenient app decoding; Forest ships three sample stories
      with triggers
- [x] Calm mode (parent setting) + live Reduce Motion policy; flash cap
- [x] DEBUG effects gallery for tuning against real art
- [ ] Real emitter textures + tuning pass once real sticker art lands
- [ ] `story-gen`/`tts`: resolve inline text cues into sidecar `at` times
      from TTS word timestamps (`docs/effects.md`, "Future: inline cues")

## Iteration 2 — proposed

- [ ] Second pack ("Meadow") as a purchasable IAP end-to-end in the StoreKit
      testing environment: purchase → install → load; refund → assets removed
- [ ] Pack picker UI (child-safe) for switching between entitled packs
- [ ] `story-gen` v1: Claude API authoring pipeline producing manifest-ready
      story JSON from pack theme + sticker list
- [ ] `tts` v1: ElevenLabs batch rendering + loudness normalisation, replacing
      `say` placeholder audio
- [ ] App test target + StoreKitTest integration tests (purchase/refund flows)
- [ ] Real art direction pass for Forest pack

## Later

- [ ] All-access unlock (`…allaccess`) + upsell placement in Grown-Ups area
- [ ] Real TTS pipeline hardening (voice selection, per-story pacing)
- [ ] Per-sticker character animation (a sibling system to the effects
      layer, sharing its clock — see `docs/effects.md`, "Deliberately not in
      the library")
- [ ] Pack delivery decision: On-Demand Resources vs own CDN (revisit when
      pack count or sizes make bundling impractical; note ODR is
      Apple-hosted → still no server of ours)
- [ ] Mac delivery follow-through: v1 opts out of "Designed for iPad on Mac"
      (docs/compliance.md); revisit once iPad experience is polished
- [x] Orientation (2026-09): migrated off `UIRequiresFullScreen` per Apple
      TN3192 — iPad supports all orientations and resizable windows with a
      preferred minimum scene size; iPhone stays landscape-only. The canvas
      adapts (normalized sticker positions, fill-cropped art). A dedicated
      portrait composition (taller art, tray placement) is still open
- [x] World + camera canvas (2026-09): art-relative sticker positions, fill
      the window and pan the overflow with one finger, tray always fully
      visible — the arrangement is identical in every orientation and
      window size
- [ ] Localized App Store metadata (+ per-locale CFBundleDisplayName if the
      name ever differs)
- [ ] More languages; per-language pack delivery via base URL + `lang=` param
      if pack sizes demand it (docs/pack-format.md)
- [ ] Future: runtime story generation + on-device TTS behind the existing
      `StoryProvider`/`Narrator` seams (docs/architecture.md) — parked
