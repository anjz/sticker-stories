package story

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testCatalog(t *testing.T) *Catalog {
	t.Helper()
	c, err := LoadCatalog(filepath.Join("..", "..", "..", "docs", "effects", "effects.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Effects) != 12 {
		t.Fatalf("catalogue has %d effects, want 12", len(c.Effects))
	}
	return c
}

var forest = Manifest{ID: "forest", Languages: []string{"en-US", "es-ES"}, Stickers: []string{"fox", "rabbit", "tree", "flower", "owl"}}

func words(n int, seed string) string {
	parts := make([]string, n)
	for i := range parts {
		parts[i] = seed
	}
	return strings.Join(parts, " ")
}

func goodStory() *Story {
	return &Story{
		Schema: 1, ID: "the-race", Pack: "forest",
		Featured: []string{"fox", "rabbit", "tree"}, Supporting: []string{"flower"},
		Tags: []string{"friendship", "funny"}, Premise: "A race that ties.", Inspiration: "Aesop, turned.", Lesson: "Finish together.",
		Languages: map[string]Localization{
			"en-US": {Title: "The Race", Text: "{flower:float loop 0.4} Ready, steady, {fox:hop} {rabbit:hop} go! " + words(90, "hop") + " {fox:hearts} friends."},
			"es-ES": {Title: "La carrera", Text: "{flower:float loop 0.4} Preparados, listos, {fox:hop} {rabbit:hop} ya! " + words(95, "salta") + " {fox:hearts} amigos."},
		},
	}
}

func TestParseCues(t *testing.T) {
	cues, plain, errs := ParseCues("{flower:float loop 0.4} Ready, {fox:hop x3} {rabbit:tint #ff0000 1.2s} go! The end {owl:fade-out hold}")
	if len(errs) != 0 {
		t.Fatalf("unexpected errors: %v", errs)
	}
	if plain != "Ready, go! The end" {
		t.Errorf("plain = %q", plain)
	}
	if len(cues) != 4 {
		t.Fatalf("got %d cues", len(cues))
	}
	float := cues[0]
	if float.Sticker != "flower" || float.Effect != "float" || !float.Loop || float.Intensity != 0.4 || float.WordIndex != 0 {
		t.Errorf("float cue parsed wrong: %+v", float)
	}
	if cues[1].Repeat != 3 || cues[1].WordIndex != 1 || cues[2].WordIndex != 1 {
		t.Errorf("go! cues should fire on word 1: %+v %+v", cues[1], cues[2])
	}
	if cues[2].Color != "#FF0000" || cues[2].Duration != 1.2 {
		t.Errorf("tint params: %+v", cues[2])
	}
	if !cues[3].Hold || cues[3].WordIndex != 3 {
		t.Errorf("trailing cue should fire on the last word (3): %+v", cues[3])
	}
	if WordCount("{fox:hop} one two {fox:pulse}") != 2 {
		t.Errorf("word count should exclude cues")
	}
}

func TestParseCueErrors(t *testing.T) {
	for _, bad := range []string{"{fox}", "{fox:hop x0}", "{fox:hop loop x2}", "{fox:tint #12}", "{fox:hop 2}", "{fox:hop 99s}", "{fox:hop"} {
		if _, _, errs := ParseCues(bad + " word"); len(errs) == 0 {
			t.Errorf("%q should not parse", bad)
		}
	}
}

func TestForbiddenWords(t *testing.T) {
	if got := ForbiddenWords("en-US", "The fox was not scared, just Shy. Nobody died."); strings.Join(got, ",") != "died" {
		t.Errorf("en: got %v", got)
	}
	if got := ForbiddenWords("es-ES", "El monstruo no existe; era un ciervo."); strings.Join(got, ",") != "monstruo" {
		t.Errorf("es: got %v", got)
	}
	if got := ForbiddenWords("en-US", "a deadline is not dead"); len(got) != 1 || got[0] != "dead" {
		t.Errorf("whole-word matching: got %v", got)
	}
}

func TestValidStoryPasses(t *testing.T) {
	is := Validate(goodStory(), forest, testCatalog(t))
	if len(is.Errors) != 0 || len(is.Warnings) != 0 {
		t.Fatalf("expected clean, got errors %v warnings %v", is.Errors, is.Warnings)
	}
}

func TestValidationFailures(t *testing.T) {
	cat := testCatalog(t)
	cases := []struct {
		name   string
		mutate func(s *Story)
		want   string
	}{
		{"bad schema", func(s *Story) { s.Schema = 2 }, "schema"},
		{"bad id", func(s *Story) { s.ID = "The Race" }, "id"},
		{"wrong pack", func(s *Story) { s.Pack = "meadow" }, "pack"},
		{"unknown sticker", func(s *Story) { s.Featured = []string{"dragon", "fox", "tree"} }, "not in the pack"},
		{"overlap", func(s *Story) { s.Supporting = []string{"fox"} }, "twice"},
		{"too many featured", func(s *Story) { s.Featured = []string{"fox", "rabbit", "tree", "flower", "owl"} }, "max 4"},
		{"no tags", func(s *Story) { s.Tags = nil }, "tags"},
		{"missing language", func(s *Story) { delete(s.Languages, "es-ES") }, "missing language"},
		{"extra language", func(s *Story) { s.Languages["fr-FR"] = s.Languages["en-US"] }, "not declared"},
		{"too short", func(s *Story) { l := s.Languages["en-US"]; l.Text = "{fox:hop} short story"; s.Languages["en-US"] = l }, "must be 65"},
		{"no cues", func(s *Story) { l := s.Languages["en-US"]; l.Text = words(100, "word"); s.Languages["en-US"] = l }, "no effect cues"},
		{"cue on absent sticker", func(s *Story) { l := s.Languages["en-US"]; l.Text += " {owl:hop}"; s.Languages["en-US"] = l }, "neither featured nor supporting"},
		{"unknown effect", func(s *Story) { l := s.Languages["en-US"]; l.Text += " {fox:explode}"; s.Languages["en-US"] = l }, "unknown effect"},
		{"tint without colour", func(s *Story) { l := s.Languages["en-US"]; l.Text += " {fox:tint}"; s.Languages["en-US"] = l }, "requires a colour"},
		{"hold on hop", func(s *Story) { l := s.Languages["en-US"]; l.Text += " {fox:hop hold}"; s.Languages["en-US"] = l }, "does not support hold"},
		{"repeat on fade", func(s *Story) { l := s.Languages["en-US"]; l.Text += " {fox:fade-out x2}"; s.Languages["en-US"] = l }, "ignores repeat"},
		{"forbidden word", func(s *Story) { l := s.Languages["en-US"]; l.Text += " It was scary."; s.Languages["en-US"] = l }, "forbidden"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := goodStory()
			tc.mutate(s)
			is := Validate(s, forest, cat)
			for _, e := range is.Errors {
				if strings.Contains(e, tc.want) {
					return
				}
			}
			t.Fatalf("no error contained %q; errors: %v", tc.want, is.Errors)
		})
	}
}

