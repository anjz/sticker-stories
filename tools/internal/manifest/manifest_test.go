package manifest

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// validManifest returns a minimal manifest that passes every rule, with its
// referenced files materialised under dir.
func validManifest(t *testing.T, dir string) *Manifest {
	t.Helper()
	w := 2.0
	m := &Manifest{
		SchemaVersion: 1,
		ID:            "forest",
		Version:       1,
		DisplayName:   "Forest Friends",
		Theme:         "forest",
		Background:    "art/background.png",
		Foreground:    "art/foreground.png",
		Stickers: []Sticker{
			{ID: "mushroom", Name: "Mushroom", Image: "stickers/mushroom.png"},
			{ID: "fox", Name: "Fox", Image: "stickers/fox.png"},
		},
		Stories: []Story{
			{
				ID: "story-001", Title: "The Shy Mushroom", Text: "Once upon a time…",
				Audio:            "audio/story-001.m4a",
				RequiredStickers: []string{"mushroom"},
				OptionalStickers: []string{"fox"},
				Weight:           &w,
				Tags:             []string{"gentle"},
			},
			{
				ID: "story-002", Title: "A Forest Day", Text: "One sunny morning…",
				Audio: "audio/story-002.m4a",
			},
		},
	}
	for _, rel := range []string{
		m.Background, m.Foreground,
		"stickers/mushroom.png", "stickers/fox.png",
		"audio/story-001.m4a", "audio/story-002.m4a",
	} {
		p := filepath.Join(dir, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return m
}

func TestValidManifestPasses(t *testing.T) {
	dir := t.TempDir()
	m := validManifest(t, dir)
	if errs := m.Validate(dir); len(errs) != 0 {
		t.Fatalf("expected no errors, got %v", errs)
	}
}

func TestLoadRoundTrip(t *testing.T) {
	dir := t.TempDir()
	m := validManifest(t, dir)
	data, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "manifest.json"), data, 0o644); err != nil {
		t.Fatal(err)
	}
	loaded, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	if errs := loaded.Validate(dir); len(errs) != 0 {
		t.Fatalf("expected no errors after round trip, got %v", errs)
	}
	if loaded.Stories[0].EffectiveWeight() != 2.0 {
		t.Errorf("explicit weight lost: got %v", loaded.Stories[0].EffectiveWeight())
	}
	if loaded.Stories[1].EffectiveWeight() != 1.0 {
		t.Errorf("default weight should be 1.0, got %v", loaded.Stories[1].EffectiveWeight())
	}
}

func TestLoadRejectsBadJSON(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "manifest.json"), []byte("{nope"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(dir); err == nil {
		t.Fatal("expected parse error")
	}
}

func TestValidationFailures(t *testing.T) {
	cases := []struct {
		name    string
		mutate  func(m *Manifest)
		wantSub string // substring expected in one of the errors
	}{
		{"unsupported schema version", func(m *Manifest) { m.SchemaVersion = 99 }, "schemaVersion"},
		{"bad pack id", func(m *Manifest) { m.ID = "Forest Pack!" }, "pack id"},
		{"zero version", func(m *Manifest) { m.Version = 0 }, "version"},
		{"empty display name", func(m *Manifest) { m.DisplayName = " " }, "displayName"},
		{"missing background file", func(m *Manifest) { m.Background = "art/nope.png" }, "not found"},
		{"absolute path", func(m *Manifest) { m.Foreground = "/etc/passwd" }, "pack-relative"},
		{"path escape", func(m *Manifest) { m.Foreground = "../../evil.png" }, "escape"},
		{"duplicate sticker id", func(m *Manifest) { m.Stickers[1].ID = "mushroom" }, "duplicate sticker"},
		{"bad sticker id", func(m *Manifest) { m.Stickers[0].ID = "Mushroom" }, "must match"},
		{"duplicate story id", func(m *Manifest) { m.Stories[1].ID = "story-001" }, "duplicate story"},
		{"empty story text", func(m *Manifest) { m.Stories[0].Text = "" }, "text"},
		{"empty story title", func(m *Manifest) { m.Stories[0].Title = "" }, "title"},
		{"undeclared required sticker", func(m *Manifest) { m.Stories[0].RequiredStickers = []string{"dragon"} }, "undeclared"},
		{"undeclared optional sticker", func(m *Manifest) { m.Stories[0].OptionalStickers = []string{"dragon"} }, "undeclared"},
		{"required/optional overlap", func(m *Manifest) { m.Stories[0].OptionalStickers = []string{"mushroom"} }, "both"},
		{"non-positive weight", func(m *Manifest) { z := 0.0; m.Stories[0].Weight = &z }, "weight"},
		{"no fallback story", func(m *Manifest) { m.Stories[1].RequiredStickers = []string{"fox"} }, "fallback"},
		{"no stories", func(m *Manifest) { m.Stories = nil }, "at least one story"},
		{"no stickers", func(m *Manifest) {
			m.Stickers = nil
			// keep story refs from also failing the test's expectation
			m.Stories[0].RequiredStickers = nil
			m.Stories[0].OptionalStickers = nil
		}, "at least one sticker"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			m := validManifest(t, dir)
			tc.mutate(m)
			errs := m.Validate(dir)
			if len(errs) == 0 {
				t.Fatal("expected validation errors, got none")
			}
			for _, err := range errs {
				if strings.Contains(err.Error(), tc.wantSub) {
					return
				}
			}
			t.Fatalf("no error mentioning %q in %v", tc.wantSub, errs)
		})
	}
}
