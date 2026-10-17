# Stories in 3D

A pack with a `space` (`docs/pack-format.md`, "Space") plays its stories in
three dimensions: every sticker on the stage has a position in the scene's
space, every place is a part of that space, every move is planned there,
and the screen is a projection of it. Packs without a space keep the 2D
planners (`StagePlanner`, `MotionPlanner`) until they get one.

Everything here is pure and seeded in StickerStoriesKit (`Stage/`), so it
is unit-tested on the Mac — including a test that plans every story of the
real Forest pack and checks the result.

## The world (`StageWorld`)

Built from the space, the base art's aspect, the rendition drawn (base or
wide) and the base art's frame in world points:

- **Coordinates.** `x` across, `y` up from the ground, `z` the depth from
  the eye, in art heights at depth 1 (`SceneSpace`). A point projects to
  `u = 0.5 + x / (aspect · z)`, `v = horizon + (y − eye) / z` (fractions of
  the base art), and to world points by the frame. A sticker's drawing is
  `size / z` art heights tall there, never below the floor.
- **Ground.** Every ground place becomes a polygon on the ground plane
  (`x`, `z`): land (the meadow) or water (the pond). The planes'
  footprints (a tree's roots) are obstacles.
- **Perches.** Lines of places on a layer (branches, bark) become lines in
  space at the layer's depth; bark lines have a facing.
- **Air.** An air place is its art area between two depths.
- **The camera's view.** The window shows part of the art (`StageScreen`:
  what is visible, what the device leaves clear, the story's pill to keep
  clear of); a pose is *on screen* when the sticker's projected drawing is
  wholly inside the clear part. A window **narrower than the art**
  (portrait, Split View, a narrow phone) plays the story on all of the
  art across, as a wide window would, and its camera follows the story
  ("Narrow windows"): the screen is then the whole art's width at the
  window's height, the pill's band is kept clear across all of it, and
  `window` says how much across the window shows.

## Poses

A sticker's pose is where its **feet** are (`Vec3`), what holds it up — the
ground, a perch, the air, another sticker (beside, on, under) or nothing
(off the stage) — and which way it faces. Its size is the space's size for
it, so how big it is drawn follows from its depth alone.

## The director (`StageDirector`)

Plans the whole story at once, from the cast and the story's triggers:

