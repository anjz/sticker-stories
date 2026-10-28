---
name: puppet
description: Make a puppet for a Sticker Stories sticker — its drawing cut into parts on a skeleton, animated by keyframes (tools/author/stickerrig) — and give it its actions. Use when asked to rig, puppet or animate a sticker, to add or change a sticker's actions or moves, or to cut a character into parts.
---

# Make a sticker's puppet

Stickers animate as puppets (`docs/pack-format.md`, "Puppets"): the
sticker's drawing cut into parts on a skeleton, and every animation a
sidecar of keyframes. Two image generations per character; every action
after that is free, so give each character **many**. Read
`tools/author/stickerrig/README.md` first (commands, the rig file,
templates, lessons). Worked examples: `tools/author/art/forest/rigs/`
(the owl, the acorn).

Work from `tools/`. Look at every picture you make — the Read tool shows
PNGs — and judge it as a picture-book illustrator would.

## 1. Design the skeleton

From the sticker (`packs/<pack>/stickers/<id>.webp`) decide, before
drawing anything:

- **The bones**: root where it touches the ground (a flyer's at its
  centre); body (pivot at its base) with a `belly` child carrying the
  body's art (squash, breathing); head at the neck; a `face` bone on
  the head carrying eyes, brows, mouth or beak (it moves with the head;
  keys never slide it off it); each limb at its shoulder or hip; tail at its base;
  ears, antennae, wings at their roots. Use the standard names
  (README, "Templates") so the shared actions fit.
- **The parts** it needs drawn: body without head or limbs; head with a
  blank face; each limb whole, from the top of its thigh or shoulder to
  the paw — a leg cut off at the body's edge shows its seam; and a piece
  for every pose a turn cannot make — a wing open, hands clasped, a
  closed bud, a curled-up ball, the open scales — plus props it holds
  or uses (a stick, a nut, a tongue, a fly). Draw them by the README's
  "Drawing the parts": joint ends with no outline, the head with its
  neck, a person's limbs in two parts with their clothing, each side's
  limb (and eye) drawn for its side, containers empty with their
  contents apart, a radial body's unoutlined centre over its arms.
- **The face pieces**: each eye **for its own side** (the left eye, then
  the right), both looking the way the sticker's eyes look — never one
  eye mirrored for the other — as in the sticker, wide, closed in sleep,
  closed happy, sad; the mouth (or beak) as in the sticker, laughing
  open, a small "o", sad, and any the actions need (a yawn, nibbling
  teeth, a beak open in song); the nose and brows if the sticker has
  them. Never stand one piece in for another (an eye as a nose).
- **The actions** (step 6): which ones its body can do.

Write the rig file `tools/author/art/<pack>/rigs/<id>.json` with
`sticker`, `called` if "the <id>" reads wrong, `skeleton` (one sentence),
and the `sheets`. Adapt the prompts of an existing rig file: the
character's own words for each part, "drawn whole, including what is
normally hidden", joint ends as above, nothing touching, no text,
transparent background; the face sheet references the parts sheet.
Beach's rig files are the worked examples: `girl` (two-part limbs, an
eye row per side), `seal` (head and neck), `starfish` (the round
centre), `bottle` (empty, its note apart).

For a **new pack**, the still comes first (`stickerart`, one image per
sticker, assumed fine): draw it in a pose that rigs well — the whole
body visible, limbs apart from the body where possible, a clear
three-quarter or front view — and keep props separate where the
character will use them.

## 2. Draw the sheets

`go run ./author/stickerrig draw -pack ../packs/<pack> -only <id>`
(OpenAI; `-local` for the local model). One drawing each; it is assumed
fine. Redraw (`-force -sheet <id>`, after fixing the prompt) only when a
needed part is missing, merged with another, or cut off — at most once.

## 3. Name the pieces

`go run ./author/stickerrig parts -pack ../packs/<pack> -only <id>` lists
the pieces and writes `out/rigs/<id>.<sheet>.pieces.png`. Look at both,
and write `parts`: a name and a point inside each piece you use (the
listed `at` is one). The face sheet usually follows the prompt's order.

## 4. Measure and place

Draw a grid over the sticker to read positions — e.g. with Python and
Pillow (`uv run --with pillow python …`): the 768 px sticker on grey,
lines every 50 px, labels every 100. Read where every joint, eye, mouth
and foot is. Then write:

- `bones`, each after its parent, at its joint;
- `slots`, back to front (far limbs and far wing, body, near limbs,
  head, face pieces, props in front), each attachment by its centre,
  its `scale` from the piece's size on the sheet (the `parts` listing
  gives the boxes) to its size on the sticker, `rotate` for a tilt,
  `flip` only for a piece truly the same both ways (eyes never), `shade`
  (0.15–0.25) for a far limb, `none`
  as the default of a slot that shows only in some poses;
- `faces`: the pack's expressions (`happy`, `sad`, `sleeping`,
  `surprised`) as slot attachments;
- `idle`: `{ "breathe": "belly", "blink": { "eyeL": "closed", … } }`.

Layer so joints never show: a limb's joint end tucks **behind** the
body (or under the part that covers it) by at least ~17 px, so the
body's outline is the only line where they meet; a joint end drawn over
the body shows its outline as a seam (a limb that must lie in front
gets `fadeTop`). Each bone sits at the real joint **as measured on the
sticker** (the shoulder, the hip, a stalk's base, a feeler's root at
the nose), inside the piece's joint end — never where the piece happens
to start on the sheet — so turning it never pulls the part out of its
socket.

