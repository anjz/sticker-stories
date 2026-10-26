package main

import (
	"image"
	"math"
	"testing"

	"stickerstories/tools/internal/manifest"
)

func TestCurveWrapsSmoothly(t *testing.T) {
	c := curve{{0, 10}, {0.25, 30}, {0.5, -10}, {0.75, 0}}
	for _, p := range c {
		if got := c.at(p[0]); math.Abs(got-p[1]) > 1e-9 {
			t.Errorf("at(%v) = %v, want %v", p[0], got, p[1])
		}
	}
	if a, b := c.at(0.999999), c.at(0); math.Abs(a-b) > 1e-3 {
		t.Errorf("not continuous round the loop: %v, %v", a, b)
	}
	if a, b := c.at(1.25), c.at(0.25); math.Abs(a-b) > 1e-9 {
		t.Errorf("not periodic: %v, %v", a, b)
	}
}

// stickPerson is a body box on two legs of a thigh and a shin each, the
// right leg a little higher (further away), root at the feet.
func stickPerson() *puppet {
	atlas := image.NewRGBA(image.Rect(0, 0, 100, 70))
	paintOutlined(atlas, image.Pt(0, 0), 60, 60, func(x, y int) bool { return x >= 0 && y >= 0 && x < 60 && y < 60 })
	paintOutlined(atlas, image.Pt(70, 0), 20, 60, func(x, y int) bool { return x >= 0 && y >= 0 && x < 20 && y < 60 })
	limb := func(id, bone string, x, y float64) manifest.PuppetSlot {
		return manifest.PuppetSlot{ID: id, Bone: bone, Default: "a", Attachments: map[string]manifest.PuppetAttachment{
			"a": {Part: "limb", X: x - 10, Y: y, W: 20, H: 60}}}
	}
	rig := &manifest.PuppetRig{
		Sticker: "stick", Size: 300,
		Parts: map[string]manifest.PuppetPart{"body": {Rect: [4]int{0, 0, 60, 60}}, "limb": {Rect: [4]int{70, 0, 20, 60}}},
		Bones: []manifest.PuppetBone{
			{ID: "root", X: 150, Y: 260}, {ID: "body", Parent: "root", X: 150, Y: 140},
			{ID: "legL", Parent: "root", X: 140, Y: 140}, {ID: "kneeL", Parent: "legL", X: 140, Y: 195},
			{ID: "legR", Parent: "root", X: 160, Y: 136}, {ID: "kneeR", Parent: "legR", X: 160, Y: 191},
		},
		Slots: []manifest.PuppetSlot{
			limb("thighR", "legR", 160, 136), limb("shinR", "kneeR", 160, 191),
			{ID: "body", Bone: "body", Default: "a", Attachments: map[string]manifest.PuppetAttachment{"a": {Part: "body", X: 120, Y: 85, W: 60, H: 60}}},
			limb("thighL", "legL", 140, 140), limb("shinL", "kneeL", 140, 195),
		},
	}
	return newPuppet(rig, atlas, nil)
}

func TestHumanWalk(t *testing.T) {
	c := &ctxt{}
	for _, facing := range []string{"left", "right"} {
		a := animSpec{ID: "walk", Kind: "move", Description: "walks", Facing: facing, Gait: &gaitSpec{Style: "human.walk"}}
		got, _, err := c.gaitAnim(&rigSpec{Sticker: "stick"}, a, stickPerson(), manifest.UnitBox{Width: 0.3})
		if err != nil {
			t.Fatal(err)
		}
		if len(got.Keys[0].Bones) > 0 || len(got.Keys[len(got.Keys)-1].Bones) > 0 {
			t.Errorf("%s: should start and end at rest", facing)
		}
		if got.Loop == nil || got.Loop.From != 1 || got.Loop.To != 14 {
			t.Fatalf("%s: loop %+v", facing, got.Loop)
		}
		if got.Stride < 0.2 || got.Stride > 2 {
			t.Errorf("%s: stride %v", facing, got.Stride)
		}
		dir := 1.0
		if facing == "right" {
			dir = -1
		}
		lo, hi := math.Inf(1), math.Inf(-1)
		for _, k := range got.Keys[1:15] {
			if k.Ease != "linear" {
				t.Errorf("%s: loop keys should move on linearly, got %q", facing, k.Ease)
			}
			// A knee folds the shin back, never forwards.
			for _, knee := range []string{"kneeL", "kneeR"} {
				if dir*k.Bones[knee].R > 0.01 {
					t.Errorf("%s: %s bends forwards (%v)", facing, knee, k.Bones[knee].R)
				}
			}
			lo, hi = math.Min(lo, k.Bones["root"].Y), math.Max(hi, k.Bones["root"].Y)
		}
		// The hips rise and fall a little, not a hop.
		if hi-lo < 1 || hi-lo > 15 {
			t.Errorf("%s: the body bobs %v px", facing, hi-lo)
		}
	}
}

func TestGaitNeedsKnownStyleAndFacing(t *testing.T) {
	c := &ctxt{}
	if _, _, err := c.gaitAnim(&rigSpec{}, animSpec{ID: "w", Facing: "left", Gait: &gaitSpec{Style: "nope"}}, stickPerson(), manifest.UnitBox{Width: 0.3}); err == nil {
		t.Error("unknown style accepted")
	}
	if _, _, err := c.gaitAnim(&rigSpec{}, animSpec{ID: "w", Gait: &gaitSpec{Style: "human.walk"}}, stickPerson(), manifest.UnitBox{Width: 0.3}); err == nil {
		t.Error("gait without facing accepted")
	}
}