1. **The cast's starting poses.** A sticker the child placed starts where
   its feet are: on the ground there, on the branch or in the air it is
   at. One standing where it cannot (in water it does not belong in, on a
   tree's roots, up in the air though it walks) moves to the nearest place
   it can, in the story's first moments (the *settle*), while every child's
   sticker eases to the size its depth makes it.
2. **Entrances.** A visitor lands on the first place of its stage with a
   free spot on screen — sampled in the place's region, on land unless it
   belongs in the water, clear of the others — and comes in from the
   nearer side along the ground (walkers), through the air (flyers), or
   grows where it stands.

   **Near whom the story puts it with** (`Director.partner`): when its
   first move goes to someone on the stage (beside, onto, under), or
   someone on the stage next comes to it, within 10 s of its coming in,
   its spot is pulled to a step or two from them (`partnerPull`) — still
   clear of them and not hiding them — so the move is short and they are
   together when the words say so. Sent to someone within 3 s of coming
   in, it comes straight to their side, and that move is made.

   **In a narrow window** a visitor's spot is also pulled in towards the
   cast already on the stage (`togetherPull`): the score drops for every
   window width they would spread past 80 % of the window, so the camera
   can show them all at once and seldom has far to go. On an empty canvas
   the Forest cast now always fits a portrait iPad's window (17 % of the
   time it did not); the child's own stickers stay where the child put
   them, however far apart. The older planner (packs without a space)
   does the same when it picks a visitor's free spot.

   **Where the director chooses** (a visitor's spot, a spot in a place,
   the side to stand beside someone, a row on someone's back), it keeps
   characters in view: the planes in front (`StageWorld.covers`, each
   plane's painted part as a grid at its depth) must not hide them or the
   room above them, and the small ones (size class `tiny`, `small`) come
   to the front, where their details show. **Nobody stands behind
   someone, nor in front of someone already there**, as the viewer sees
   it: far apart in depth can still be one in front of the other on the
   screen (the deer near the front, the frog at the pond behind it). A
   spot is scored by how much of it the nearer stickers' drawings would
   hide and how much of anyone farther it would hide
   (`StageWorld.hidden(_:behind:)`), the story's cast counting fully and
   the child's other stickers less (`Director.blocking`); beside someone
   it is weighed where it will really stand, a step further out or nearer
   when that shows it — and **it does not hide whom it stands by**, nor
   stand hidden by them (a little overlap is being together; the fox
   beside the duckling). A flyer by someone small on the ground hovers up
   by their head, not across them, and one that circles keeps its loop
   from passing in front of them. Entrances and moves are planned in the story's
   order, so each sees the stage as it is then; a move an entrance already
   made (it came straight to the place) is not made again. The Forest
   staging test fails any of the cast mostly hidden behind another
   sticker while both stand still — beside each other too; only on or
   under someone may hide them. A place the story names keeps
   its spot — the pond's shore is where it is. A child's sticker its
   depth puts mostly behind a plane steps out to where it shows as the
   story starts.
3. **Moves.** Each `go` ends at a pose planned in space: beside someone at
   their depth, on or under them, at a free spot of a place (in it, or on
   its shore for one that does not belong in its water), off the stage,
   back home. Walkers follow a path on the ground around water and roots
   (A* on a grid of the ground plane, then straightened, each straight
   stretch checked exactly against the water's outline and the roots so
   it never cuts a pond's corner) — across any ground, not only the places
   they may stop in; one riding on someone's back shuffles along it, never
   down to the ground and up; a way that
   belongs to the water walks to its edge and swims the rest; flyers arc
   up through the air and down. Every leg's time follows the distance in the
   world and the sticker's gait: a walker's leg takes as long as its steps
   take to cover the way, its frames played a little faster or slower
   (0.6–2.5×) to keep near the usual times — its feet always keep pace with
   the ground, so nobody glides — 6 s at most, 4 s to someone, who is
   waiting for it (`maxTravelToSomeone`). A go to someone it already
   stands beside is no move. A flyer left in the air keeps flying
   ("In the air" below). On a perch one of its ways `stays` on (the
   woodpecker's `cling`, `on: ["trunks"]`), it takes to that way as it
   gets there and keeps it while it is there (`takeToPerch`): it clings to
   the bark, its actions there (`tap`, `drum`) play from that pose, and it
   clings on after them.
4. **Moving comes first.** A sticker on its way somewhere plays its move
   until it stops: an action the story cues meanwhile waits until it gets
   there (`StageDirector.delayed`). Once an action is over, a move that
   stays (a flyer hovering, a duckling swimming) goes on. **Whoever
   someone is on the way to waits for them too** (`StageDirector.reaction`):
   its actions, faces and effects cued while someone travels to its side,
   onto or under it wait until they get there, 4 s at most — the mushroom
   giggles once the ladybug's feet are on her cap. The Forest staging
   test keeps the mean time from a go to someone to the arrival under
   4.2 s.
5. **Actions in their place** (the woodpecker on the bark) go there first,
   as before (`PlacementPlanner`).
6. **Out of the story's way.** The director plans the story once to see
   where its cast — every sticker it names, moves, sends someone to or
   cues anything on — will be and pass; a child's sticker the story does
   not use that stands in the way walks (or fades) to the freest land on
   screen away from the cast, the further back and nearer the sides the
   better, as the story starts; then the story is planned again round it.

## In the air

A flyer left in the air — in a place's air, by someone up there, or put
there by the child — never stops flying while it is up there; on a
branch, the ground or someone's back it rests like anyone else. Flyers
come in two kinds, by their flight (`hovers` in its sidecar,
`docs/pack-format.md`):

- **It can hover** (a bee, a butterfly, a firefly, a ladybug): it stays
  where it is, bobbing gently, its wings going.
- **It cannot** (a bird, an owl, a woodpecker): it flies a slow loop
  round its spot (`StageLeg.circling`, a lap every 5 s) — out ahead the
  way it faces, round nearer the camera and back, turning at each end —
  as wide as keeps it on screen and out from behind the trees, until the
  story sends it on, from wherever it is on the loop.

Either way its wings never stop: an action the story cues up there (a
talk, a laugh, a held pose) plays on the rest of its body while the
flight keeps the bones its sidecar names as `wings` — and whatever hangs
on them — beating (`PuppetPose.flying`).

## In the water

Only a sticker with a way that belongs to the water goes into it (a move
with that water in its `on`: the duckling `by swim`); anyone else stops
on the bank and walks round it. Its water way keeps it in the water: it
walks to the edge, turns there the way it will swim, swims in straight
from the edge without crossing the bank on the way, and leaving by its
usual way it swims to the bank first, then walks. Sent by its water way
to someone in that water (the turtle `by swim` to the fish), it swims to
their side in the water; anyone else sent to someone out in water stops
on the land on its way to them (the ball by the seal out at sea).
Coming in or going off the stage it does so through its water when it
swims (Beach's turtle through the sea, from the side the sea runs on
past the art), and never through water it does not belong in (Beach's
rock pool runs on past the art's right edge): the other side, or the
nearest depth at that side that will do.

A sticker **every one of whose moves is a water move** (a fish, a boat,
Beach's bottle and ring bobbing) is *water-bound*: it is never on or
across land. One the child left on land, or in water it cannot move in
(the octopus in the sea), fades into the nearest of its own water as
the story starts (the settle), at a spot where it is seen and hides
no one. Sent to a place or someone out of its water, it goes to the
nearest spot of its water it is seen at — at a place on land (the
shore) that is in its water by it, at the waterline; to a place or
someone its water does not reach (the little fish from the rock pool to
the sea and home), it fades across: out where it is, in at the nearest
point of its own water, or of the target's. Coming in or going off where
its water runs nowhere off the stage, it fades in or out where it is.
The pack staging test (every
pack with a space) fails a swim over land or a walk in the water — a
hair off the waterline counts as either. In
the water it floats: its move's
`waterline` (`docs/pack-format.md`) is how much of its drawing, from its
feet, is under the water. Whatever it does there — swims, quacks, naps —
its puppet and its shadow are cut off at the waterline and sunk by as
much, so the waterline lies where its feet were, and ripples ring it
there, the far half behind it and the near half in front
(`StageWorld.afloat`, `StickerNode.float`). It sinks in over its first
half-height into the water and rises as it climbs out. A sticker in water
without a waterline would stand on the water, so the pack staging test
fails one — except in **shallow** water (Beach's rock pool, `shallow` in
the space): whoever belongs there sits on its clear bottom, seen whole,
and nobody floats there, whatever its waterline.

## Alive at rest

Every puppet on the stage takes over from its still art as the story
starts and breathes and blinks from then on (`PuppetPose.idle`). Now and
then — every 7 to 14 seconds, staggered so the stage never fidgets all at
once — a character the story leaves be plays one of its small, gentle
actions (`idle` in its sidecar, `docs/pack-format.md`: a look around, an
ear flick, a sniff), never the same twice in a row (`IdleLife`). Never
while it is on its way, plays or holds an action the story cued, sleeps,
hovers or swims, or just before the story cues it: the story always comes
first. Calm mode keeps only the breathing and blinking.

## Narrow windows (`StoryCamera`)

When the art is wider than the window, the story is planned on all of it
(above) and the camera follows it while it plays, in every pack. It
follows the story's **beats**: each action, face (not the return to the
usual one) and sticker effect the story cues, from 0.8 s before it to
0.6 s after, and each sticker's way in and moves, all the way along (not
the child's stickers settling, nor making room). Idle life is not a beat.
Each frame it takes the least move that brings every current beat's
sticker into the window, a margin in from its sides; when they do not
all fit it goes with the beat that began last, then adds as many of the
others as still fit. It eases there, never faster than 0.9 window widths
a second, and never past the art's edges. Under Reduce Motion it cuts
instead of gliding. While the child pans by hand, and for 4 s after, it
leaves the view where they put it. A window as wide as the art never
moves.

## Rendering

Every frame each sticker's pose at that time is projected: its feet's
screen point, its drawn height, and its order — nearer in front, at the
same depth the one that got there last in front. The scene's planes sit in
that order at their depths. Effects (a wobble, a jump) compose on top of
the projected placement, sized to the sticker as it is drawn. The child's
canvas comes back exactly when the story ends.
