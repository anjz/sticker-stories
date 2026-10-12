package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"regexp"
)

// Space is a pack's scene as a place with depth
// (tools/author/art/<pack>/space.json): a camera looking level at a ground,
// fitted to the painted art, so every point on the art has a depth and every
// sticker a size there.
//
// Units: x, y (height above the ground) and z (depth from the eye) are in
// art heights at depth 1, the depth of the nearest foreground layer. A
// sticker size s is its drawn height standing at depth 1, and s/z where it
// stands. Art points are fractions of the base art, origin bottom-left
// (the space saved positions use); on the wide art they run past 0…1.
type Space struct {
	// Horizon is the art y of the eye line: everything on the ground lies
	// below it, and the far ground meets it.
	Horizon float64 `json:"horizon"`
	// Ground is the art y of the ground at depth 1.
	Ground float64 `json:"ground"`
	// Back is the depth of the backdrop: where the ground ends and the
	// painted distance (far bushes, hills, sky) begins.
	Back float64 `json:"back"`
	// Stand is the range of depths stickers may stand at.
	Stand Range `json:"stand"`
	// Floor is the smallest drawn height a sticker shrinks to with depth,
	// in art heights, so a tiny one far away stays easy to see.
	Floor float64 `json:"floor,omitempty"`
	// Layers put the scene's planes in front of the background at their
	// depths: the foreground, and the planes painted between (art.json
	// scene.layers: the trees). A plane can be cut into pieces at their
	// own depths with masks (a tree whose roots stand in the meadow is
	// behind what stands in front of them); per plane, at most one layer
	// has no mask: the rest of it.
	Layers []Layer `json:"layers"`
	// Places are the pack's features (the same ids) as parts of the space.
	Places map[string]Place `json:"places"`
	// Sizes are stickers' drawn heights at depth 1 (art heights).
	Sizes map[string]float64 `json:"sizes,omitempty"`
	// Preview is what the viewer shows walking about; not part of the pack.
	Preview []PreviewSticker `json:"preview,omitempty"`
	// Lineup is where the sizing page last had each sticker (its feet), so
	// the comparison carries on; not part of the pack.
	Lineup []LineupSticker `json:"lineup,omitempty"`
}

type Range struct {
	Near float64 `json:"near"`
	Far  float64 `json:"far"`
}

// Polygon is a list of art points ([u, v] fractions of the base art).
type Polygon [][2]float64

// Layer is a scene plane, or a piece of one, at one depth.
type Layer struct {
	ID string `json:"id"`
	// Art is the plane it shows: "foreground" (the default) or the id of
	// one of the scene's layers in art.json.
	Art   string  `json:"art,omitempty"`
	Depth float64 `json:"depth"`
	// Mask is the part of the plane that is this layer; absent on the
	// layer that is the rest of it.
	Mask Polygon `json:"mask,omitempty"`
	// Footprint is the ground it stands on, where nothing can walk
	// (a trunk's roots), as feet positions.
	Footprint Polygon `json:"footprint,omitempty"`
	// Wide is the same piece on the wide art, which paints it elsewhere.
	Wide *LayerRendition `json:"wide,omitempty"`
}

type LayerRendition struct {
	Depth     float64 `json:"depth"`
	Mask      Polygon `json:"mask,omitempty"`
	Footprint Polygon `json:"footprint,omitempty"`
}

// Place is a feature in space: ground to stand on (feet positions), open
// air to fly in, or lines on a foreground layer (a branch to perch on, the
// bark of a trunk).
type Place struct {
	Ground Polygon `json:"ground,omitempty"`
	// Water: the ground is water (only swimmers and those whose stage
	// lands there go in).
	Water     bool   `json:"water,omitempty"`
	Air       *Air   `json:"air,omitempty"`
	Lines     []Line `json:"lines,omitempty"`
	WideLines []Line `json:"wideLines,omitempty"`
}

type Air struct {
	Area  Polygon    `json:"area"`
	Depth [2]float64 `json:"depth"`
}

// Line is where feet (a perch) or a front (bark) go on a layer, at its
// depth.
type Line struct {
	Layer  string  `json:"layer"`
	Points Polygon `json:"points"`
	Facing string  `json:"facing,omitempty"`
}

type LineupSticker struct {
	Sticker string     `json:"sticker"`
	At      [2]float64 `json:"at"`
	Flip    bool       `json:"flip,omitempty"`
}

type PreviewSticker struct {
	Sticker string      `json:"sticker"`
	At      *[2]float64 `json:"at,omitempty"`
	Path    Polygon     `json:"path,omitempty"`
	Perch   string      `json:"perch,omitempty"`
	Fly     Polygon     `json:"fly,omitempty"`
	Depth   float64     `json:"depth,omitempty"`
}

// Plane is the scene plane the layer shows.
func (l Layer) Plane() string {
	if l.Art == "" {
		return "foreground"
	}
	return l.Art
}

// Save writes the space as JSON with each [u, v] point on one line.
func (s *Space) Save(path string) error {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	data = compactPoints.ReplaceAll(data, []byte("[$1, $2]"))
	return os.WriteFile(path, append(data, '\n'), 0o644)
}

