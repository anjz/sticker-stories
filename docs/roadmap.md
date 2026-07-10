# Roadmap

## Iteration 1 — runnable core (current)

- [ ] Repo scaffold: CLAUDE.md, README, docs/, .gitignore, git history started
- [ ] Go tools module: `packager validate` v0 + tests; `placeholdergen`;
      story-gen/tts stubs
- [ ] Forest starter pack: manifest v1, 9 placeholder stickers, background +
      foreground art, 10 placeholder stories with `say`-rendered audio,
      passes `packager validate`
- [ ] Xcode project (hand-rolled pbxproj, synchronized folders) +
      StickerStoriesKit local package; app builds for iPad & iPhone simulators
- [ ] Pack loading layer: manifest decoding + validation (mirrors packager),
      `PackLoader(directory:)`, bundled pack loads via the same path a
      purchased pack will; unit tests
- [ ] Canvas: tray → canvas continuous drag & drop, sticker selection with
      outline + drop shadow, send-to-back, delete, landing animation, haptics
- [ ] `CanvasState` Codable snapshot model
- [ ] Story selection: scoring per docs/architecture.md, recently-played
      deprioritisation, fallback guarantee; unit tests
- [ ] Playback: `Narrator` protocol + `AudioFileNarrator`, play button,
      playing-state HUD with stop
- [ ] StoreKit 2 scaffolding: `EntitlementStore` + launch reconciliation +
      `Transaction.updates` listener + unit tests; `.storekit` testing config;
      parental gate; Grown-Ups area shell
- [ ] PrivacyInfo.xcprivacy; compliance checklist satisfied
- [ ] Runs and feels right on iPad **and** iPhone simulators

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
- [ ] Story-beat animations (stickers react while their story plays)
- [ ] Pack delivery decision: On-Demand Resources vs own CDN (revisit when
      pack count or sizes make bundling impractical; note ODR is
      Apple-hosted → still no server of ours)
- [ ] Mac delivery follow-through: v1 opts out of "Designed for iPad on Mac"
      (docs/compliance.md); revisit once iPad experience is polished
- [ ] Orientation: revisit landscape-only (portrait canvas layout?)
- [ ] Localisation strategy (manifest `displayName`/stories per locale)
- [ ] Future: runtime story generation + on-device TTS behind the existing
      `StoryProvider`/`Narrator` seams (docs/architecture.md) — parked
