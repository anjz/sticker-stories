package manifest

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// validAnimation writes a sidecar for the fox (with its rig, eight keys)
// under dir and returns the sidecar's pack-relative path.
func validAnimation(t *testing.T, dir string, mutate func(a *StickerAnimation)) string {
	t.Helper()
	validRig(t, dir, nil)
	a := StickerAnimation{ID: "yawn", Sticker: "fox", Description: "the fox yawns and stretches.",
		StickerBox: UnitBox{X: 0.03, Y: 0.04, Width: 0.94, Height: 0.92},
		Puppet:     puppetHolding(0.3, 0.2, 0.1, 0.1, 0.1, 0.2, 0.2, 0.3)}
	if mutate != nil {
		mutate(&a)
	}
	data, _ := json.Marshal(a)
	os.WriteFile(filepath.Join(dir, "anims", "fox.yawn.json"), data, 0o644)
	return "anims/fox.yawn.json"
}

func TestAnimationsValidate(t *testing.T) {
	dir := t.TempDir()
	m := validManifest(t, dir)
	m.Stickers[1].Animations = []string{validAnimation(t, dir, func(a *StickerAnimation) {
		i := 0.8
		a.Particles = []AnimationParticle{{Frame: 2, Effect: "dust-puff", X: 0.5, Y: 0.95, Intensity: &i}, {Frame: 3, Effect: "sparks", X: 0.4, Y: -0.1, Color: "#FFCC00"}}
	})}
	if errs := m.Validate(dir); len(errs) != 0 {
		t.Fatalf("valid animation rejected: %v", errs)
	}

	cases := []struct {
		name    string
		mutate  func(a *StickerAnimation)
		wantSub string
	}{
		{"wrong sticker", func(a *StickerAnimation) { a.Sticker = "mushroom" }, "does not match"},
		{"no puppet", func(a *StickerAnimation) { a.Puppet = nil }, "puppet must give"},
		{"hold too short", func(a *StickerAnimation) { a.Puppet.Keys[2].Hold = 0.001 }, "outside"},
		{"box outside", func(a *StickerAnimation) { a.StickerBox.Width = 1.5 }, "unit square"},
		{"no description", func(a *StickerAnimation) { a.Description = " " }, "description"},
		{"unknown kind", func(a *StickerAnimation) { a.Kind = "dance" }, "action or move"},
		{"pause on the first frame", func(a *StickerAnimation) { a.Pause = &AnimationPause{Frame: 0, Shows: "x"} }, "middle frame"},
		{"pause without shows", func(a *StickerAnimation) { a.Pause = &AnimationPause{Frame: 3} }, "pause.shows"},
		{"loop on an action", func(a *StickerAnimation) { a.Loop = &FrameRange{From: 1, To: 4} }, "belong to a move"},
		{"pause on a move", func(a *StickerAnimation) { a.Kind = KindMove; a.Pause = &AnimationPause{Frame: 3, Shows: "x"} }, "belong to an action"},
		{"loop outside", func(a *StickerAnimation) {
			a.Kind, a.Loop, a.Facing, a.Stride = KindMove, &FrameRange{From: 1, To: 8}, "left", 0.5
		}, "within 0–7"},
		{"loop without facing", func(a *StickerAnimation) { a.Kind, a.Loop, a.Stride = KindMove, &FrameRange{From: 1, To: 6}, 0.5 }, "facing"},
		{"loop without stride", func(a *StickerAnimation) { a.Kind, a.Loop, a.Facing = KindMove, &FrameRange{From: 1, To: 6}, "right" }, "stride"},
		{"facing without loop", func(a *StickerAnimation) { a.Kind, a.Facing = KindMove, "right" }, "need a loop"},
		{"stays on an action", func(a *StickerAnimation) { a.Stays = true }, "belong to a move"},
		{"stays without on", func(a *StickerAnimation) {
			a.Kind, a.Loop, a.Facing, a.Stride, a.Stays = KindMove, &FrameRange{From: 1, To: 6}, "left", 0.5, true
		}, "stays needs on"},
		{"waterline on an action", func(a *StickerAnimation) { a.Waterline = 0.3 }, "belong to a move"},
		{"waterline without on", func(a *StickerAnimation) {
			a.Kind, a.Loop, a.Facing, a.Stride, a.Waterline = KindMove, &FrameRange{From: 1, To: 6}, "left", 0.5, 0.3
		}, "waterline needs on"},
		{"waterline of the whole drawing", func(a *StickerAnimation) {
			a.Kind, a.Loop, a.Facing, a.Stride, a.On, a.Waterline = KindMove, &FrameRange{From: 1, To: 6}, "left", 0.5, []string{"pond"}, 1
		}, "below 1"},
		{"hovers on an action", func(a *StickerAnimation) { a.Hovers = true }, "belong to a move"},
		{"hovers without flies", func(a *StickerAnimation) {
			a.Kind, a.Loop, a.Facing, a.Stride, a.Hovers = KindMove, &FrameRange{From: 1, To: 6}, "left", 0.5, true
		}, "hovers needs flies"},
		{"particle on a missing frame", func(a *StickerAnimation) {
			a.Particles = []AnimationParticle{{Frame: 99, Effect: "dust-puff", X: 0.5, Y: 0.9}}
		}, "is not one of the"},
		{"particle that is not a particle", func(a *StickerAnimation) {
			a.Particles = []AnimationParticle{{Frame: 1, Effect: "hearts", X: 0.5, Y: 0.9}}
		}, "must be one of dust-puff"},
		{"particle far outside", func(a *StickerAnimation) {
			a.Particles = []AnimationParticle{{Frame: 1, Effect: "spray", X: 2, Y: 0.9}}
		}, "within -0.5–1.5"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			m := validManifest(t, dir)
			m.Stickers[1].Animations = []string{validAnimation(t, dir, tc.mutate)}
			errs := m.Validate(dir)
			found := false
			for _, e := range errs {
				if strings.Contains(e.Error(), tc.wantSub) {
					found = true
				}
			}
			if !found {
				t.Errorf("no error mentioning %q in %v", tc.wantSub, errs)
			}
		})
	}

	t.Run("a pausable action and a walk are fine; a second move must loop", func(t *testing.T) {
		dir := t.TempDir()
		m := validManifest(t, dir)
		m.Stickers[1].Animations = []string{validAnimation(t, dir, func(a *StickerAnimation) {
			a.Pause = &AnimationPause{Frame: 3, Shows: "the fox asleep"}
		})}
		walk := func(id string, mutate ...func(*StickerAnimation)) string {
			a := StickerAnimation{ID: id, Sticker: "fox", Kind: KindMove, Description: "the fox trots.",
				StickerBox: UnitBox{X: 0.1, Y: 0.1, Width: 0.8, Height: 0.8}, Puppet: puppetHolding(0.1, 0.08, 0.08, 0.08, 0.08, 0.08, 0.08, 0.3),
				Loop: &FrameRange{From: 1, To: 6}, Facing: "left", Stride: 0.6, Hops: true}
			for _, f := range mutate {
				f(&a)
			}
			data, _ := json.Marshal(a)
			os.WriteFile(filepath.Join(dir, "anims", "fox."+id+".json"), data, 0o644)
			return "anims/fox." + id + ".json"
		}
		m.Stickers[1].Animations = append(m.Stickers[1].Animations, walk("trot"))
		if errs := m.Validate(dir); len(errs) != 0 {
			t.Fatalf("valid action and move rejected: %v", errs)
		}
		base := m.Stickers[1].Animations
		m.Features = map[string]Feature{"pond": {Description: "The small pond.", Areas: []StageArea{{X: []float64{0.57, 0.74}, Y: []float64{0.3, 0.37}}}}}
		// Another way to go: the fox can swim too, into the pond.
		m.Stickers[1].Animations = append(base, walk("swim", func(a *StickerAnimation) { a.Hops, a.On = false, []string{"pond"} }))
		if errs := m.Validate(dir); len(errs) != 0 {
			t.Errorf("a second looping move rejected: %v", errs)
		}
		m.Stickers[1].Animations = append(base, walk("run", func(a *StickerAnimation) { a.Loop, a.Facing, a.Stride, a.Hops = nil, "", 0, false }))
		if errs := m.Validate(dir); len(errs) != 1 || !strings.Contains(errs[0].Error(), "second move must loop") {
			t.Errorf("a second move without a loop: %v", errs)
		}
		m.Stickers[1].Animations = append(base, walk("fly", func(a *StickerAnimation) { a.Flies, a.On = true, []string{"lake"} }))
		errs := m.Validate(dir)
		if len(errs) != 2 || !strings.Contains(fmt.Sprint(errs), "hops or flies") || !strings.Contains(fmt.Sprint(errs), `"lake" is not a feature`) {
			t.Errorf("a flying hop onto a missing feature: %v", errs)
		}
	})

	t.Run("missing sidecar", func(t *testing.T) {
		dir := t.TempDir()
		m := validManifest(t, dir)
		m.Stickers[1].Animations = []string{"anims/fox.nope.json"}
		if errs := m.Validate(dir); len(errs) != 1 || !strings.Contains(errs[0].Error(), "not found") {
			t.Errorf("got %v", errs)
		}
	})
	t.Run("sidecar must be json", func(t *testing.T) {
		dir := t.TempDir()
		m := validManifest(t, dir)
		validAnimation(t, dir, nil)
		m.Stickers[1].Animations = []string{"anims/fox.rig.webp"}
		if errs := m.Validate(dir); len(errs) != 1 || !strings.Contains(errs[0].Error(), ".json") {
			t.Errorf("got %v", errs)
		}
	})
	t.Run("unknown key is an error", func(t *testing.T) {
		dir := t.TempDir()
		m := validManifest(t, dir)
		rel := validAnimation(t, dir, nil)
		p := filepath.Join(dir, filepath.FromSlash(rel))
		data, _ := os.ReadFile(p)
		os.WriteFile(p, []byte(strings.Replace(string(data), `"id":`, `"loop":true,"id":`, 1)), 0o644)
		m.Stickers[1].Animations = []string{rel}
		if errs := m.Validate(dir); len(errs) != 1 || !strings.Contains(errs[0].Error(), "loop") {
			t.Errorf("got %v", errs)
		}
	})
}

