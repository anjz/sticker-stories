package manifest

import (
	"encoding/json"
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
