package manifest

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"slices"
)

// SceneLayer is a plane of the scene between the background and the
// foreground (the trees, the reeds at the pond): painted on its own, so
// stories can put a sticker between planes at its depth (Space). While
// the child edits the canvas the app draws it with the background.
type SceneLayer struct {
	ID        string `json:"id"`
	Image     string `json:"image"`
	ImageWide string `json:"imageWide,omitempty"`
}

// Sky is where the background is open sky (docs/pack-format.md, "Sky"):
// masks of the background's shape — white, their alpha the sky — for the
// base art and, exactly when the pack has wide art, for the wide art.
type Sky struct {
	Image     string `json:"image"`
	ImageWide string `json:"imageWide,omitempty"`
}

// Space is the scene as a place with depth (docs/pack-format.md,
// "Space"): a camera looking level at a ground, fitted to the art, so
// every point on the art has a depth and every sticker a size there.
//
// Units: x, y (height above the ground) and z (depth from the eye) are in
// art heights at depth 1, the depth of the nearest foreground layer. A
// sticker of size s is drawn s/z tall standing at depth z (never below
// Floor). Art points are fractions of the base art, origin bottom-left;
// on the wide art they run past 0…1.
type Space struct {
	// Horizon is the art y of the eye line.
	Horizon float64 `json:"horizon"`
	// Ground is the art y of the ground at depth 1.
	Ground float64 `json:"ground"`
	// Back is the depth of the backdrop: where the ground ends and the
	// painted distance begins.
	Back float64 `json:"back"`
	// Stand is the range of depths stickers stand at.
	Stand SpaceRange `json:"stand"`
	// Floor is the smallest height a sticker is drawn at, in art heights.
	Floor float64 `json:"floor,omitempty"`
	// Layers put the scene's planes (the foreground and Manifest.Layers)
	// at their depths, a plane cut into pieces by masks when its parts
	// stand at different depths.
	Layers []SpaceLayer `json:"layers"`
	// Places are features (the same ids) as parts of the space.
	Places map[string]SpacePlace `json:"places,omitempty"`
	// Sizes are stickers' drawn heights at depth 1, in art heights.
	Sizes map[string]float64 `json:"sizes"`
	// Edit is how big stickers are while the child edits the canvas;
	// without it, at their sizes (docs/pack-format.md, "Space").
	Edit *SpaceEdit `json:"edit,omitempty"`
}

// SpaceEdit sizes stickers while the child edits the canvas: Spread
// softens their differences in size (1: as they are; less draws them
// closer together, the biggest staying as it is: height = biggest ×
// (height / biggest)^Spread), and none is smaller on the screen than
// Minimum points (the square root of its drawing's width × height).
type SpaceEdit struct {
	Spread  float64 `json:"spread"`
	Minimum float64 `json:"minimum"`
}

type SpaceRange struct {
	Near float64 `json:"near"`
	Far  float64 `json:"far"`
}

// Polygon is a list of art points, [u, v].
type Polygon [][2]float64

// SpaceLayer is a scene plane, or a piece of one, at one depth.
type SpaceLayer struct {
	ID string `json:"id"`
	// Art is the plane it shows: "foreground" (the default) or a
	// Manifest.Layers id.
	Art   string  `json:"art,omitempty"`
	Depth float64 `json:"depth"`
	// Mask is the part of the plane that is this piece; absent on the
	// piece that is the rest of it.
	Mask Polygon `json:"mask,omitempty"`
	// Footprint is the ground it stands on, where nothing walks (feet
	// positions).
	Footprint Polygon `json:"footprint,omitempty"`
	// Wide is the same piece on the wide art, when it is painted elsewhere
	// there.
	Wide *SpaceLayerRendition `json:"wide,omitempty"`
}

type SpaceLayerRendition struct {
	Depth     float64 `json:"depth"`
	Mask      Polygon `json:"mask,omitempty"`
	Footprint Polygon `json:"footprint,omitempty"`
}

// Plane is the scene plane the layer shows.
func (l SpaceLayer) Plane() string {
	if l.Art == "" {
		return "foreground"
	}
	return l.Art
}