func TestPerchedIsForActions(t *testing.T) {
	dir := t.TempDir()
	m := validManifest(t, dir)
	m.Stickers[1].Animations = []string{validAnimation(t, dir, func(a *StickerAnimation) { a.Perched = true })}
	if errs := m.Validate(dir); len(errs) != 0 {
		t.Errorf("a perched action rejected: %v", errs)
	}
	m.Stickers[1].Animations = []string{validAnimation(t, dir, func(a *StickerAnimation) {
		a.Kind, a.Perched, a.Loop, a.Facing, a.Stride = KindMove, true, &FrameRange{From: 1, To: 2}, "left", 0.5
	})}
	if errs := m.Validate(dir); len(errs) != 1 || !strings.Contains(errs[0].Error(), "perched, idle, place and props belong to an action") {
		t.Errorf("a perched move: %v", errs)
	}
}

func TestIdleIsForActions(t *testing.T) {
	dir := t.TempDir()
	m := validManifest(t, dir)
	m.Stickers[1].Animations = []string{validAnimation(t, dir, func(a *StickerAnimation) { a.Idle = true })}
	if errs := m.Validate(dir); len(errs) != 0 {
		t.Errorf("an idle action rejected: %v", errs)
	}
	m.Stickers[1].Animations = []string{validAnimation(t, dir, func(a *StickerAnimation) {
		a.Kind, a.Idle, a.Loop, a.Facing, a.Stride = KindMove, true, &FrameRange{From: 1, To: 2}, "left", 0.5
	})}
	if errs := m.Validate(dir); len(errs) != 1 || !strings.Contains(errs[0].Error(), "idle") {
		t.Errorf("an idle move: %v", errs)
	}
}

