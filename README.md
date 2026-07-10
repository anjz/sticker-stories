# Sticker Stories

A sticker-canvas storytelling app for young children (4+), for iPad and iPhone.

Kids drag stickers from a tray onto a two-layer scene, then press play: the app
picks one of the pack's pregenerated short stories that matches what's on the
canvas and narrates it aloud. Fully offline and deterministic — no runtime AI,
no data collection, Kids Category compliant.

## Repository layout

| Path      | What it is |
|-----------|------------|
| `app/`    | Xcode project — SwiftUI shell + SpriteKit canvas + local `StickerStoriesKit` package |
| `packs/`  | Source-of-truth sticker pack content (art, stories, audio, manifests) |
| `tools/`  | Development-time Go pipeline: pack validation/packaging, story generation, TTS (never ships) |
| `docs/`   | Architecture, pack format, compliance, commerce, roadmap |

## Running the app

Requires Xcode 26+ with an iOS 18+ simulator runtime.

```sh
# Build & run (or just open app/StickerStories.xcodeproj in Xcode and hit Run)
xcodebuild -project app/StickerStories.xcodeproj -scheme StickerStories \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' build
```

If `xcode-select` points at the Command Line Tools, prefix commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Running the tests

```sh
# Core logic (manifest, story selection, entitlements) — runs on macOS, no simulator needed
cd app/StickerStoriesKit && swift test

# Tools
cd tools && go test ./...

# Validate a pack
cd tools && go run ./packager validate ../packs/forest
```

See `CLAUDE.md` for working conventions and `docs/` for design documentation.
