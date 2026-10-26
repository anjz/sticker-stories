package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
	"testing"

	"stickerstories/tools/internal/manifest"
)

// A stiff leg reaching its foot to a place puts the foot's tip there.
func TestWaterLegReach(t *testing.T) {
	p := stickPerson()
	g := &gaitBody{p: p, dir: 1}
	leg := wtLegOf(g, "legL")
	rest := newGround(p, []string{"legL"}).bottom(0, p.world(nil))
	for _, d := range [][2]float64{{12, 0}, {-12, 0}, {8, -6}, {-5, -10}} {
		pose := leg.reach(d[0], d[1])
		// The tip of the foot at rest, carried by the leg.
		lx, ly := p.world(nil)["legL"].inv().apply(rest.x, rest.y)
		x, y := p.world(map[string]manifest.BonePose{"legL": pose})["legL"].apply(lx, ly)
		if math.Abs(x-rest.x-d[0]) > 0.5 || math.Abs(y-rest.y-d[1]) > 0.5 {
			t.Errorf("reach %v: the foot went (%.1f, %.1f)", d, x-rest.x, y-rest.y)
		}
	}
}

// TestWaterFeetSlip (WATER_PACK, WATER_ONLY, WATER_ANIM, WATER_FEET set)
// plays an installed move as the film does and says how far each foot's
// tip slides along the ground while it is down.
func TestWaterFeetSlip(t *testing.T) {
	pack := os.Getenv("WATER_PACK")
	if pack == "" {
		t.Skip("WATER_PACK not set")
	}
	only := os.Getenv("WATER_ONLY")
	c, err := load(pack, os.Getenv("WATER_ART"), only)
	if err != nil {
		t.Fatal(err)
	}
	p, anims, err := c.loadPuppet(only)
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range anims {
		if a.ID != os.Getenv("WATER_ANIM") {
			continue
		}
		dir := 1.0
		if a.Facing == "right" {
			dir = -1
		}
		if leg := os.Getenv("WATER_KEYS"); leg != "" {
			rest := p.world(nil)
			lo := newGround(p, []string{leg}).bottom(0, rest)
			lx, ly := rest[leg].inv().apply(lo.x, lo.y)
			for i, k := range a.Puppet.Keys {
				x, y := p.world(k.Bones)[leg].apply(lx, ly)
				t.Logf("key %d hold %.3f: %.1f %.1f", i, k.Hold, x, y-lo.y)
			}
		}
		frames := timeline(p, a, 3, 1200)
		rest := p.world(nil)
		for _, leg := range strings.Split(os.Getenv("WATER_FEET"), ",") {
			lo := newGround(p, []string{leg}).bottom(0, rest)
			lx, ly := rest[leg].inv().apply(lo.x, lo.y)
			var seg []float64
			var slips []float64
			flush := func() {
				if len(seg) > 60 {
					mn, mx := seg[0], seg[0]
					for _, v := range seg {
						mn, mx = math.Min(mn, v), math.Max(mx, v)
					}
					slips = append(slips, mx-mn)
				}
				seg = nil
			}
			for _, f := range frames {
				w := p.world(f.bones)
				x, y := w[leg].apply(lx, ly)
				var ry float64
				if rb, ok := f.bones[p.rig.Bones[0].ID]; ok {
					ry = rb.Y
				}
				_ = ry
				if os.Getenv("WATER_PRINT") == leg {
					t.Logf("x=%.1f y=%.1f world=%.1f dx=%.1f", x, y-lo.y, x-dir*f.dx, f.dx)
				}
				if y-lo.y > -0.3 {
					seg = append(seg, x-dir*f.dx)
				} else {
					flush()
				}
			}
			flush()
			t.Logf("%s: %d stances, slides %v px", leg, len(slips), fmtSlips(slips))
		}
	}
}

func fmtSlips(v []float64) string {
	var s []string
	for _, x := range v {
		s = append(s, strconv.FormatFloat(x, 'f', 1, 64))
	}
	return strings.Join(s, " ")
}