func TestPlaceNamesFeatures(t *testing.T) {
	dir := t.TempDir()
	m := validManifest(t, dir)
	m.Features = map[string]Feature{"trunks": {Description: "Bark.", Areas: []StageArea{{X: []float64{0.05, 0.06}, Y: []float64{0.5, 0.7}, Facing: "left"}}}}
	m.Stickers[1].Animations = []string{validAnimation(t, dir, func(a *StickerAnimation) { a.Place = []string{"trunks"} })}
	if errs := m.Validate(dir); len(errs) != 0 {
		t.Errorf("an action on the trunks rejected: %v", errs)
	}
	m.Stickers[1].Animations = []string{validAnimation(t, dir, func(a *StickerAnimation) { a.Place = []string{"cliff"} })}
	m.Features["trunks"].Areas[0].Facing = "up"
	errs := fmt.Sprint(m.Validate(dir))
	if !strings.Contains(errs, `place: "cliff" is not a feature`) || !strings.Contains(errs, "facing must be left or right") {
		t.Errorf("a missing place and a bad facing: %v", errs)
	}
}

func TestActionOnFacesAndMoveAway(t *testing.T) {
	water := map[string]Feature{"sea": {Description: "The sea.", Areas: []StageArea{{X: []float64{0.1, 0.9}, Y: []float64{0.5, 0.6}}}}}
	move := func(dir, id string, mutate func(*StickerAnimation)) string {
		a := StickerAnimation{ID: id, Sticker: "fox", Kind: KindMove, Description: "the fox paddles.",
			StickerBox: UnitBox{X: 0.1, Y: 0.1, Width: 0.8, Height: 0.8}, Puppet: puppetHolding(0.1, 0.08, 0.08, 0.08, 0.08, 0.08, 0.08, 0.3),
			Loop: &FrameRange{From: 1, To: 6}, Facing: "left", Stride: 0.6}
		if mutate != nil {
			mutate(&a)
		}
		data, _ := json.Marshal(a)
		os.WriteFile(filepath.Join(dir, "anims", "fox."+id+".json"), data, 0o644)
		return "anims/fox." + id + ".json"
	}
	setup := func(t *testing.T, action func(*StickerAnimation), paddle func(*StickerAnimation)) (*Manifest, string) {
		dir := t.TempDir()
		m := validManifest(t, dir)
		m.Features = water
		m.Stickers[1].Animations = []string{
			validAnimation(t, dir, action),
			move(dir, "paddle", func(a *StickerAnimation) {
				a.On, a.Stays, a.Away = []string{"sea"}, true, "paddle-out"
				if paddle != nil {
					paddle(a)
				}
			}),
			move(dir, "paddle-out", nil),
		}
		return m, dir
	}
	m, dir := setup(t, func(a *StickerAnimation) {
		a.On, a.Faces = []string{"sea"}, "right"
		a.Effects = []AnimationEffect{{Frame: 1, Effect: "surf-wave"}}
	}, func(a *StickerAnimation) { a.Faces, a.Rest = "right", "paddle-out" })
	if errs := m.Validate(dir); len(errs) != 0 {
		t.Fatalf("an action done in the sea facing right, and a paddle that paddles out, rejected: %v", errs)
	}
	cases := []struct {
		name           string
		action, paddle func(*StickerAnimation)
		wantSub        string
	}{
		{"an action on no feature", func(a *StickerAnimation) { a.On = []string{"moon"} }, nil, `on: "moon" is not a feature`},
		{"faces up", func(a *StickerAnimation) { a.Faces = "up" }, nil, "faces must be left or right"},
		{"faces up on a move", nil, func(a *StickerAnimation) { a.Faces = "up" }, "faces must be left or right"},
		{"rest on an action", func(a *StickerAnimation) { a.Rest = "paddle" }, nil, "belong to a move"},
		{"rest without stays", nil, func(a *StickerAnimation) { a.Stays, a.Rest = false, "paddle-out" }, "rest needs stays"},
		{"rest to no move", nil, func(a *StickerAnimation) { a.Rest = "sit" }, `rest: "sit" is not another looping move`},
		{"an effect a frame cannot start", func(a *StickerAnimation) { a.Effects = []AnimationEffect{{Frame: 1, Effect: "hop"}} }, nil, `effect "hop" must be one of surf-wave`},
		{"an effect past the frames", func(a *StickerAnimation) { a.Effects = []AnimationEffect{{Frame: 40, Effect: "surf-wave"}} }, nil, "frame 40 is not one of"},
		{"away on an action", func(a *StickerAnimation) { a.Away = "paddle" }, nil, "belong to a move"},
		{"away to no move", nil, func(a *StickerAnimation) { a.Away = "swim" }, `away: "swim" is not another looping move`},
		{"away to itself", nil, func(a *StickerAnimation) { a.Away = "paddle" }, "must be another move"},
		{"away to an action", nil, func(a *StickerAnimation) { a.Away = "yawn" }, `away: "yawn" is not another looping move`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m, dir := setup(t, tc.action, tc.paddle)
			if errs := fmt.Sprint(m.Validate(dir)); !strings.Contains(errs, tc.wantSub) {
				t.Errorf("no error mentioning %q in %v", tc.wantSub, errs)
			}
		})
	}
}

func TestPropsAreWhereAPausedActionHoldsThem(t *testing.T) {
	dir := t.TempDir()
	m := validManifest(t, dir)
	m.Stickers[1].Animations = []string{validAnimation(t, dir, func(a *StickerAnimation) {
		a.Pause = &AnimationPause{Frame: 2, Shows: "the kite up high"}
		a.Props = map[string]AnimationPoint{"kite": {X: 0.2, Y: -0.6}}
	})}
	if errs := m.Validate(dir); len(errs) != 0 {
		t.Errorf("a kite held out high above the image: %v", errs)
	}
	m.Stickers[1].Animations = []string{validAnimation(t, dir, func(a *StickerAnimation) {
		a.Props = map[string]AnimationPoint{"kite": {X: 0.2, Y: -0.6}}
	})}
	if errs := m.Validate(dir); len(errs) != 1 || !strings.Contains(errs[0].Error(), "props need a pause") {
		t.Errorf("props without a pause: %v", errs)
	}
}
