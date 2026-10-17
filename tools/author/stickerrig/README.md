# stickerrig — puppets: stickers that move on a skeleton

A puppet is a sticker's drawing cut into parts that hang on a skeleton
(`docs/pack-format.md`, "Puppets"). The app moves the parts, so an
animation is a few keyframes of data instead of a sprite sheet: two
image generations per character, then any number of animations for
free. This is how stickers animate: each animation is a sidecar without
a sheet, which stories cue like any other (`{fox:live jump}`).

```sh
cd tools
go run ./author/stickerrig draw    -pack ../packs/forest -only fox            # parts sheet, then face sheet (≈ $0.11)
go run ./author/stickerrig parts   -pack ../packs/forest -only fox            # list the pieces: where each is
# … name the parts, measure the sticker, write bones, slots, faces, idle, animations …
go run ./author/stickerrig install -pack ../packs/forest -only fox            # atlas + rig + sidecars + manifest
go run ./author/stickerrig preview -pack ../packs/forest -only fox -png       # out/rigs/fox.*.png to look at
go run ./packager validate ../packs/forest
```

`draw` is the only step that costs anything (about $0.05–0.06 a sheet at
`-quality high`, nothing with `-local`, which draws on this Mac:
`author/localimage`). It draws each sheet once: assume it is fine and
redraw only what is broken (a part missing, merged with another, or cut
by the sheet's edge). The face sheet is drawn with the parts sheet as a
second reference. The `.claude/skills/puppet` skill walks Claude through
the whole thing for a character.

## The rig file (`tools/author/art/<packID>/rigs/<sticker>.json`)

One file per sticker, so several can be rigged at once:

- `sticker`; `called` — how descriptions name it ("the bear cub"; "the
  <sticker>" by default); `skeleton` — a sentence on the body type,
  joints and pose, for whoever adds animations later.
- `sheets`: what the edits model draws, in order — each from the
  sticker's raw art (stickerart's `out/stickers/<id>.noprop.png`, else
  `.raw.png`) plus the sheets it lists in `references`. Two work: the
  **parts** (body without head or limbs; head with a blank face; each
  limb once, with rounded joint ends; a variant per pose that rotation
  cannot make — a wing open, hands clasped, a curled-up ball; props it
  holds) and the **face pieces** (one eye in five states, mouths or
  beaks). Ask for every piece apart, nothing touching, no text, a
  transparent background.
- `parts`: `{ name: { "sheet", "at": [x, y] } }` — the piece of a sheet
  at (or nearest) that point. `parts` lists every piece with a point
  inside it and writes `<sticker>.<sheet>.pieces.png`, every piece boxed
  and numbered. `fadeTop` (a fraction of the piece's height) fades its
  top in: a limb laid **over** the body then joins it with no outline,
  its fur running into the body's (the deer's near legs).
- `bones`, `faces`, `idle`: as in the pack's rig, in the sticker image's
  pixels at `stickerSize` (768): measure them on the finished sticker.
- `slots`: as in the pack's rig, except that an attachment is given by
  its **centre** (`x`, `y`) at rest and its `scale` from the piece as
  drawn (`scaleY` stretches the height on top); install works out the
  box. Eyes drawn for one side are `flip`ped for the other.
- `animations`: the sticker's animations, in the manifest's order (its
  first move is its usual way), each with the sidecar's fields — `id`,
  `kind`, `description`, `pause` (`{ "frame": key, "shows" }`), `loop`,
  `facing`, `stride`, `hops`, `flies`, `hovers`, `wings` (the
  sidecar's `puppet.wings`), `on`, `stays`, `waterline`, `away`,
  `place`, `perched`, `faces`, `idle`, `particles` — and its `keys`.
  Pause, loop and particles count keys. In the water: a move's `away`
  names the move it plays going away from us (`"paddle"` with
  `"away": "paddle-out"`, his back to us); an action's `on` names the
  places it is done in (`"ride-wave"`: `["sea"]`) — while a move that
  `stays` keeps the character in water, any other action shows only its
  face over the move, so its face slots should be the ones the rig's
  `faces` swap; an action's `faces` (`"right"`) is the way the
  character faces on screen while it plays
  (`docs/pack-format.md`, "Live animations"). Or `template`: `"common.jump"` takes from
  `templates/common.json` whatever the animation leaves out (its keys,
  kind, pause and a description where `{the}` becomes `called`).

`install` cuts every part out at the largest size an attachment shows it,
grows each by the pack's border into a white silhouette, packs them all
into `anims/<sticker>.rig.webp`, writes `anims/<sticker>.rig.json` and
every animation's sidecar `anims/<sticker>.<id>.json` (deleting a sprite
sheet one replaces), sets the sticker's `animations` in the manifest to
the rig's, and validates the pack. It refuses to leave out an animation
the sticker has now — stories may cue it — unless `-drop`. Installs take
a lock, so several can run at once.

`preview` writes one page with the puppet at rest beside the sticker and
over it, every face, and every animation playing with its keys laid
out, drawn by the same rules as the app. `-png` takes pictures of it
with headless Chrome: `<sticker>.rest.png` (rest, a mismatch view —
sticker only magenta, puppet only green — and the faces) and
`<sticker>.<animation>.png` (its keys, large); `-anim <id>` for one.

## Templates (`templates/<type>.json`)

Shared animations written against standard bone and slot names (the
file lists them): `root` (the ground contact), `body`, `belly` (the
body's art alone, for squash and breathing), `head`, `face` (on the
head; carries the eyes and mouth — a sideways shift turns the face),
`eyeL`/`eyeR`, `browL`/`browR`, `mouth` or `beak`, `armL`/`armR`,
`legL`/`legR`, `footL`/`footR`, `earL`/`earR`, `tail`, `wingL`/`wingR`,
`antennaL`/`antennaR`; L is the viewer's left. Eye attachments `wide`,
`closed`, `happy`, `sad`; mouth `open` (laughing), `o`, `sad`; beak
`open`; wings `open`. A rig that lacks a bone or slot just leaves it out
(install notes the bones). `common.json` has jump, nod, shake-head,
look-around, laugh, dance, shiver, talk, cry, sleep, wave and twirl.
Use a template where it reads right and copy its keys into the rig
file to tune them where it doesn't.

## Lessons (2026-10)

- Draw the puppet **from the finished sticker** and say "at the size it
  has in image 1": the parts come back at close to one scale, in the
  sticker's style, first time.
- Ask for the head with a **blank face** and the features on their own
  sheet: eyes and mouths swap per expression and blink.
- The sheet draws eyes for one side, but not always the same side:
  check each and flip per attachment.
- Give squash its own bone (`belly`, the body's art only) so a body can
  swell without squashing the head on it.
- Place parts by eye on a grid over the sticker, then check the
  preview's overlay and mismatch view. A silhouette fit (maximising the
  overlap of the bordered outlines) made the owl's wing far too big: the
  outline is not the drawing.
- A pose rotation cannot make is a part of its own swapped in on a key:
  the owl's open wing, the acorn's clasped hands, a hedgehog's ball.
- The puppet and the sticker never match exactly, so the app hands over
  from one to the other once per story and keeps the puppet on (idling)
  between animations: a crossfade at every cue showed a double outline.
