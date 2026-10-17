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
   4.2 s. An action waits only for the moves cued **before** it; a move
   the story cues after it waits for it to end (`StageAction`: the
   surfer rides the wave, then comes in). One move's legs carry on
   through the pause between them (`StageLeg.cue`): a way brought to rest
   (`StageMove.tail`: off his board in the shallows) before it sets off
   the next way on foot. An effect cued on a sticker at the same moment
   as one of its actions goes with that action (`StageDirector.withAction`:
   the wave rises as he rides it, out in the sea). Over a move that goes
   on, an action's way back to its still pose is left out, so a move cued
   after it takes over straight away; and an action that `faces` a way
   leaves it facing so (`StageAction.faces`) — no turn back, nor a turn
   at the next move's start if that goes the same way.
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

**Out in open water.** A sticker afloat that rests in a water or is sent
to it (not on a shallow bottom) stops well out from the waterline, never
hugging the shore: at least a third of the way out (`StageWorld.openWater`),
measured up the art at that spot from the water's near edge (0) to its
far edge (1) (`StageWorld.outInWater`, `inOpenWater`). A wave rises only
that far out too. A water-bound sticker sent to a place on land (the
bottle "to shore") still stops at the waterline; a child's sticker the
child put in the water stays where the child put it. Going off from by
the shore, one afloat heads out to open water (the bottle bobbing away
out to sea), not along the waterline.

**Going to a place, and that way.** Sent into a place from outside it, a
sticker goes somewhere near in it, not across it (the sea from the sand:
just out past the waves). Sent that way (`toward`) it goes well on that
way within the place — the boats racing across the sea, though they are
in it already — or stays where nothing lies further that way; never the
other way.

**Beside someone.** Each one more already on that side of them stands a
step further out (two sent to the bottle never share a spot), and whoever
else stands by them in front counts as hiding them too. A flyer by them
stays clear of them, aloft — beside someone bigger on the ground, up by
their shoulders (the gull flew up beside Lola), never down by their feet — and one that cannot hover loops out away from them, turning
away as it gets there, never across them (a lap that fits nowhere
shrinks to beating its wings where it is).

**Under someone** standing on the ground and taller than it (an
umbrella, a mushroom), a sticker taller than 55 % of them shelters just
behind them in depth — they are drawn in front, their canopy coming over
the top of its head, its face or middle showing below — and across the
screen beside the pole or stalk, a third of its own width off their
middle on the side it came from (one about as wide as them, the frog by
the mushroom, by their edge). It walks in standing beside the pole in
front of the canopy line, and steps back under it only as its next action
— cued within a second of its getting there (Lola crouching) — takes it
down, that action playing as it steps; with none, it stays in front. A
small one that fits under them whole
stands in front, as before; both keep their sizes. The staging test fails
one sheltering so that neither its face nor its middle shows past its
host's painted shape; being partly behind its own host is no fault there.

**On a shallow bottom** a sticker is seen in the water: (nearly) all of
its drawing over the water where there is room to choose
(`StageWorld.overWaterShare`), else its middle (`overWater`) — not up on
the rocks at the pool's rim, even if that means sitting by the story
pill's corner. Wherever the director chooses, it never puts a sticker on
top of, in front of or behind someone already there, nor mostly behind the
scene's planes (a clam behind the pool's front rocks), just to keep clear
of the pill; and "another part" of a place with no such spot leaves it
where it is. The staging test (Beach also on a phone in landscape) fails a
water dweller with more than a quarter of its drawing over the rim. A child's sticker never takes a perch it would be off
screen or hidden on (the far trunk at a phone's edge).

**Turning.** A turning sticker is never drawn narrower than
`StagePlan.narrowest` (half its width): it flips through edge-on in a
blink, never showing a sliver.

**Its back to us going out.** A move can name another as its `away`
(`docs/pack-format.md`): while a leg that way goes away from the viewer
— deeper into the scene more than across it — that move plays instead,
the character's back to us (the surfer paddling out, `paddle`'s
`paddle-out`); resting there, or coming back, it plays its own, looking
at us (`StageLeg.away`, `StagePlan.travel`). From its back to the front
it turns like any turn: a quick squash through edge-on round the moment
it gets there (`StagePlan.sample`), never a cut.

**Acting over a move that goes on** (afloat on a move that stays, or
aloft): the action's first and last keys — the sticker's still pose — are
left out (`StageActing.overMove`): it blends from the move's pose straight
into the action and back to the move as the action heads for its end,
never standing still on the water or in the air.

**Acting in the water** (`StageActing`). While a move that `stays` keeps
a sticker in water (the surfer paddling, a seal swimming, a pelican
afloat), an action the story cues there plays its body only when its
`on` names that water (riding a wave, `on: ["sea"]`). Any other keeps the
move's loop going and shows only its face — the eye, mouth and brow
attachments its keys swap (`PuppetRig.faceSlots`), over the move's pose
(`PuppetPose.wearingFace`): the surfer laughs as he paddles on, never
standing up on the water. It is the other way round from a flyer's
wings, which beat on through an action (`PuppetPose.flying`). Out of the
water, and on a move that does not stay (Forest's duckling swimming),
every action plays as before. An action that `faces` a way on screen
(riding a wave: right, the way the wave rolls) turns the whole sticker to
it as it starts, whatever way it faced, and back as it ends
(`StageActing.facing`) — never the head alone.

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
An action or an effect under way keeps the camera before anything that
begins meanwhile (the wave Nico rides crashes in view while the seal comes
in), the one that began first keeping it (`Focus.playing`). Anyone the
window's edge would cut goes wholly out or comes wholly in, giving up the
margin if that is the only way; a puppet counts as wide as its pose is
drawn (lying on his board is wider than standing). The stage counts it
so too: afloat on a move that stays, a sticker is at least as wide as it
is tall (`StageActor.ratio(at:in:)`), so it rests where all of that pose
is on the art — at the art's edge no camera can show more. Each frame it
takes the least move that brings every current beat's
sticker into the window, a margin in from its sides; when they do not
all fit it goes with the beat that began last, then adds as many of the
others as still fit. Then it takes in as many of the other stickers on
show (the cast) as still fit, nearest first, and it leaves nobody cut by
the window's edge when it can help it: a sticker it cannot take in whole
it leaves wholly out, as long as that keeps the beats in view (Nico
waiting at sea while the turtle swims stays whole, or out of the window,
never half). It eases there, never faster than 0.9 window widths
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
