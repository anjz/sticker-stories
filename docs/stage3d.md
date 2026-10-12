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
  wholly inside the clear part.

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
3. **Moves.** Each `go` ends at a pose planned in space: beside someone at
   their depth, on or under them, at a free spot of a place (in it, or on
   its shore for one that does not belong in its water), off the stage,
   back home. Walkers follow a path on the ground around water and roots
   (A* on a grid of the ground plane, then straightened); a way that
   belongs to the water walks to its edge and swims the rest; flyers arc
   up through the air and down. Every leg's time follows the distance in the
   world and the sticker's gait.
4. **Actions in their place** (the woodpecker on the bark) go there first,
   as before (`PlacementPlanner`).
5. **Out of the story's way.** The director plans the story once to see
   where its cast — every sticker it names, moves, sends someone to or
   cues anything on — will be and pass; a child's sticker the story does
   not use that stands in the way walks (or fades) to the freest land on
   screen away from the cast, the further back and nearer the sides the
   better, as the story starts; then the story is planned again round it.

## Rendering

Every frame each sticker's pose at that time is projected: its feet's
screen point, its drawn height, and its order — nearer in front, at the
same depth the one that got there last in front. The scene's planes sit in
that order at their depths. Effects (a wobble, a jump) compose on top of
the projected placement, sized to the sticker as it is drawn. The child's
canvas comes back exactly when the story ends.
