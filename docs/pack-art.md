# Pack art — rules for every new pack

What every sticker pack's art must get right, collected from building Forest
and Beach. The tools enforce what they can; the rest is on the author.
How the tools work: `tools/author/stickerart/README.md` (stickers, faces,
scene) and `tools/author/stickerrig/README.md` (puppets: how stickers
animate). The format: `docs/pack-format.md`. The effects: `docs/effects.md`.

A pack has **25 stickers**, every one with a size class, a stage, a
puppet with many actions, and its moves.

## 1. Stickers are drawn at their size

- Set `"sizeInArt": true` in `art.json` (`docs/pack-format.md`, "Drawn
  size"). Each sticker is drawn at its **size class's share of its square
  image**, centred: huge 94 %, big 84 %, medium 72 %, small 60 %, tiny 50 %
  (longest side, border included). Never fill the box with a small thing.
- Give **every sticker a `size`**: `huge` (a rocket, a whale), `big` (a
  deer, a lander, a greenhouse), `medium` (a person, a fox, a rover),
  `small` (a bird, a solar panel, a satellite far up), `tiny` (a ladybug,
  a seedling, a moon rock). Things seen far away (the sky) get the class
  they look, not the class they are.
- The room left around a drawing is where its **animations reach** — dust,
  sparks, a raised arm, a puff of exhaust. An animation never shrinks the
  sticker to make room (section 3).
- Draw each subject **whole, facing slightly left, on its own**: no ground
  patch, no props it would not carry everywhere (the frog lost its lily
  pad: `prop` in `art.json` removes one after the fact, but prompt without
  it first). Realistic subjects stay realistic: no faces on machines unless
  the design really has a screen.

## 2. Faces

- Characters with faces get the four variants (`happy`, `sad`, `sleeping`,
  `surprised`) from a `face` box that covers the **whole** face — a box
  cutting through an eye leaves doubled outlines.
- Use `faceNote` wherever the face is unusual (eyes on stalks, an LED
  visor, a face on a flower): say what must not change and what must not
  be added.
- Adding any field to the face box changes every fingerprint and re-renders
  every variant (~$6 a pack): decide the boxes before rendering.

## 3. Puppets

Stickers animate as puppets (`/puppet` skill): each one's drawing cut
into parts on a skeleton, every animation keyframes. What the art needs:

- **Draw each still once and use it**, and draw it in a pose that rigs
  well: the whole body in view, limbs clear of the body where it can be,
  a front or three-quarter view; props the character uses (a stick, a
  nut) apart from its paws where possible.
- **Design the skeleton before the sheets**: the joints, which parts
  turn on them, and the poses a turn cannot make (a wing open, hands
  clasped, a curled-up ball) — each one a piece on the parts sheet.
- **One parts sheet and one face sheet**, drawn from the still, every
  piece apart; redraw only what is broken. Drawn so no seam shows and
  nothing faces the wrong way (stickerrig README, "Drawing the parts"):
  joint ends with no outline, tucked under what they join; the head with
  its neck running into the chest; a person's limbs in two parts with
  their clothing on them; each eye drawn for its own side, never
  mirrored; containers empty, their contents apart; a radial body's
  centre unoutlined over its arms; every bone at the joint measured on
  the still.
- **Many actions**: they cost nothing, so every living character gets
  the shared ones its body can do (jump, nod, laugh, wave…) and its own.
- **Objects move only as the world could move them**: wind, waves,
  water, a bump — a bucket wobbles in the breeze, a bottle bobs. Nothing
  inanimate acts by itself (a spade never digs alone, a bucket never hops).
- **Motions stay small and unhurried**, start and end at rest, and never
  show a limb's joint end. Travel is the app's job: moves play in
  place. Never draw particles (dust, drops, sparks): a key's `particles`
  has the app fire them.
- The puppet lies on the still at rest (the preview's mismatch view):
  the app hands over from one to the other once per story.
  `stickerrig check` (run by install) warns of seams, misplaced bones,
  mirrored eyes and faces sliding off heads.

## 4. The scene

- **Background and foreground** are painted at the wide 2:1 size with the
  base 4:3 composition centred. Keep the horizon and everything that
  matters in the **central 70 % of the height** — phones crop the top and
  bottom, and sky landmarks (an Earth, a moon) must sit low enough to
  survive.
- **Framing elements at the edges** (a building, a tree, a rock) stay
  slim — no more than about an eighth of the width — and must not grow on
  phones: paint the wide foreground on its own with them at its own edges
  (`scene.foregroundWideOwn`), never by widening one the 4:3 picture cuts.
  Places on them get `wideAreas`.
- **Layers in front frame the scene, no more.** Everything in front of
  the background — the foreground and every scene layer (`scene.layers`:
  trees, reeds) — covers **at most 40 %** of the picture together, on
  each rendition (Forest: 38 %), most of it above the ground the stickers
  stand on: more hides them. A few low plants in the bottom corners for
  the foreground; a big tree on each side, close to the viewer, as placed
  layers (`area`, and `wideArea` to stand at the wide picture's edges
  too), each its own layer so it has its own depth: two different kinds,
  with full leafy crowns, their trunks in the picture at its edges and
  their tops running off it — the middle stays open. `stickerart` prints the coverage after a scene
  render and refuses to install over the limit. **What stands at the
  bottom runs off the bottom edge** — the foreground's plants, the
  plants at a tree's foot — so a sticker the child puts behind them never
  shows its feet below them (`scene.foregroundDown`, a layer's
  `toBottom`). Something big the background already shows in the
  middle of the ground (the boulders on Beach's rock pool) can be a
  plane of its own cut from it (a layer's `cut`): stickers behind it in
  a story pass behind it, and while the child plays every sticker stays
  in front of it.
- **Every window shape plays the whole picture.** A portrait iPad, Split
  View or a narrow phone shows about half the art across (a third, or
  less, in a narrow Split View) and the camera follows the story there
  (`docs/stage3d.md`, "Narrow windows"). So a place at the edges (a
  trunk, a landing pad) works in every window, and the art must read
  well in any window-wide slice: no slice that is only an empty strip,
  nothing a scene needs split across both edges. Check new art in a
  portrait iPad simulator as well as landscape.
- **Outdoors**: no sun, moon, stars, rain or rainbow in the art — canvas
  effects draw those. A space pack's sky is part of the place (stars, the
  Earth) and stays.
- **Features** (the places stickers land) are measured on the finished
  composite by pasting real stickers at their in-app size (16 % of the
  height for filled packs, 21 % for packs drawn at size) at each area's
  centre, on both renditions. Re-measure after any repaint.

## 5. Process

1. Style proofs → pick one → style sheet.
2. Cast (25) with size classes and stages in `art.json` → render → review
   all together on the scene (a contact sheet at their drawn sizes).
3. Faces → review.
4. Puppets: skeletons and sheets for all → pilot two or three stickers
   → review → the rest → review.
5. Scene and features → measure → install → check on an iPhone and an
   iPad simulator.
6. Only then stories (`/author-stories`) and narration (`storyaudio`).