func TestWaterReachDebug(t *testing.T) {
	pack := os.Getenv("WATER_PACK")
	if pack == "" || os.Getenv("WATER_REACH") == "" {
		t.Skip()
	}
	only := os.Getenv("WATER_ONLY")
	c, _ := load(pack, os.Getenv("WATER_ART"), only)
	p, _, _ := c.loadPuppet(only)
	g := &gaitBody{p: p, dir: 1}
	leg := os.Getenv("WATER_REACH")
	l := wtLegOf(g, leg)
	rest := p.world(nil)
	lo := newGround(p, []string{leg}).bottom(0, rest)
	lx, ly := rest[leg].inv().apply(lo.x, lo.y)
	t.Logf("leg %+v", l)
	for dx := -24.0; dx <= 24; dx += 6 {
		q := l.reach(dx, 0)
		x, y := p.world(map[string]manifest.BonePose{leg: q})[leg].apply(lx, ly)
		t.Logf("dx %.0f: %+v tip moved %.1f %.1f", dx, q, x-lo.x, y-lo.y)
	}
}

// TestWaterRollKeys (WATER_PACK, WATER_ART, WATER_ONLY, WATER_ROLL =
// "<facing>,<keys>,<seconds a turn>") prints a roll's loop keys from
// object.roll, and its travel a turn.
func TestWaterRollKeys(t *testing.T) {
	spec := os.Getenv("WATER_ROLL")
	if spec == "" {
		t.Skip()
	}
	parts := strings.Split(spec, ",")
	n, _ := strconv.Atoi(parts[1])
	turn, _ := strconv.ParseFloat(parts[2], 64)
	only := os.Getenv("WATER_ONLY")
	c, err := load(os.Getenv("WATER_PACK"), os.Getenv("WATER_ART"), only)
	if err != nil {
		t.Fatal(err)
	}
	p, _, err := c.loadPuppet(only)
	if err != nil {
		t.Fatal(err)
	}
	g := &gaitBody{p: p, dir: 1, spec: gaitSpec{Style: "object.roll"}}
	if parts[0] == "right" {
		g.dir = -1
	}
	hull, _ := wtHull(g, "spin")
	t.Logf("hull perimeter %.1f px, width %.1f px", hull, wtWidth(p))
	for i := range n {
		gp := objectRoll(g, float64(i)/float64(n))
		s := gp.Bones["spin"]
		r := gp.Bones["root"]
		fmt.Printf("{\"hold\": %.3f, \"ease\": \"linear\", \"bones\": {\"spin\": {\"r\": %g}, \"root\": {\"y\": %.1f}}},\n", turn/float64(n), math.Round(s.R*100)/100, r.Y)
	}
}

// TestWaterGaitKeys (WATER_PACK, WATER_ART, WATER_ONLY, WATER_GAIT = an
// animation with a gait, as in a rig file) prints the keys the engine
// makes for it, the settle key keeping the gait's slots: for a move the
// engine cannot end yet (a body swapped for other pieces through it).
func TestWaterGaitKeys(t *testing.T) {
	spec := os.Getenv("WATER_GAIT")
	if spec == "" {
		t.Skip()
	}
	var a animSpec
	if err := json.Unmarshal([]byte(spec), &a); err != nil {
		t.Fatal(err)
	}
	only := os.Getenv("WATER_ONLY")
	c, err := load(os.Getenv("WATER_PACK"), os.Getenv("WATER_ART"), only)
	if err != nil {
		t.Fatal(err)
	}
	p, anims, err := c.loadPuppet(only)
	if err != nil {
		t.Fatal(err)
	}
	a, _, err = c.gaitAnim(nil, a, p, anims[0].StickerBox)
	if err != nil {
		t.Fatal(err)
	}
	n := len(a.Keys)
	a.Keys[n-2].Slots = a.Gait.Slots
	out, _ := json.Marshal(map[string]any{"keys": a.Keys, "loop": a.Loop})
	fmt.Println(string(out))
}