// SpacePlace is a feature in space: ground to stand on (feet positions),
// open air to fly in, or lines on a layer (a branch to perch on, the bark
// of a trunk).
type SpacePlace struct {
	Ground    Polygon     `json:"ground,omitempty"`
	Water     bool        `json:"water,omitempty"`
	Air       *SpaceAir   `json:"air,omitempty"`
	Lines     []SpaceLine `json:"lines,omitempty"`
	WideLines []SpaceLine `json:"wideLines,omitempty"`
}

type SpaceAir struct {
	Area  Polygon    `json:"area"`
	Depth [2]float64 `json:"depth"`
}

// SpaceLine is where feet (a perch) or a front (bark) go on a layer, at
// its depth.
type SpaceLine struct {
	Layer  string  `json:"layer"`
	Points Polygon `json:"points"`
	Facing string  `json:"facing,omitempty"`
}

// LoadSpace reads a space file (tools/author/art/<pack>/space.json); keys
// that are not the pack's (the viewer's preview, the sizing line-up) are
// left out.
func LoadSpace(path string) (*Space, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var s Space
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &s, nil
}

// EyeHeight is the eye's height above the ground.
func (s *Space) EyeHeight() float64 { return s.Horizon - s.Ground }

// GroundDepth is the depth of the ground seen at art y v (below the
// horizon).
func (s *Space) GroundDepth(v float64) float64 { return s.EyeHeight() / (s.Horizon - v) }

// GroundPoint is the spot on the ground seen at art point (u, v): its x and
// depth. aspect is the base art's width over its height.
func (s *Space) GroundPoint(u, v, aspect float64) (x, z float64) {
	z = s.GroundDepth(v)
	return (u - 0.5) * aspect * z, z
}

// Project is where a point in space shows on the art.
func (s *Space) Project(x, y, z, aspect float64) (u, v float64) {
	return 0.5 + x/(aspect*z), s.Horizon + (y-s.EyeHeight())/z
}

// DrawnHeight is a sticker of size size's height on the art at depth z,
// never below the floor (nor above its own size at depth 1 when that is
// smaller than the floor).
func (s *Space) DrawnHeight(size, z float64) float64 {
	return math.Max(size/z, math.Min(s.Floor, size))
}

