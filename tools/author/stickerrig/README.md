# stickerrig — puppets: stickers that move on a skeleton

A puppet is a sticker's drawing cut into parts that hang on a skeleton
(`docs/pack-format.md`, "Puppets"). The app moves the parts, so an
animation is a few keyframes of data instead of a sprite sheet: two
image generations per character, then any number of animations for free.
The puppet plays the sticker's existing animations (same ids, pause and
loop), so stories need no change.

```sh
cd tools
go run ./author/stickerrig draw    -pack ../packs/forest -only owl -options 2   # the two sheets, to pick from
cp author/art/forest/out/rigs/owl.parts.option1.png author/art/forest/out/rigs/owl.parts.png
go run ./author/stickerrig draw    -pack ../packs/forest -only owl -sheet face -options 2
cp author/art/forest/out/rigs/owl.face.option1.png author/art/forest/out/rigs/owl.face.png
go run ./author/stickerrig parts   -pack ../packs/forest -only owl   # list the pieces: where each is
# … name the parts, place them, write the bones, slots, faces and keys in rig.json …
go run ./author/stickerrig install -pack ../packs/forest -only owl   # atlas + rig + each sidecar's puppet
go run ./author/stickerrig preview -pack ../packs/forest -only owl   # out/rigs/owl.preview.html
go run ./packager validate ../packs/forest
```

`draw` is the only step that costs anything (about $0.05–0.06 a sheet at
`-quality high`); the face sheet is drawn with the parts sheet as a
second reference, so pick the parts first. The `.claude/skills/puppet`
skill walks Claude through the whole thing for a new character.

## rig.json (`tools/author/art/<packID>/rig.json`)

One entry per sticker in `rigs`:

- `sheets`: what the edits model draws, in order — each from the
  sticker's raw art (stickerart's `out/stickers/<id>.noprop.png`, else
  `.raw.png`) plus the sheets it lists in `references`. Two work: the
  **parts** (body without head, wings or feet; head with a blank face;
  folded wing; open wing; one foot) and the **face pieces** (one eye in
  each expression, brows, beaks). Ask for every piece apart, nothing
  touching, no text, a transparent background.
- `parts`: `{ name: { "sheet", "at": [x, y] } }` — the piece of a sheet
  at (or nearest) that point. `parts` lists every piece with a point
  inside it and writes `<sticker>.<sheet>.pieces.png`, every piece boxed
  and numbered.
- `bones`, `faces`, `idle`: as in the pack's rig, in the sticker image's
  pixels at `stickerSize` (768): measure them on the finished sticker.
- `slots`: as in the pack's rig, except that an attachment is given by
  its **centre** (`x`, `y`) at rest and its `scale` from the piece as
  drawn; install works out the box. Eyes drawn for one side are
  `flip`ped for the other.
- `animations`: `[{ "id", "keys", "pause"?, "loop"?, "stride"? }]` — the
  puppet's version of the sticker's animation with that id (it must have
  one in the pack). Keep its timing close to the sheet's: stories were
  timed with it.

`install` cuts every part out at the largest size an attachment shows it,
grows each by the pack's border into a white silhouette, packs them all
into `anims/<sticker>.rig.webp`, writes `anims/<sticker>.rig.json`, puts
each animation's keys into its sidecar as `puppet`, and validates the
pack. `stickeranim install` keeps a sidecar's puppet.

`preview` writes one page with the puppet at rest beside the sticker and
over it, every face, and every animation playing with its keys laid
out, drawn by the same rules as the app.

## Lessons from the owl (2026-10)

- Draw the puppet **from the finished sticker** and say "at the size it
  has in image 1": the parts came back at close to one scale, in the
  sticker's style, first time. Two options of each sheet were enough.
- Ask for the head with a **blank face** and the features on their own
  sheet: eyes, brows and beaks swap per expression and blink, and the
  model drew a separate brow for every eye, which gives brows of their
  own to raise.
- The sheet drew eyes for one side, but not always the same side (the
  calm eye's lashes on the left, the others' on the right): check each
  and flip per attachment.
- A body part with the side feathers drawn on both sides covers the far
  wing at rest; the open far wing is the near one flipped and shaded,
  shown only in flight.
- Give the squash its own bone (`belly`, the body's art only) so a
  dozing body can swell without squashing the head on it.
- Place parts by eye on a 50 px grid over the sticker, then check the
  preview's overlay. A silhouette fit (maximising the overlap of the
  bordered outlines) made the wing far too big: the outline is not the
  drawing.
- The puppet and the sticker never match exactly, so the app hands over
  from one to the other once per story and keeps the puppet on (idling)
  between animations: a crossfade at every cue showed a double outline.