var compactPoints = regexp.MustCompile(`\[\s+(-?[\d.e+-]+),\s+(-?[\d.e+-]+)\s+\]`)

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

// Validate returns every problem found. stickers are the pack's sticker
// ids and features its feature ids.
func (s *Space) Validate(stickers, features map[string]bool) []error {
	var errs []error
	fail := func(format string, a ...any) { errs = append(errs, fmt.Errorf(format, a...)) }
	if s.Horizon <= 0 || s.Horizon >= 1 {
		fail("horizon %v: must be inside the art (0…1)", s.Horizon)
	}
	if s.Ground >= s.Horizon {
		fail("ground %v: must be below the horizon %v", s.Ground, s.Horizon)
	}
	if s.Stand.Near <= 0 || s.Stand.Far <= s.Stand.Near {
		fail("stand %v…%v: needs 0 < near < far", s.Stand.Near, s.Stand.Far)
	}
	if s.Back < s.Stand.Far {
		fail("back %v: must be at least stand.far %v", s.Back, s.Stand.Far)
	}
	if s.Floor < 0 || s.Floor >= 1 {
		fail("floor %v: must be a fraction of the art's height", s.Floor)
	}
	ground := func(field string, p Polygon) {
		if len(p) < 3 {
			fail("%s: a polygon needs at least 3 points", field)
		}
		for _, pt := range p {
			if pt[1] >= s.Horizon {
				fail("%s: point %v is not below the horizon (feet are on the ground)", field, pt)
				return
			}
			if z := s.GroundDepth(pt[1]); z > s.Back {
				fail("%s: point %v is at depth %.2f, past the backdrop (%v)", field, pt, z, s.Back)
				return
			}
		}
	}
	layers := map[string]bool{}
	rest := map[string]int{}
	for i, l := range s.Layers {
		field := fmt.Sprintf("layers[%d] %q", i, l.ID)
		if l.ID == "" || layers[l.ID] {
			fail("%s: needs a unique id", field)
		}
		layers[l.ID] = true
		if l.Depth <= 0 || l.Depth > s.Back {
			fail("%s: depth %v must be in (0, back]", field, l.Depth)
		}
		if l.Mask == nil {
			rest[l.Plane()]++
			if l.Wide != nil && l.Wide.Mask != nil {
				fail("%s: the rest has no mask, wide or not", field)
			}
		} else if len(l.Mask) < 3 {
			fail("%s: mask needs at least 3 points", field)
		}
		if l.Footprint != nil {
			ground(field+" footprint", l.Footprint)
		}
		if w := l.Wide; w != nil {
			if w.Depth <= 0 || w.Depth > s.Back {
				fail("%s: wide depth %v must be in (0, back]", field, w.Depth)
			}
			if l.Mask != nil && len(w.Mask) < 3 {
				fail("%s: wide mask needs at least 3 points", field)
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
	for id, p := range s.Places {
		field := "places." + id
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
			if len(a.Area) < 3 {
				fail("%s air: area needs at least 3 points", field)
			}
			if a.Depth[0] <= 0 || a.Depth[1] < a.Depth[0] || a.Depth[1] > s.Back {
				fail("%s air: depth %v must be within (0, back], near first", field, a.Depth)
			}
		}
		if p.Lines != nil {
			kinds++
		}
		for _, lines := range [][]Line{p.Lines, p.WideLines} {
			for _, l := range lines {
				if !layers[l.Layer] {
					fail("%s: line on unknown layer %q", field, l.Layer)
				}
				if len(l.Points) < 2 {
					fail("%s: a line needs at least 2 points", field)
				}
				if l.Facing != "" && l.Facing != "left" && l.Facing != "right" {
					fail("%s: facing %q must be left or right", field, l.Facing)
				}
			}
		}
		if kinds != 1 {
			fail("%s: needs exactly one of ground, air or lines", field)
		}
	}
	for id, size := range s.Sizes {
		if stickers != nil && !stickers[id] {
			fail("sizes.%s: not a sticker of the pack", id)
		}
		if size <= 0 {
			fail("sizes.%s: %v must be positive", id, size)
		}
	}
	for i, l := range s.Lineup {
		if stickers != nil && !stickers[l.Sticker] {
			fail("lineup[%d] %q: not a sticker of the pack", i, l.Sticker)
		}
	}
	for i, p := range s.Preview {
		field := fmt.Sprintf("preview[%d] %q", i, p.Sticker)
		if stickers != nil && !stickers[p.Sticker] {
			fail("%s: not a sticker of the pack", field)
		}
		if _, ok := s.Sizes[p.Sticker]; !ok {
			fail("%s: has no size", field)
		}
		if p.Perch != "" && s.Places[p.Perch].Lines == nil {
			fail("%s: perch %q is not a place with lines", field, p.Perch)
		}
		if p.Fly != nil && p.Depth <= 0 {
			fail("%s: a flyer needs a depth", field)
		}
	}
	return errs
}