Install, then `preview -png -anim none` and read `out/rigs/<id>.rest.png`:
the puppet beside, over (50 %) and against the sticker (mismatch: magenta
is sticker only, green puppet only). Adjust centres, scales and turns
until the shapes agree to within a few pixels at the edges and every
feature sits where the sticker has it; small differences are fine, a
gap, a doubled outline or a floating part is not. Check the five faces
read as the expression they name. Install runs `stickerrig check` and
prints its warnings (README, "check"): look at what each one names and
fix it only where you can see the defect; never rework a puppet the
user has approved just to silence a warning.

## 5. Keep its animations

The rig must carry every animation the sticker has (install refuses
otherwise): same ids, same kind, and for a move the same `facing`,
`loop` (now in keys), `hops`/`flies`/`on`/`stays`, a similar stride.
A flying move also says how it flies (`docs/stage3d.md`, "In the air"):
`hovers: true` when the creature can hold still in the air (insects,
a hummingbird) — leave it out for one that cannot (most birds), which
the app keeps circling while it is up there — and `wings`, the bones
its flight keeps beating whatever else it does in the air (`["wingL",
"wingR"]`, the ladybug's `shell` too; whatever hangs on them goes with
them).
Make a move from a **gait** where its body has one (README, "Gaits":
`"gait": {"style": "human.walk"}`): the limbs move as the real animal's
do, the feet stay planted and the stride is measured. Write keys by
hand only for what no gait covers, and watch the result with `film`.
Read the old sidecar for its `description` and `pause.shows` — stories
were written to them — and make the keys tell exactly that, about as
long (an action 2–5 s, a move's loop a step or a wingbeat cycle of
0.5–0.8 s). Rewrite a description only where the puppet truly cannot
show part of it, and say so in your report.

## 6. Give it rich actions

Actions are free: aim for 10–16 per living character, 6–10 for a plant
or an object. Use the same ids across characters so stories can rely on
them:

- From `templates/common.json` where they read right: `jump`, `nod`,
  `shake-head`, `look-around`, `laugh`, `dance`, `talk`, `shiver`,
  `cry`, `sleep` (not if it has its own nap or doze), `wave` (anything
  with a hand, a paw, a wing, a leaf or a leg to wave), `twirl`.
- Its own, from what its body does and stories might tell: a bird
  `flap`, `peck`, `sing`; a four-legged one `sniff`, `shake-off`,
  `stretch`, `wag-tail`; an upright one `clap`, `stretch`, `scratch`; a
  bug `buzz`, `flap`; a plant `sway`, `droop`, `stretch-up`. Short,
  plain ids (lowercase, hyphens), one sentence of description each, in
  the style of the existing ones ("the fox pounces forward on its front
  paws and wags its tail"), and a `pause` (`frame` and `shows`) where
  there is a pose a story would hold (asleep, hiding, listening).
- An object's actions are only what wind, waves, water or a bump could
  do to it (sway, bob, wobble, tip, roll, spin on the water) — never
  something it would need a hand or a life for (a spade digging, a
  bucket hopping).
- Copy a template's keys into the rig file and tune them wherever the
  character's rest pose makes the shared keys wrong (an arm already
  raised, a head facing left, no head bone at all).

The face moves with the head: turn or nod the `head` bone; shift the
`face` sideways only as far as the eyes stay on the head (`check` warns
when they slide off), and never turn an eye on its own.

Motion rules: small, unhurried, smooth — nothing fast that a four-year-
old can't follow, nothing that tears the puppet (a limb's joint end
must stay hidden: turn limbs at most ~60° unless the joint end is
round and covered). Every action starts and ends at rest (key 0 and
the last key without bones), so hand-overs never jump. Swap eyes and
mouths on the keys where the feeling changes; a slot not named on a key
goes back to the face.

## 7. Check the keys

`preview -png` and read every `out/rigs/<id>.<animation>.png`: each key
should be a pose an illustrator would draw — balanced, nothing
detached or out of its socket, no seam where a limb meets the body, no
arm flung past the face, left and right where they belong, both wings
of a flyer visible in flight (the far one spread behind, shaded),
nothing pointing the wrong way (signs: turns are clockwise, y
is down; an arm on the viewer's left rises with +r). Run
`stickerrig check -pack ../packs/<pack> -only <id>`: it names the keys
where a joint end shows or the face slides off the head. Fix what reads
wrong and look again.

## 8. In the app, then commit

Build, then `-storyGallery -storyGalleryPack <pack> -storyGalleryPlay
<story>` on a simulator with a story that cues the sticker; or the
developer effects gallery to play any animation. Record with `simctl io
recordVideo` and look at frames. Run `go test ./...`, `go run ./packager
validate ../packs/<pack>` and `swift test` in `app/StickerStoriesKit`;
bump the pack version (`install -bump`); commit the rig file, the
pack's rig files and sidecars separately from any code change.

When several stickers are rigged at once (one agent each): touch only
your stickers' rig files, never commit, never `git checkout` or restore
pack files (other stickers' work lives there uncommitted), and leave
the shared templates alone.
