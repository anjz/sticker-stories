package manifest

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestNarrationPackIDFollowsTheAudio(t *testing.T) {
	dir := t.TempDir()
	m := validManifest(t, dir)
	en, err := m.NarrationPackID(dir, "en-US")
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`^forest-narration-en-[0-9a-f]{8}$`).MatchString(en) {
		t.Fatalf("en-US narration pack %q", en)
	}
	es, _ := m.NarrationPackID(dir, "es-ES")
	if !strings.HasPrefix(es, "forest-narration-es-") || es == en {
		t.Fatalf("es-ES narration pack %q (en %q)", es, en)
	}
	// The same audio names the same pack; a new recording, a new one.
	if again, _ := m.NarrationPackID(dir, "en-US"); again != en {
		t.Fatalf("not stable: %q then %q", en, again)
	}
	if err := os.WriteFile(filepath.Join(dir, "audio/en-US/story-002.m4a"), []byte("re-recorded"), 0o644); err != nil {
		t.Fatal(err)
	}
	if changed, _ := m.NarrationPackID(dir, "en-US"); changed == en {
		t.Fatalf("a new recording kept the name %q", en)
	}
	if got := NarrationPath(en, "audio/en-US/story-001.m4a"); got != en+"/audio/en-US/story-001.m4a" {
		t.Fatalf("path inside the asset pack: %q", got)
	}
}

func TestNarrationLanguageIsThePrimarySubtagUnlessShared(t *testing.T) {
	m := &Manifest{Languages: []string{"en-US", "es-ES"}}
	if m.NarrationLanguage("en-US") != "en" || m.NarrationLanguage("es-ES") != "es" {
		t.Fatalf("got %q %q", m.NarrationLanguage("en-US"), m.NarrationLanguage("es-ES"))
	}
	m.Languages = append(m.Languages, "en-GB")
	if m.NarrationLanguage("en-US") != "en-US" || m.NarrationLanguage("en-GB") != "en-GB" || m.NarrationLanguage("es-ES") != "es" {
		t.Fatal("two Englishes must keep their regions")
	}
}

func TestNarrationPacksAreValidated(t *testing.T) {
	dir := t.TempDir()
	m := validManifest(t, dir)
	en, _ := m.NarrationPackID(dir, "en-US")
	es, _ := m.NarrationPackID(dir, "es-ES")
	m.NarrationPacks = map[string]string{"en-US": en, "es-ES": es}
	if errs := m.Validate(dir); len(errs) != 0 {
		t.Fatalf("current narration packs: %v", errs)
	}
	for _, tc := range []struct {
		name  string
		packs map[string]string
		want  string
	}{
		{"undeclared language", map[string]string{"fr-FR": en}, "not a declared language"},
		{"malformed id", map[string]string{"en-US": "Forest_EN"}, "lowercase"},
		{"shared by two languages", map[string]string{"en-US": en, "es-ES": en}, "also"},
		{"stale", map[string]string{"en-US": "forest-narration-en-00000000"}, "stale"},
	} {
		m.NarrationPacks = tc.packs
		errs := m.Validate(dir)
		joined := ""
		for _, e := range errs {
			joined += e.Error() + "\n"
		}
		if !strings.Contains(joined, tc.want) {
			t.Errorf("%s: want %q in %q", tc.name, tc.want, joined)
		}
	}
}
