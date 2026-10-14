package manifest

import (
	"math"
	"strings"
	"testing"
)

func near(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

func TestSpaceGroundRoundTrip(t *testing.T) {
	s := &Space{Horizon: 0.5, Ground: 0.1}
	const aspect = 4.0 / 3
	for _, pt := range [][2]float64{{0.5, 0.1}, {0.2, 0.3}, {0.9, 0.45}, {-0.2, 0.05}} {
		x, z := s.GroundPoint(pt[0], pt[1], aspect)
		u, v := s.Project(x, 0, z, aspect)
		if !near(u, pt[0]) || !near(v, pt[1]) {
			t.Errorf("%v → (%v, %v) → (%v, %v)", pt, x, z, u, v)
		}
	}
	if z := s.GroundDepth(0.1); !near(z, 1) {
		t.Errorf("ground at depth 1: got depth %v", z)
	}
}

func TestSpaceDrawnHeightFollowsDepthDownToTheFloor(t *testing.T) {
	s := &Space{Horizon: 0.5, Floor: 0.05}
	if h := s.DrawnHeight(0.3, 2); !near(h, 0.15) {
		t.Errorf("0.3 at depth 2: %v", h)
	}
	if h := s.DrawnHeight(0.08, 4); !near(h, 0.05) {
		t.Errorf("held at the floor: %v", h)
	}
	if h := s.DrawnHeight(0.03, 4); !near(h, 0.03) {
		t.Errorf("never above its own size: %v", h)
	}
}

func validSpace() *Space {
	return &Space{
		Horizon: 0.5, Ground: 0, Back: 7, Stand: SpaceRange{1.1, 6},
		Layers: []SpaceLayer{{ID: "trees", Art: "trees", Depth: 2}, {ID: "front", Depth: 1}},
		Places: map[string]SpacePlace{
			"meadow": {Ground: Polygon{{0.1, 0.1}, {0.9, 0.1}, {0.5, 0.4}}},
			"branch": {Lines: []SpaceLine{{Layer: "trees", Points: Polygon{{0.1, 0.8}, {0.2, 0.85}}}}},
		},
		Sizes: map[string]float64{"fox": 0.3},
	}
}

func TestSpaceValidate(t *testing.T) {
	planes, stickers := map[string]bool{"trees": true}, map[string]bool{"fox": true}
	features := map[string]bool{"meadow": true, "branch": true}
	if errs := validSpace().Validate(planes, stickers, features); len(errs) != 0 {
		t.Fatalf("valid space: %v", errs)
	}
	edited := validSpace()
	edited.Edit = &SpaceEdit{Spread: 0.6, Minimum: 60}
	if errs := edited.Validate(planes, stickers, features); len(errs) != 0 {
		t.Fatalf("valid edit sizes: %v", errs)
	}
	cases := map[string]func(s *Space){
		"not a feature": func(s *Space) {
			s.Places["sky"] = SpacePlace{Air: &SpaceAir{Area: Polygon{{0, 0.6}, {1, 0.6}, {0.5, 0.9}}, Depth: [2]float64{2, 5}}}
		},
		"not below the horizon": func(s *Space) { s.Places["meadow"] = SpacePlace{Ground: Polygon{{0.1, 0.6}, {0.9, 0.6}, {0.5, 0.8}}} },
		"show all of trees":     func(s *Space) { s.Layers = append(s.Layers, SpaceLayer{ID: "more", Art: "trees", Depth: 3}) },
		"not one of the pack's": func(s *Space) { s.Layers[0].Art = "rocks" },
		"nothing puts trees":    func(s *Space) { s.Layers = s.Layers[1:]; s.Places = nil },
		"has no size":           func(s *Space) { delete(s.Sizes, "fox") },
		"not one of the space":  func(s *Space) { s.Places["branch"].Lines[0].Layer = "bush" },
		"exactly one of":        func(s *Space) { s.Places["meadow"] = SpacePlace{} },
		"edit.spread":           func(s *Space) { s.Edit = &SpaceEdit{Spread: 0, Minimum: 60} },
		"edit.minimum":          func(s *Space) { s.Edit = &SpaceEdit{Spread: 0.6, Minimum: -1} },
	}
	for want, change := range cases {
		s := validSpace()
		change(s)
		errs := s.Validate(planes, stickers, features)
		found := false
		for _, e := range errs {
			found = found || strings.Contains(e.Error(), want)
		}
		if !found {
			t.Errorf("%s: got %v", want, errs)
		}
	}
}
