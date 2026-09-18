package manifest

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func text(en, es string) map[string]string {
	return map[string]string{"en-US": en, "es-ES": es}
}

// validManifest returns a minimal manifest that passes every rule, with its
// referenced files materialised under dir.
func validManifest(t *testing.T, dir string) *Manifest {
	t.Helper()
	w := 2.0
	m := &Manifest{
		SchemaVersion: 2,
		ID:            "forest",
		Version:       1,
		Languages:     []string{"en-US", "es-ES"},
		DisplayName:   text("Forest Friends", "Amigos del Bosque"),
		Theme:         "forest",
		Background:    "art/background.png",
		Foreground:    "art/foreground.png",
		Stickers: []Sticker{
			{ID: "mushroom", Name: text("Mushroom", "Seta"), Image: "stickers/mushroom.png"},
			{ID: "fox", Name: text("Fox", "Zorro"), Image: "stickers/fox.png"},
		},
		Stories: []Story{
			{
				ID:               "story-001",
				RequiredStickers: []string{"mushroom"},
				OptionalStickers: []string{"fox"},
				Weight:           &w,
				Tags:             []string{"gentle"},
				Localizations: map[string]StoryLocalization{
					"en-US": {Title: "The Shy Mushroom", Text: "Once upon a time…", Audio: "audio/en-US/story-001.m4a"},
					"es-ES": {Title: "La seta tímida", Text: "Érase una vez…", Audio: "audio/es-ES/story-001.m4a"},
				},
			},
			{
				ID: "story-002",
				Localizations: map[string]StoryLocalization{
					"en-US": {Title: "A Forest Day", Text: "One sunny morning…", Audio: "audio/en-US/story-002.m4a"},
					"es-ES": {Title: "Un día en el bosque", Text: "Una mañana de sol…", Audio: "audio/es-ES/story-002.m4a"},
				},
			},
		},
	}
	assets := []string{
		m.Background, m.Foreground,
		"stickers/mushroom.png", "stickers/fox.png",
	}
	for _, st := range m.Stories {
		for _, loc := range st.Localizations {
			assets = append(assets, loc.Audio)
		}
	}
	for _, rel := range assets {
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
	if loaded.Stories[0].Localizations["es-ES"].Title != "La seta tímida" {
		t.Errorf("Spanish localization lost: %+v", loaded.Stories[0].Localizations)
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
		{"unsupported schema version", func(m *Manifest) { m.SchemaVersion = 1 }, "schemaVersion"},
		{"bad pack id", func(m *Manifest) { m.ID = "Forest Pack!" }, "pack id"},
		{"zero version", func(m *Manifest) { m.Version = 0 }, "version"},
		{"no languages", func(m *Manifest) { m.Languages = nil }, "languages must not be empty"},
		{"malformed language", func(m *Manifest) { m.Languages[0] = "english" }, "well-formed"},
		{"duplicate language", func(m *Manifest) { m.Languages = []string{"en-US", "en-US"} }, "duplicate language"},
		{"display name missing language", func(m *Manifest) { delete(m.DisplayName, "es-ES") }, "missing \"es-ES\""},
		{"display name empty value", func(m *Manifest) { m.DisplayName["es-ES"] = " " }, "must not be empty"},
		{"display name undeclared language", func(m *Manifest) { m.DisplayName["fr-FR"] = "Amis" }, "not in declared languages"},
		{"sticker name missing language", func(m *Manifest) { delete(m.Stickers[0].Name, "es-ES") }, "missing \"es-ES\""},
		{"missing background file", func(m *Manifest) { m.Background = "art/nope.png" }, "not found"},
		{"absolute path", func(m *Manifest) { m.Foreground = "/etc/passwd" }, "pack-relative"},
		{"path escape", func(m *Manifest) { m.Foreground = "../../evil.png" }, "escape"},
		{"duplicate sticker id", func(m *Manifest) { m.Stickers[1].ID = "mushroom" }, "duplicate sticker"},
		{"bad sticker id", func(m *Manifest) { m.Stickers[0].ID = "Mushroom" }, "must match"},
		{"duplicate story id", func(m *Manifest) { m.Stories[1].ID = "story-001" }, "duplicate story"},
		{"story missing localization", func(m *Manifest) { delete(m.Stories[0].Localizations, "es-ES") }, "missing \"es-ES\""},
		{"story undeclared localization", func(m *Manifest) {
			m.Stories[0].Localizations["fr-FR"] = StoryLocalization{Title: "T", Text: "T.", Audio: "audio/en-US/story-001.m4a"}
		}, "not in declared languages"},
		{"empty story text", func(m *Manifest) {
			loc := m.Stories[0].Localizations["en-US"]
			loc.Text = ""
			m.Stories[0].Localizations["en-US"] = loc
		}, "text"},
		{"empty story title", func(m *Manifest) {
			loc := m.Stories[0].Localizations["en-US"]
			loc.Title = ""
			m.Stories[0].Localizations["en-US"] = loc
		}, "title"},
		{"missing audio file", func(m *Manifest) {
			loc := m.Stories[0].Localizations["es-ES"]
			loc.Audio = "audio/es-ES/nope.m4a"
			m.Stories[0].Localizations["es-ES"] = loc
		}, "not found"},
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

func TestEffectsSidecarIsValidatedStrictly(t *testing.T) {
	dir := t.TempDir()
	m := validManifest(t, dir)
	loc := m.Stories[0].Localizations["en-US"]
	loc.Effects = "audio/en-US/story-001.effects.json"
	m.Stories[0].Localizations["en-US"] = loc
	sidecar := filepath.Join(dir, "audio", "en-US", "story-001.effects.json")

	// Missing file → rule 5.
	errs := m.Validate(dir)
	if len(errs) != 1 || !strings.Contains(errs[0].Error(), "effects") {
		t.Fatalf("expected one missing-file error, got %v", errs)
	}

	// Valid sidecar → passes.
	good := `{"schema": 1, "triggers": [{"at": 1.5, "sticker": "fox", "effect": "hop", "repeat": 2}]}`
	if err := os.WriteFile(sidecar, []byte(good), 0o644); err != nil {
		t.Fatal(err)
	}
	if errs := m.Validate(dir); len(errs) != 0 {
		t.Fatalf("expected no errors, got %v", errs)
	}

	// Undeclared sticker and unknown effect → strict errors attributed to the localization.
	bad := `{"schema": 1, "triggers": [{"at": 1.5, "sticker": "dragon", "effect": "explode"}]}`
	if err := os.WriteFile(sidecar, []byte(bad), 0o644); err != nil {
		t.Fatal(err)
	}
	errs = m.Validate(dir)
	if len(errs) != 2 {
		t.Fatalf("expected two sidecar errors, got %v", errs)
	}
	for _, e := range errs {
		if !strings.Contains(e.Error(), `stories[0] ("story-001") en-US effects:`) {
			t.Errorf("error not attributed to the localization: %v", e)
		}
	}
}