func TestCueMismatchAcrossLanguagesWarns(t *testing.T) {
	s := goodStory()
	l := s.Languages["es-ES"]
	l.Text += " {fox:sparkle}"
	s.Languages["es-ES"] = l
	is := Validate(s, forest, testCatalog(t))
	if len(is.Errors) != 0 {
		t.Fatalf("unexpected errors %v", is.Errors)
	}
	found := false
	for _, w := range is.Warnings {
		if strings.Contains(w, "cues differ") {
			found = true
		}
	}
	if !found {
		t.Errorf("expected a cue-mismatch warning, got %v", is.Warnings)
	}
}

func TestCoverage(t *testing.T) {
	a := goodStory()
	b := goodStory()
	b.ID = "the-other-race"
	c := goodStory()
	c.ID = "the-forest"
	c.Featured = nil
	cov := Cover([]*Story{a, b, c}, forest, 50)
	if cov.Fallbacks != 1 || cov.Featured["fox"] != 2 || cov.Used["flower"] != 3 {
		t.Errorf("counts wrong: %+v", cov)
	}
	joined := strings.Join(cov.Errors, "\n")
	if !strings.Contains(joined, `"owl" is never featured`) {
		t.Errorf("owl should be flagged as never featured: %v", cov.Errors)
	}
	warnings := strings.Join(cov.Warnings, "\n")
	for _, want := range []string{"same featured set", "fallback", "should have 50", "share the"} {
		if !strings.Contains(warnings, want) {
			t.Errorf("expected warning containing %q; got %v", want, cov.Warnings)
		}
	}
}

func TestLoadDir(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "the-race"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "the-race", "story.json"), []byte(`{"schema":1,"id":"the-race","pack":"forest","tags":["x"],"languages":{}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "empty-folder"), 0o755); err != nil {
		t.Fatal(err)
	}
	stories, errs := LoadDir(dir)
	if len(errs) != 0 || len(stories) != 1 || stories[0].ID != "the-race" || filepath.Base(stories[0].Dir) != "the-race" {
		t.Fatalf("stories %v errs %v", stories, errs)
	}
}