// Validate returns every problem found. planes are the pack's scene layer
// ids, stickers its sticker ids and features its feature ids; a nil set is
// not checked against (a space being fitted before install).
func (s *Space) Validate(planes, stickers, features map[string]bool) []error {
	var errs []error
	fail := func(format string, a ...any) { errs = append(errs, fmt.Errorf("space: "+format, a...)) }
	if s.Horizon <= 0 || s.Horizon >= 1 {
		fail("horizon %v must be inside the art (0…1)", s.Horizon)
	}
	if s.Ground >= s.Horizon {
		fail("ground %v must be below the horizon %v", s.Ground, s.Horizon)
	}
	if s.Stand.Near <= 0 || s.Stand.Far <= s.Stand.Near {
		fail("stand %v…%v needs 0 < near < far", s.Stand.Near, s.Stand.Far)
	}
	if s.Back < s.Stand.Far {
		fail("back %v must be at least stand.far %v", s.Back, s.Stand.Far)
	}
	if s.Floor < 0 || s.Floor >= 1 {
		fail("floor %v must be a fraction of the art's height (0 up to 1)", s.Floor)
	}
	if e := s.Edit; e != nil {
		if e.Spread <= 0 || e.Spread > 1 {
			fail("edit.spread %v must be above 0 and at most 1", e.Spread)
		}
		if e.Minimum < 0 || e.Minimum > 200 {
			fail("edit.minimum %v must be 0–200 points", e.Minimum)
		}
	}
	inArt := func(field string, p Polygon, least int) bool {
		if len(p) < least {
			fail("%s needs at least %d points", field, least)
			return false
		}
		for _, pt := range p {
			if pt[0] < -WideMargin || pt[0] > 1+WideMargin || pt[1] < 0 || pt[1] > 1 {
				fail("%s: point %v must be within x −0.5…1.5, y 0…1", field, pt)
				return false
			}
		}
		return true
	}
	ground := func(field string, p Polygon) {
		if !inArt(field, p, 3) {
			return
		}
		for _, pt := range p {
			if pt[1] >= s.Horizon {
				fail("%s: point %v is not below the horizon (feet are on the ground)", field, pt)
				return
			}
			if s.Horizon > s.Ground && s.GroundDepth(pt[1]) > s.Back {
				fail("%s: point %v is at depth %.2f, past the backdrop (%v)", field, pt, s.GroundDepth(pt[1]), s.Back)
				return
			}
		}
	}
	depth := func(field string, z float64) {
		if z <= 0 || z > s.Back {
			fail("%s: depth %v must be in (0, back]", field, z)
		}
	}
	layers := map[string]bool{}
	rest := map[string]int{}
	shown := map[string]bool{}
	for i, l := range s.Layers {
		field := fmt.Sprintf("layers[%d] %q", i, l.ID)
		if !idPattern.MatchString(l.ID) || layers[l.ID] {
			fail("%s: needs a unique lowercase a-z0-9 id", field)
		}
		layers[l.ID] = true
		if planes != nil && l.Plane() != "foreground" && !planes[l.Plane()] {
			fail("%s: art %q is not one of the pack's layers", field, l.Plane())
		}
		shown[l.Plane()] = true
		depth(field, l.Depth)
		if l.Mask == nil {
			rest[l.Plane()]++
			if l.Wide != nil && l.Wide.Mask != nil {
				fail("%s: the rest of a plane has no mask, wide or not", field)
			}
		} else {
			inArt(field+" mask", l.Mask, 3)
		}
		if l.Footprint != nil {
			ground(field+" footprint", l.Footprint)
		}
		if w := l.Wide; w != nil {
			depth(field+" wide", w.Depth)
			if l.Mask != nil && w.Mask != nil {
				inArt(field+" wide mask", w.Mask, 3)
			}
			if w.Footprint != nil {
				ground(field+" wide footprint", w.Footprint)
			}
		}
	}
	for plane, n := range rest {
		if n > 1 {
			fail("layers: %d layers show all of %s; cut it with masks, one may be the rest", n, plane)
		}
	}
	if planes != nil {
		for _, plane := range append(sortedKeys(planes), "foreground") {
			if !shown[plane] {
				fail("layers: nothing puts %s at a depth", plane)
			}
		}
	}
	for _, id := range sortedKeys(s.Places) {
		p, field := s.Places[id], "places."+id
		if features != nil && !features[id] {
			fail("%s: not a feature of the pack", field)
		}
		kinds := 0
		if p.Ground != nil {
			kinds++
			ground(field+" ground", p.Ground)
		} else if p.Water {
			fail("%s: water needs ground", field)
		}
		if a := p.Air; a != nil {
			kinds++
			inArt(field+" air area", a.Area, 3)
			if a.Depth[0] <= 0 || a.Depth[1] < a.Depth[0] || a.Depth[1] > s.Back {
				fail("%s air: depth %v must be near…far within (0, back]", field, a.Depth)
			}
		}
		if p.Lines != nil {
			kinds++
		} else if p.WideLines != nil {
			fail("%s: wideLines need lines", field)
		}
		for _, lines := range [][]SpaceLine{p.Lines, p.WideLines} {
			for _, l := range lines {
				if !layers[l.Layer] {
					fail("%s: a line on %q, which is not one of the space's layers", field, l.Layer)
				}
				inArt(field+" line", l.Points, 2)
				if l.Facing != "" && l.Facing != "left" && l.Facing != "right" {
					fail("%s: facing %q must be left or right", field, l.Facing)
				}
			}
		}
		if kinds != 1 {
			fail("%s: needs exactly one of ground, air or lines", field)
		}
	}
	for _, id := range sortedKeys(s.Sizes) {
		if stickers != nil && !stickers[id] {
			fail("sizes.%s: not a sticker of the pack", id)
		}
		if size := s.Sizes[id]; size <= 0 || size > 5 {
			fail("sizes.%s: %v must be above 0 and at most 5", id, size)
		}
	}
	for _, id := range sortedKeys(stickers) {
		if _, ok := s.Sizes[id]; !ok {
			fail("sizes: sticker %q has no size", id)
		}
	}
	return errs
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}
