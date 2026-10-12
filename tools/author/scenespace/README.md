# scenespace — the scene with depth

A pack's scene fitted with a camera and a ground, so every point on the
art has a depth and every sticker a size there: `space.json` beside the
pack's `art.json` (`tools/author/art/<pack>/space.json`). The viewer draws
it in 3D — the painted art projected from the camera onto the ground, the
backdrop and the foreground's layers — so the camera view is the picture
itself, and turning around shows where everything is.

```sh
cd tools
go run ./author/scenespace check -pack ../packs/forest   # validate, print depths and sizes
go run ./author/scenespace serve -pack ../packs/forest   # http://127.0.0.1:8737 (three.js from jsDelivr)
```

The page reads `space.json` again on every reload. Buttons (and keys):
camera view / turn around (C), base / wide art (W), art (A), places (P),
layers tinted with their depths (L), stickers (S), walk (space), hide the
panel (H). The pointer over the ground shows its art point and depth.
URL options start it that way: `?pov=0&places=1&layers=1&wide=1&walk=0&t=6`
(`t` is the walk's time, `from=x,y,z` where the turning camera starts) —
for pictures with headless Chrome.

## The model

Units are art heights at depth 1, the depth of the nearest foreground
layer. The camera looks level from the eye, `horizon − ground` above the
ground:

- the ground seen at art y `v` is at depth `z = (horizon − ground) / (horizon − v)`;
- a point `(x, y, z)` shows at `u = 0.5 + x / (aspect·z)`, `v = horizon + (y − eye) / z`;
- a sticker of size `s` (its drawn height at depth 1) is `s / z` tall,
  never below `floor` (or its own size, if that is smaller).

| field | |
|---|---|
| `horizon`, `ground` | art y of the eye line, and of the ground at depth 1 |
| `back` | depth of the backdrop, where the ground ends (Forest: the far bushes) |
| `stand` | depths stickers may stand at |
| `floor` | smallest drawn height, so tiny stickers stay visible far away |
| `layers` | the foreground cut into pieces at their depths: `mask` (art polygon; one layer has none — the rest), `footprint` (ground nothing walks on), `wide` (the same on the wide art) |
| `places` | the pack's features in space: `ground` (feet polygon; `water`), `air` (`area` + `depth` range), or `lines` / `wideLines` on a layer (a branch, the bark, with `facing`) |
| `sizes` | stickers' drawn heights at depth 1 |
| `preview` | what the viewer shows: `at`, `path` (feet points), `perch` (a place with lines), `fly` + `depth` |

All points are fractions of the base art, origin bottom-left; on the wide
art they run past 0…1. Measure them on a grid over the background with
the foreground on top: a tree's depth is where its roots meet the
ground.
