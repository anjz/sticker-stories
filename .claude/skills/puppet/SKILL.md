---
name: puppet
description: Make a puppet for a Sticker Stories sticker — its drawing cut into parts on a skeleton, animated by keyframes instead of sprite sheets (tools/author/stickerrig). Use when asked to rig, puppet or skeleton-animate a sticker, to add or change a puppet's animation, or to cut a character into parts.
---

# Make a sticker's puppet

The puppet replaces a sticker's sprite-sheet animations with parts the
app moves (`docs/pack-format.md`, "Puppets"). Two image generations per
character; everything after is free and yours to get right by looking.
Read `tools/author/stickerrig/README.md` first (workflow, rig.json,
lessons) and use the owl in `tools/author/art/forest/rig.json` as the
worked example.

## Steps

1. **Check the inputs.** The sticker needs stickerart's raw art
   (`tools/author/art/<pack>/out/stickers/<id>.noprop.png` or
   `.raw.png`) and its animations in the pack (`anims/<id>.*.json`). Read
   each animation's sidecar: its description, hold total, pause and loop
   are what the puppet must play.
2. **Write the sheets** in rig.json, adapting the owl's two prompts to
   the character: which parts it has (a fox: body, head, tail, four legs
   or two leg pieces; a snail: body, shell, eye stalks), each drawn whole
   including what is normally hidden, with rounded joint ends, and the
   face pieces it needs for its animations and its pack faces
   (`stickers[].expressions`). Run `draw -options 2` for the parts, look
   at both, copy the better one over `<id>.parts.png`; the same for the
   face sheet. Redraw when a part is missing, merged or touching another.
3. **Name the pieces.** Run `parts`, look at `<id>.<sheet>.pieces.png`,
   and write `parts` with a point inside each piece you use.
4. **Measure the sticker.** Draw a grid over
   `packs/<pack>/stickers/<id>.webp` (768 px) and read where every
   joint, eye, beak and foot is. Bones at the joints (root at the feet,
   the body's pivot at its base, the head's at the neck, a wing's at its
   shoulder; give squash its own bone). Slots back to front: far limbs,
   body, near limbs, head, face pieces. Each attachment's centre and
   scale from those measurements; a tilt in the sticker is a `rotate`.
5. **Install and preview**, then look at the preview's rest row: the
   puppet beside, over and flicking with the sticker. Adjust centres,
   scales and turns until it lies on the drawing; small differences are
   fine.
6. **Keys.** Write each animation as keys on the sheet's timing:
   pause and loop in the same places, about the same length. Rest pose
   first. A swap (eyes closed, beak open) shows from its key on; a hold
   is the time to the next key; a blink is a 0.1 s key. Look at the
   preview's key strip and play, then fix what reads wrong.
7. **Check in the app.** Build, then
   `-storyGallery -storyGalleryPack <pack> -storyGalleryPlay <story>` on a
   simulator with a story that cues the sticker; record with
   `simctl io recordVideo` and look at frames (the hand-over, a held
   pause, a face change, a move's landing). The developer switch
   "Puppet animations" (Settings, debug builds; `-developer.puppets NO`)
   plays the sheets instead, for comparison.
8. Run `go test ./...`, `go run ./packager validate ../packs/<pack>` and
   `swift test` in `app/StickerStoriesKit`, bump the pack version
   (`install -bump`), and commit the rig.json, the pack's rig files and
   sidecars separately from any code change.
