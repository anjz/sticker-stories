package manifest

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// validAnimation writes a sidecar for the fox (with its sheet) under dir
// and returns the sidecar's pack-relative path.
func validAnimation(t *testing.T, dir string, mutate func(a *StickerAnimation)) string {
	t.Helper()
	a := StickerAnimation{ID: "yawn", Sticker: "fox", Description: "the fox yawns and stretches.", Sheet: "anims/fox.yawn.webp", Columns: 4, Count: 8,
		Rest: UnitBox{X: 0.03, Y: 0.2, Width: 0.9, Height: 0.75}, StickerBox: UnitBox{X: 0.03, Y: 0.04, Width: 0.94, Height: 0.92},
		Hold: []float64{0.3, 0.2, 0.1, 0.1, 0.1, 0.2, 0.2, 0.3}}
	a.Frame.Width, a.Frame.Height = 712, 808
	if mutate != nil {
		mutate(&a)
	}
	os.MkdirAll(filepath.Join(dir, "anims"), 0o755)
	os.WriteFile(filepath.Join(dir, "anims", "fox.yawn.webp"), []byte("x"), 0o644)
	data, _ := json.Marshal(a)
	os.WriteFile(filepath.Join(dir, "anims", "fox.yawn.json"), data, 0o644)
	return "anims/fox.yawn.json"
}

func TestAnimationsValidate(t *testing.T) {
	dir := t.TempDir()
	m := validManifest(t, dir)
	m.Stickers[1].Animations = []string{validAnimation(t, dir, nil)}
	if errs := m.Validate(dir); len(errs) != 0 {
		t.Fatalf("valid animation rejected: %v", errs)
	}

	cases := []struct {
		name    string
		mutate  func(a *StickerAnimation)
		wantSub string
	}{
		{"wrong sticker", func(a *StickerAnimation) { a.Sticker = "mushroom" }, "does not match"},
		{"missing sheet", func(a *StickerAnimation) { a.Sheet = "anims/nope.webp" }, "not found"},
		{"sheet not an image", func(a *StickerAnimation) { a.Sheet = "anims/fox.yawn.json" }, ".png or .webp"},
		{"hold count", func(a *StickerAnimation) { a.Hold = a.Hold[:3] }, "hold has 3 entries"},
		{"hold too short", func(a *StickerAnimation) { a.Hold[2] = 0.001 }, "outside"},
		{"no frames", func(a *StickerAnimation) { a.Count = 0; a.Hold = nil }, "count must be"},
		{"box outside", func(a *StickerAnimation) { a.Rest.Width = 1.5 }, "unit square"},
		{"no description", func(a *StickerAnimation) { a.Description = " " }, "description"},
		{"empty frame", func(a *StickerAnimation) { a.Frame.Height = 0 }, "frame size"},
		{"unknown kind", func(a *StickerAnimation) { a.Kind = "dance" }, "action or move"},
		{"pause on the first frame", func(a *StickerAnimation) { a.Pause = &AnimationPause{Frame: 0, Shows: "x"} }, "middle frame"},
		{"pause without shows", func(a *StickerAnimation) { a.Pause = &AnimationPause{Frame: 3} }, "pause.shows"},
		{"loop on an action", func(a *StickerAnimation) { a.Loop = &FrameRange{From: 1, To: 4} }, "belong to a move"},
		{"pause on a move", func(a *StickerAnimation) { a.Kind = KindMove; a.Pause = &AnimationPause{Frame: 3, Shows: "x"} }, "belongs to an action"},
		{"loop outside", func(a *StickerAnimation) {
			a.Kind, a.Loop, a.Facing, a.Stride = KindMove, &FrameRange{From: 1, To: 8}, "left", 0.5
		}, "within 0–7"},
		{"loop without facing", func(a *StickerAnimation) { a.Kind, a.Loop, a.Stride = KindMove, &FrameRange{From: 1, To: 6}, 0.5 }, "facing"},
		{"loop without stride", func(a *StickerAnimation) { a.Kind, a.Loop, a.Facing = KindMove, &FrameRange{From: 1, To: 6}, "right" }, "stride"},
		{"facing without loop", func(a *StickerAnimation) { a.Kind, a.Facing = KindMove, "right" }, "need a loop"},
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
			a := StickerAnimation{ID: id, Sticker: "fox", Kind: KindMove, Description: "the fox trots.", Sheet: "anims/fox.yawn.webp", Columns: 4, Count: 8,
				Rest: UnitBox{X: 0.1, Y: 0.1, Width: 0.8, Height: 0.8}, StickerBox: UnitBox{X: 0.1, Y: 0.1, Width: 0.8, Height: 0.8},
				Hold: []float64{0.1, 0.08, 0.08, 0.08, 0.08, 0.08, 0.08, 0.3}, Loop: &FrameRange{From: 1, To: 6}, Facing: "left", Stride: 0.6, Hops: true}
			a.Frame.Width, a.Frame.Height = 400, 400
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
		m.Stickers[1].Animations = []string{"anims/fox.yawn.webp"}
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
