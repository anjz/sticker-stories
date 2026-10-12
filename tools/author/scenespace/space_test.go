package main

import (
	"math"
	"testing"
)

func near(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

func TestGroundRoundTrip(t *testing.T) {
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

func TestDrawnHeightFollowsDepthDownToTheFloor(t *testing.T) {
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

func TestValidate(t *testing.T) {
	s := &Space{
		Horizon: 0.5, Ground: 0, Back: 7, Stand: Range{1.1, 6},
		Layers: []Layer{{ID: "fg", Depth: 1}},
		Places: map[string]Place{"meadow": {Ground: Polygon{{0.1, 0.1}, {0.9, 0.1}, {0.5, 0.4}}}},
	}
	if errs := s.Validate(nil, map[string]bool{"meadow": true}); len(errs) != 0 {
		t.Fatalf("valid space: %v", errs)
	}
	s.Places["sky"] = Place{Ground: Polygon{{0.1, 0.6}, {0.9, 0.6}, {0.5, 0.8}}}
	s.Layers = append(s.Layers, Layer{ID: "rest2", Depth: 2})
	if errs := s.Validate(nil, map[string]bool{"meadow": true}); len(errs) != 3 {
		t.Errorf("want 3 problems (not a feature, above horizon, two rests), got %v", errs)
	}
}

func TestForestSpaceIsValid(t *testing.T) {
	s, err := LoadSpace("../art/forest/space.json")
	if err != nil {
		t.Fatal(err)
	}
	features := map[string]bool{"meadow": true, "pond": true, "sky": true, "branches": true, "trunks": true}
	if errs := s.Validate(nil, features); len(errs) != 0 {
		t.Errorf("%v", errs)
	}
}
