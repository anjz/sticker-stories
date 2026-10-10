# Pack art — rules for every new pack

What every sticker pack's art must get right, collected from building Forest
and Moon Base. The tools enforce what they can; the rest is on the author.
How the tools work: `tools/author/stickerart/README.md` (stickers, faces,
scene) and `tools/author/stickeranim/README.md` (live animations). The
format: `docs/pack-format.md`. The effects: `docs/effects.md`.

A pack has **25 stickers**, every one with a size class, a stage, one
action and one move.

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

## 3. Animations hold their size

The rule: **the sticker is the same size in every frame**, and only what
moves, moves.

- Frames are drawn **in the sticker's box at the sticker's scale**; extras
  (dust, sparks, a thrown pebble) go into the room around the drawing,
  never by shrinking it. A frame whose subject is a different size from
  the rest pose is a defect, not a style.
- **Motions stay small** — nothing reaches far from the sticker; travel
  is the app's job (moves are drawn in place, "on a treadmill").
- **A walk is a real walk cycle.** The app slides a walker along while
  its loop plays, so a loop whose legs barely change reads as a statue
  gliding (Beach's first surfer walk). Write every walk, run, crawl and
  scuttle frame by frame as contact → down → passing → up, then the same
  with the other leg, each frame's legs clearly different from the one
  before, the free arm swinging against the front leg — and mark the
  move `"steps": true` in anim.json: the check then flags a loop whose
  lower half changes less than 7 % a frame (`frozen loop`). Things that
  glide (a snail, an urchin on its tube feet) leave it off.
- Rigid things (machines, spacecraft, buildings) must keep their exact
  outline: only the moving part changes (a hatch, a wheel, an arm). Use
  `restFromSticker: false` for them.
- **Never draw particles** — no dust, sand, soil, drops, sparks, smoke or
  debris in any frame (the scaffold prompt forbids them). Where a frame
  needs them (a landing, a touchdown, a splash, a drill biting), mark it in
  anim.json's `particles` and the app fires `dust-puff`, `spray` or
  `sparks` there, in the pack's `world` (gravity, ground colour). Engine
  flames are part of the vehicle and stay drawn.
- Draw them **over a scaffold** (`"scaffold": true` in anim.json): the
  model re-poses the sticker cell by cell instead of redrawing it, which
  keeps one size and the same proportions across a sheet. Give an
  animation `room` when it must reach past the sticker's box (a flame
  under a huge ship). Flights register on their `body`.
- Every animation is **reviewed by eye** before install, at real speed,
  with its per-frame size check: `stickeranim review` (flagged frames in
  orange). A flagged frame is either a real defect (redo the sheet, or add
  a `hint`) or an intended change (a puff of dust, a crouch) — decide by
  eye, never by number alone.

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
4. Animations: pilot two or three stickers → review → the rest → review.
5. Scene and features → measure → install → check on an iPhone and an
   iPad simulator.
6. Only then stories (`/author-stories`) and narration (`storyaudio`).
