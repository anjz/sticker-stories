package story

import (
	"fmt"
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
	if len(c.Canvas) != 27 {
		t.Fatalf("catalogue has %d canvas effects, want 27", len(c.Canvas))
	}
	return c
}

var forest = Manifest{ID: "forest", Languages: []string{"en-US", "es-ES"}, Stickers: []string{"fox", "rabbit", "tree", "flower", "owl"}, Setting: "outdoors"}

func words(n int, seed string) string {
	parts := make([]string, n)
	for i := range parts {
		parts[i] = seed
	}
	return strings.Join(parts, " ")
}

// beats is n filler words with a sticker reaction every ten, the cue
// density a real story has.
func beats(n int, seed string) string {
	parts := make([]string, 0, n+n/10)
	for i := 0; i < n; i++ {
		if i > 0 && i%10 == 0 {
			parts = append(parts, "{fox:wobble}")
		}
		parts = append(parts, seed)
	}
	return strings.Join(parts, " ")
}

func goodStory() *Story {
	return &Story{
		Schema: 1, ID: "the-race", Pack: "forest",
		Featured: []string{"fox", "rabbit", "tree"}, Supporting: []string{"flower"},
		Tags: []string{"friendship", "funny"}, Premise: "A race that ties.", Inspiration: "Aesop, turned.", Lesson: "Finish together.",
		Languages: map[string]Localization{
			"en-US": {Title: "The Race", Text: "{flower:enter} {flower:float loop 0.4} {tree:enter} Ready, steady, {fox:enter} {rabbit:enter} {fox:hop} {rabbit:hop} go! " + beats(90, "hop") + " {fox:hearts} friends."},
			"es-ES": {Title: "La carrera", Text: "{flower:enter} {flower:float loop 0.4} {tree:enter} Preparados, listos, {fox:enter} {rabbit:enter} {fox:hop} {rabbit:hop} ya! " + beats(90, "salta") + " {fox:hearts} amigos."},
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
	for _, bad := range []string{"{fox}", "{fox:hop x0}", "{fox:hop loop x2}", "{fox:tint #12}", "{fox:hop 2}", "{fox:hop 999s}", "{fox:hop", "{canvas}"} {
		if _, _, errs := ParseCues(bad + " word"); len(errs) == 0 {
			t.Errorf("%q should not parse", bad)
		}
	}
}

func TestParseCanvasCues(t *testing.T) {
	cues, plain, errs := ParseCues("Plip, plop. {canvas:rain 0.7 14s} Here comes the rain. {canvas:sunshine} The end.")
	if len(errs) != 0 {
		t.Fatal(errs)
	}
	if plain != "Plip, plop. Here comes the rain. The end." {
		t.Errorf("plain = %q", plain)
	}
	if len(cues) != 2 || !cues[0].Canvas || cues[0].Sticker != "" || cues[0].Effect != "rain" || cues[0].Intensity != 0.7 || cues[0].Duration != 14 || cues[0].WordIndex != 2 {
		t.Errorf("rain cue parsed wrong: %+v", cues)
	}
	if !cues[1].Canvas || cues[1].Effect != "sunshine" || cues[1].WordIndex != 6 {
		t.Errorf("sunshine cue parsed wrong: %+v", cues[1])
	}
}

func TestParseTagsSoundsAndSegments(t *testing.T) {
	text := "[softly] Night came. {sfx:owl solo} [whispers] Who is there? {fox:hop} It was Fox. [giggles] [pause] The end. [sighs]"
	nar, errs := Parse(text)
	if len(errs) != 0 {
		t.Fatal(errs)
	}
	if nar.Plain() != "Night came. Who is there? It was Fox. The end." {
		t.Errorf("plain = %q", nar.Plain())
	}
	if len(nar.Words) != 10 || WordCount(text) != 10 {
		t.Errorf("tags and cues must not count as words: %d", len(nar.Words))
	}
	names := []string{}
	for _, tg := range nar.Tags {
		names = append(names, fmt.Sprintf("%s@%d", tg.Name, tg.WordIndex))
	}
	if strings.Join(names, " ") != "softly@0 whispers@2 giggles@8 pause@8 sighs@10" {
		t.Errorf("tags placed wrong: %v", names)
	}
	if len(nar.Cues) != 2 || !nar.Cues[0].Sound || !nar.Cues[0].Solo || nar.Cues[0].Effect != "owl" || nar.Cues[0].WordIndex != 2 || nar.Cues[1].Sticker != "fox" {
		t.Errorf("cues parsed wrong: %+v", nar.Cues)
	}
	segs := nar.Segments()
	if len(segs) != 2 || segs[0] != (Segment{0, 2, -1}) || segs[1] != (Segment{2, 10, 0}) {
		t.Errorf("segments wrong: %+v", segs)
	}
	spoken, starts := nar.Spoken(2, 10)
	if spoken != "[whispers] Who is there? It was Fox. [giggles] [pause] The end. [sighs]" {
		t.Errorf("spoken = %q", spoken)
	}
	if len(starts) != 8 || spoken[starts[0]:starts[0]+3] != "Who" || spoken[starts[6]:starts[6]+3] != "The" {
		t.Errorf("word starts wrong: %v", starts)
	}
	first, _ := nar.Spoken(0, 2)
	if first != "[softly] Night came." {
		t.Errorf("first segment = %q", first)
	}
	if got := StripTags(spoken); got != "Who is there? It was Fox. … The end." {
		t.Errorf("StripTags = %q", got)
	}
	if _, errs := Parse("[shouts angrily] Hello [there"); len(errs) != 2 {
		t.Errorf("unknown tag and stray bracket should both error: %v", errs)
	}
	if _, _, errs := ParseCues("{fox:hop solo} word"); len(errs) == 0 {
		t.Errorf("solo on a sticker cue should not parse")
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
		{"cycle too long", func(s *Story) { l := s.Languages["en-US"]; l.Text += " {fox:hop 99s}"; s.Languages["en-US"] = l }, "cycle of 0.05–30 s"},
		{"forbidden word", func(s *Story) { l := s.Languages["en-US"]; l.Text += " It was scary."; s.Languages["en-US"] = l }, "forbidden"},
		{"canvas effect on a sticker", func(s *Story) { l := s.Languages["en-US"]; l.Text += " {fox:rain}"; s.Languages["en-US"] = l }, "is a canvas effect; write {canvas:rain"},
		{"sticker effect on the canvas", func(s *Story) { l := s.Languages["en-US"]; l.Text += " {canvas:hop}"; s.Languages["en-US"] = l }, "is a sticker effect"},
		{"unknown canvas effect", func(s *Story) { l := s.Languages["en-US"]; l.Text += " {canvas:blizzard}"; s.Languages["en-US"] = l }, "unknown canvas effect"},
		{"canvas effect for the wrong setting", func(s *Story) { l := s.Languages["en-US"]; l.Text += " {canvas:dimlight}"; s.Languages["en-US"] = l }, `suits indoors packs; this pack's setting is "outdoors"`},
		{"canvas cue with sticker params", func(s *Story) { l := s.Languages["en-US"]; l.Text += " {canvas:rain loop}"; s.Languages["en-US"] = l }, "only an intensity and a duration"},
		{"canvas cue too short", func(s *Story) { l := s.Languages["en-US"]; l.Text += " {canvas:rain 0.5s}"; s.Languages["en-US"] = l }, "stays on for 1–120 s"},
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

func TestSoundCuesAndTagsAreValidated(t *testing.T) {
	cat := testCatalog(t)
	s := goodStory()
	s.Sounds = map[string]SoundSpec{"rain": {Prompt: "gentle rain on leaves", Seconds: 2}, "birds": {Prompt: "dawn chorus", Seconds: 12, Loop: true}}
	for _, lang := range []string{"en-US", "es-ES"} {
		l := s.Languages[lang]
		l.Text = "{canvas:rain 0.5 12s} [softly] It rained all morning, and the whole forest listened to it, drip by drip by drip. {sfx:rain solo} {sfx:birds} " + l.Text
		s.Languages[lang] = l
	}
	if is := Validate(s, forest, cat); len(is.Errors) != 0 || len(is.Warnings) != 0 {
		t.Fatalf("expected clean, got errors %v warnings %v", is.Errors, is.Warnings)
	}
	cases := []struct {
		name   string
		mutate func(s *Story)
		want   string
		warn   bool
	}{
		{"unknown sound", func(s *Story) { l := s.Languages["en-US"]; l.Text += " {sfx:thunder}"; s.Languages["en-US"] = l }, `no sound "thunder"`, false},
		{"sound with params", func(s *Story) { l := s.Languages["en-US"]; l.Text += " {sfx:rain x2}"; s.Languages["en-US"] = l }, "takes only solo", false},
		{"solo loop", func(s *Story) { l := s.Languages["en-US"]; l.Text += " {sfx:birds solo}"; s.Languages["en-US"] = l }, "cannot play solo", false},
		{"bad seconds", func(s *Story) { s.Sounds["rain"] = SoundSpec{Prompt: "rain", Seconds: 40} }, "range is 0.5–30", false},
		{"no prompt", func(s *Story) { s.Sounds["rain"] = SoundSpec{} }, "needs a prompt", false},
		{"solo mid-sentence", func(s *Story) {
			l := s.Languages["en-US"]
			l.Text = "It rained {sfx:rain solo} hard. " + l.Text
			s.Languages["en-US"] = l
		}, "mid-sentence", true},
		{"solo leaves a short stretch", func(s *Story) {
			l := s.Languages["en-US"]
			l.Text = "It rained. {sfx:rain solo} " + l.Text
			s.Languages["en-US"] = l
		}, "stretch of only", true},
		{"too many tags", func(s *Story) {
			l := s.Languages["en-US"]
			l.Text = "[excited] [curious] [happily] [laughs] [gasps] [sighs] [whispers] " + l.Text
			s.Languages["en-US"] = l
		}, "audio tags", true},
		{"stacked tags", func(s *Story) {
			l := s.Languages["en-US"]
			l.Text = "[excited] [whispers] " + l.Text
			s.Languages["en-US"] = l
		}, "stacked", true},
		{"only sound cues", func(s *Story) {
			l := s.Languages["en-US"]
			l.Text = "It rained. {sfx:rain solo} " + words(90, "word")
			s.Languages["en-US"] = l
		}, "no sticker effect cues", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := goodStory()
			s.Sounds = map[string]SoundSpec{"rain": {Prompt: "gentle rain on leaves", Seconds: 2}, "birds": {Prompt: "dawn chorus", Seconds: 12, Loop: true}}
			tc.mutate(s)
			is := Validate(s, forest, cat)
			list := is.Errors
			if tc.warn {
				list = is.Warnings
			}
			for _, e := range list {
				if strings.Contains(e, tc.want) {
					return
				}
			}
			t.Fatalf("nothing contained %q; errors %v warnings %v", tc.want, is.Errors, is.Warnings)
		})
	}
}

func TestLearningShareIsReported(t *testing.T) {
	var set []*Story
	for i := 0; i < 10; i++ {
		s := goodStory()
		s.ID = fmt.Sprintf("story-%d", i)
		if i < 4 {
			s.Learning = "Bees carry pollen from flower to flower."
		}
		set = append(set, s)
	}
	cov := Cover(set, forest, 0)
	if cov.LearningStories != 4 {
		t.Errorf("learning count wrong: %d", cov.LearningStories)
	}
	if strings.Contains(strings.Join(cov.Warnings, "\n"), "piece of learning") {
		t.Errorf("40%% is within range: %v", cov.Warnings)
	}
	set[0].Learning = ""
	if strings.Contains(strings.Join(Cover(set, forest, 0).Warnings, "\n"), "piece of learning") {
		t.Errorf("30%% is still within range")
	}
	set[1].Learning = ""
	if !strings.Contains(strings.Join(Cover(set, forest, 0).Warnings, "\n"), "piece of learning") {
		t.Errorf("20%% should warn")
	}
}

func TestCanvasCuesFollowTheSetting(t *testing.T) {
	cat := testCatalog(t)
	s := goodStory()
	for _, lang := range []string{"en-US", "es-ES"} {
		l := s.Languages[lang]
		l.Text += " {canvas:rain 0.7 14s} {canvas:rainbow}"
		s.Languages[lang] = l
	}
	if is := Validate(s, forest, cat); len(is.Errors) != 0 || len(is.Warnings) != 0 {
		t.Fatalf("outdoors pack should accept rain and a rainbow: %v %v", is.Errors, is.Warnings)
	}
	none := forest
	none.Setting = ""
	is := Validate(s, none, cat)
	if len(is.Errors) != 4 || !strings.Contains(is.Errors[0], `this pack's setting is "none"`) {
		t.Errorf("a pack without a setting allows no canvas effects: %v", is.Errors)
	}
	// Too many, and only canvas cues, are warnings.
	l := s.Languages["en-US"]
	l.Text = "{canvas:fog} {canvas:rain} {canvas:sunshine} {canvas:night} " + words(90, "word")
	s.Languages["en-US"] = l
	warnings := strings.Join(Validate(s, forest, cat).Warnings, "\n")
	for _, want := range []string{"keep it to the 3 biggest", "only canvas cues"} {
		if !strings.Contains(warnings, want) {
			t.Errorf("expected a warning containing %q; got %v", want, warnings)
		}
	}
	named := forest
	named.Stickers = append(named.Stickers, "canvas")
	if is := Validate(goodStory(), named, cat); len(is.Errors) == 0 || !strings.Contains(is.Errors[0], "reserved") {
		t.Errorf("a sticker called canvas must be rejected: %v", is.Errors)
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
	l := c.Languages["en-US"]
	l.Text += " {canvas:rain}"
	c.Languages["en-US"] = l
	cov := Cover([]*Story{a, b, c}, forest, 50)
	if cov.Fallbacks != 1 || cov.Featured["fox"] != 2 || cov.Used["flower"] != 3 {
		t.Errorf("counts wrong: %+v", cov)
	}
	if cov.EffectUse["hop"] != 3 || cov.EffectUse["hearts"] != 3 || cov.EffectUse["canvas:rain"] != 1 || cov.CanvasStories != 1 {
		t.Errorf("effect usage wrong: %+v", cov.EffectUse)
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

// An ellipsis is one rune of three bytes; a solo sound after "ah…" is
// between sentences, not mid-sentence.
func TestSoloAfterEllipsisIsBetweenSentences(t *testing.T) {
	cat := testCatalog(t)
	s := goodStory()
	s.Sounds = map[string]SoundSpec{"sneeze": {Prompt: "a gentle comic sneeze", Seconds: 1.5}}
	for _, lang := range []string{"en-US", "es-ES"} {
		l := s.Languages[lang]
		l.Text = "His nose tickled, and it tickled, and everyone waited to see what would happen… ah… {sfx:sneeze solo} " + l.Text
		s.Languages[lang] = l
	}
	is := Validate(s, forest, cat)
	for _, w := range is.Warnings {
		if strings.Contains(w, "mid-sentence") {
			t.Fatalf("solo after an ellipsis flagged as mid-sentence: %v", is.Warnings)
		}
	}
}

func TestLiveCues(t *testing.T) {
	cat := testCatalog(t)
	pack := forest
	pack.Animations = map[string][]Animation{
		"owl": {{ID: "sleepy-blink", Description: "the owl blinks and yawns.", Seconds: 4.5}},
		"fox": {{ID: "wings", Seconds: 3}, {ID: "tap-tap", Seconds: 3}},
	}
	withText := func(en, es string) *Story {
		s := goodStory()
		s.Supporting = append(s.Supporting, "owl")
		l := s.Languages["en-US"]
		l.Text += en
		s.Languages["en-US"] = l
		l = s.Languages["es-ES"]
		l.Text += es
		s.Languages["es-ES"] = l
		return s
	}
	cues, _, errs := ParseCues("Owl {owl:live} blinked, fox {fox:live wings} flapped {fox:live tap-tap} tapped.")
	if len(errs) != 0 || cues[0].Effect != LiveEffect || cues[0].Animation != "" || cues[1].Animation != "wings" || cues[2].Animation != "tap-tap" {
		t.Fatalf("live cues parsed wrong: %+v %v", cues, errs)
	}
	if is := Validate(withText(" {owl:enter} {owl:live} blink.", " {owl:enter} {owl:live} parpadea."), pack, cat); len(is.Errors) != 0 || len(is.Warnings) != 0 {
		t.Fatalf("a live cue on an animated sticker is fine: %v %v", is.Errors, is.Warnings)
	}
	for _, tc := range []struct{ cue, want string }{
		{" {rabbit:live} hop.", "has no live animation"},
		{" {fox:live} hop.", "name one"},
		{" {fox:live dance} hop.", `no live animation "dance"`},
		{" {owl:live x2} hop.", "takes no parameters"},
		{" {owl:live 0.5} hop.", "takes no parameters"},
	} {
		is := Validate(withText(tc.cue, tc.cue), pack, cat)
		if !strings.Contains(strings.Join(is.Errors, "\n"), tc.want) {
			t.Errorf("%s: want an error containing %q, got %v", tc.cue, tc.want, is.Errors)
		}
	}
	twice := " {owl:enter} {owl:live} blink {owl:live} blink."
	if is := Validate(withText(twice, twice), pack, cat); len(is.Errors) != 0 || len(is.Warnings) != 0 {
		t.Errorf("the same animation twice is fine when the words say so: %v %v", is.Errors, is.Warnings)
	}
	// Hold and resume: only on an animation with a pause frame, in order.
	pack.Animations["owl"] = append(pack.Animations["owl"], Animation{ID: "nap", Seconds: 3, Pause: "asleep", ToPause: 1, FromPause: 1.5})
	cues, _, _ = ParseCues("{owl:live nap hold} x {owl:live nap resume} y")
	if !cues[0].Hold || cues[0].Resume || cues[0].Animation != "nap" || !cues[1].Resume {
		t.Fatalf("hold/resume parsed wrong: %+v", cues)
	}
	ok := " {owl:enter} {owl:live nap hold} naps, {owl:face normal} and {owl:live nap resume} wakes."
	if is := Validate(withText(ok, ok), pack, cat); len(is.Errors) != 0 || !strings.Contains(strings.Join(is.Warnings, "\n"), "held paused") {
		t.Errorf("hold, face, resume: want no errors and a held-face warning: %v %v", is.Errors, is.Warnings)
	}
	heldToTheEnd := " {owl:enter} {owl:live nap hold} naps."
	if is := Validate(withText(heldToTheEnd, heldToTheEnd), pack, cat); len(is.Errors) != 0 {
		t.Errorf("held until the story ends is fine: %v", is.Errors)
	}
	for _, tc := range []struct{ cue, want string }{
		{" {owl:live sleepy-blink hold} x.", "no pause frame"},
		{" {owl:live nap resume} x.", "nothing to resume"},
		{" {owl:live nap hold} x {owl:live nap hold} y.", "still held"},
		{" {owl:live nap hold} x {owl:live sleepy-blink} y.", "still held"},
		{" {owl:live nap hold resume} x.", "not both"},
	} {
		is := Validate(withText(tc.cue, tc.cue), pack, cat)
		if !strings.Contains(strings.Join(is.Errors, "\n"), tc.want) {
			t.Errorf("%s: want an error containing %q, got %v", tc.cue, tc.want, is.Errors)
		}
	}
	pack.Animations["owl"] = pack.Animations["owl"][:1]
	// Coverage: an animated, well-featured sticker nobody brings alive warns.
	set := []*Story{}
	for i := 0; i < MinFeaturedPer; i++ {
		s := goodStory()
		s.Featured = []string{"owl", "fox", "tree"}
		set = append(set, s)
	}
	if w := strings.Join(Cover(set, pack, 0).Warnings, "\n"); !strings.Contains(w, `"owl"'s action`) {
		t.Errorf("an unused live sticker should warn: %v", w)
	}
	set[0] = withText(" {owl:live} blink.", " {owl:live} parpadea.")
	if c := Cover(set, pack, 0); c.LiveUse["owl"] != 1 || c.LiveStories != 1 || c.EffectUse[LiveEffect] != 0 {
		t.Errorf("live use counted wrong: %+v %d", c.LiveUse, c.LiveStories)
	}
}

func TestWeatherWordsWantTheirCanvasEffect(t *testing.T) {
	cat := testCatalog(t)
	s := goodStory()
	for lang, extra := range map[string]string{"en-US": " Then the snow began to fall.", "es-ES": " Entonces empezó a caer la nieve."} {
		l := s.Languages[lang]
		l.Text += extra
		s.Languages[lang] = l
	}
	w := strings.Join(Validate(s, forest, cat).Warnings, "\n")
	if !strings.Contains(w, `en-US: the text mentions "snow"`) || !strings.Contains(w, `es-ES: the text mentions "nieve"`) {
		t.Fatalf("snow without {canvas:snow} should warn in both languages: %v", w)
	}
	for lang, cue := range map[string]string{"en-US": " {canvas:snow} Snow.", "es-ES": " {canvas:snow} Nieve."} {
		l := s.Languages[lang]
		l.Text += cue
		s.Languages[lang] = l
	}
	if w := strings.Join(Validate(s, forest, cat).Warnings, "\n"); strings.Contains(w, "mentions") {
		t.Errorf("a cued snow story should not warn: %v", w)
	}
	// A pack whose setting has no such effect is not asked for one.
	indoors := forest
	indoors.Setting = "indoors"
	plain := goodStory()
	l := plain.Languages["en-US"]
	l.Text += " Outside, the snow fell."
	plain.Languages["en-US"] = l
	if w := strings.Join(Validate(plain, indoors, cat).Warnings, "\n"); strings.Contains(w, "mentions") {
		t.Errorf("indoors packs have no snow effect: %v", w)
	}
}

func TestFaceAndAllCues(t *testing.T) {
	cat := testCatalog(t)
	pack := forest
	pack.Expressions = map[string][]string{"fox": {"happy", "sleeping"}, "rabbit": {"happy"}}
	withText := func(en, es string) *Story {
		s := goodStory()
		l := s.Languages["en-US"]
		l.Text += en
		s.Languages["en-US"] = l
		l = s.Languages["es-ES"]
		l.Text += es
		s.Languages["es-ES"] = l
		return s
	}
	ok := " {fox:face happy} Smile. {all:face sleeping} {all:hop} Sleep. {fox:face normal} Wake."
	if is := Validate(withText(ok, ok), pack, cat); len(is.Errors) != 0 || len(is.Warnings) != 0 {
		t.Fatalf("face and all cues are fine: %v %v", is.Errors, is.Warnings)
	}
	for _, tc := range []struct{ cue, want string }{
		{" {rabbit:face sleeping} x.", `has no expression "sleeping"`},
		{" {all:face angry} x.", `no sticker has the expression "angry"`},
		{" {fox:face} x.", "name the expression"},
		{" {fox:face happy 2s} x.", "takes no parameters"},
		{" {owl:face happy} x.", "neither featured nor supporting"},
		{" {all:live} x.", "one sticker at a time"},
	} {
		is := Validate(withText(tc.cue, tc.cue), pack, cat)
		if !strings.Contains(strings.Join(is.Errors, "\n"), tc.want) {
			t.Errorf("%s: want an error containing %q, got %v", tc.cue, tc.want, is.Errors)
		}
	}
	if w := strings.Join(Validate(goodStory(), pack, cat).Warnings, "\n"); !strings.Contains(w, "no face changes") {
		t.Errorf("a story without face cues should warn when the pack has faces: %v", w)
	}
	named := pack
	named.Stickers = append(named.Stickers, "all")
	if is := Validate(goodStory(), named, cat); !strings.Contains(strings.Join(is.Errors, "\n"), "reserved every-sticker") {
		t.Errorf("a sticker called all must be rejected: %v", is.Errors)
	}
	c := Cover([]*Story{withText(ok, ok)}, pack, 0)
	if c.FaceStories != 1 || c.AllStories != 1 || c.FaceUse["happy"] != 1 || c.FaceUse["normal"] != 1 {
		t.Errorf("face coverage wrong: %+v %d %d", c.FaceUse, c.FaceStories, c.AllStories)
	}
}

func TestEnterCues(t *testing.T) {
	cat := testCatalog(t)
	pack := forest
	pack.Names = map[string]map[string]string{
		"fox":    {"en-US": "Fox", "es-ES": "Zorro"},
		"rabbit": {"en-US": "Rabbit", "es-ES": "Conejo"},
		"owl":    {"en-US": "Owl", "es-ES": "Búho"},
	}
	withText := func(en string) *Story {
		s := goodStory()
		s.Supporting = append(s.Supporting, "owl")
		for _, lang := range []string{"en-US", "es-ES"} {
			l := s.Languages[lang]
			l.Text += en
			s.Languages[lang] = l
		}
		return s
	}
	if is := Validate(withText(" Then {owl:enter} Owl's eyes opened."), pack, cat); len(is.Errors) != 0 || len(is.Warnings) != 0 {
		t.Fatalf("an entrance on the first mention is fine: %v %v", is.Errors, is.Warnings)
	}
	for _, tc := range []struct{ text, want string }{
		{" Owl woke.", "owl never enters"},
		{" {owl:enter} Owl {owl:enter} woke.", "already enters earlier"},
		{" {all:enter} Owl woke.", "names one sticker"},
		{" {owl:enter 2s} Owl woke.", "takes no parameters"},
	} {
		is := Validate(withText(tc.text), pack, cat)
		if !strings.Contains(strings.Join(is.Errors, "\n"), tc.want) {
			t.Errorf("%s: want an error containing %q, got %v", tc.text, tc.want, is.Errors)
		}
	}
	for _, tc := range []struct{ text, want string }{
		{" Owl woke, {owl:enter} and so on.", "named earlier"},
		{" {owl:hop} Hop. {owl:enter} Owl woke.", "fires before owl enters"},
	} {
		is := Validate(withText(tc.text), pack, cat)
		if !strings.Contains(strings.Join(is.Warnings, "\n"), tc.want) {
			t.Errorf("%s: want a warning containing %q, got %v", tc.text, tc.want, is.Warnings)
		}
	}
	// A loop before the entrance carries on once the sticker is in.
	if is := Validate(withText(" {owl:float loop} Hush. {owl:enter} Owl woke."), pack, cat); len(is.Warnings) != 0 {
		t.Errorf("a loop before the entrance is fine: %v", is.Warnings)
	}
	// A shorter name inside a longer one is not a mention.
	woodpecker := pack
	woodpecker.Names = map[string]map[string]string{"owl": {"es-ES": "Pájaro"}, "tree": {"es-ES": "Pájaro carpintero"}}
	if i := firstMention([]string{"el", "pájaro", "carpintero", "y", "el", "Pájaro."}, "owl", "es-ES", woodpecker); i != 5 {
		t.Errorf("first mention of Pájaro = %d, want 5", i)
	}
	if i := firstMention([]string{"Owl's", "eyes"}, "owl", "en-US", pack); i != 0 {
		t.Errorf("a possessive is a mention, got %d", i)
	}
}

func TestGoCues(t *testing.T) {
	cat := testCatalog(t)
	pack := forest
	pack.Stages = map[string]string{"fox": "hop", "rabbit": "hop", "owl": "fly", "flower": "grow", "tree": "grow"}
	pack.Features = map[string]string{"pond": "the pond"}
	withText := func(en string) *Story {
		s := goodStory()
		for _, lang := range []string{"en-US", "es-ES"} {
			l := s.Languages[lang]
			l.Text += en
			s.Languages[lang] = l
		}
		return s
	}
	cues, _, errs := ParseCues("{fox:go to rabbit} a {fox:go on flower} b {fox:go under tree} c {fox:go to pond} d {fox:go away} e {fox:go back} f")
	if len(errs) != 0 || cues[0].GoKind != GoTo || cues[0].Target != "rabbit" || cues[1].GoKind != GoOn || cues[4].GoKind != GoAway || cues[4].Target != "" {
		t.Fatalf("go cues parsed wrong: %+v %v", cues, errs)
	}
	ok := " {fox:go to rabbit} Fox trotted over, {fox:go on flower} climbed up, {fox:go to pond} went to the pond, {fox:go away} ran off {fox:go back} and came back."
	if is := Validate(withText(ok), pack, cat); len(is.Errors) != 0 || len(is.Warnings) != 0 {
		t.Fatalf("moves after the entrances are fine: %v %v", is.Errors, is.Warnings)
	}
	for _, tc := range []struct{ text, want string }{
		{" {flower:go to fox} x.", "only walkers and flyers move"},
		{" {fox:go to owl} x.", "neither featured nor supporting"},
		{" {fox:go on fox} x.", "cannot go on itself"},
		{" {fox:go under} x.", "needs a target"},
		{" {fox:go away rabbit} x.", "takes no target"},
		{" {fox:go} x.", "say where it goes"},
		{" {all:go away} x.", "names one sticker"},
		{" {fox:go to rabbit 2s} x.", "only where it goes"},
		{" {fox:go on pond} x.", "neither featured nor supporting"},
	} {
		is := Validate(withText(tc.text), pack, cat)
		if !strings.Contains(strings.Join(is.Errors, "\n"), tc.want) {
			t.Errorf("%s: want an error containing %q, got %v", tc.text, tc.want, is.Errors)
		}
	}
	// A move before the mover or the target is on stage.
	early := goodStory()
	for _, lang := range []string{"en-US", "es-ES"} {
		l := early.Languages[lang]
		l.Text = "{fox:go to rabbit} " + l.Text
		early.Languages[lang] = l
	}
	if e := strings.Join(Validate(early, pack, cat).Errors, "\n"); !strings.Contains(e, "moves before it enters") || !strings.Contains(e, "not on stage yet") {
		t.Errorf("early move: %v", e)
	}
	gone := " {fox:go away} Off he ran. {fox:hop} Hop."
	if w := strings.Join(Validate(withText(gone), pack, cat).Warnings, "\n"); !strings.Contains(w, "has gone away") {
		t.Errorf("a cue on a sticker that went away should warn: %v", w)
	}

	// Another way to go: the fox trots, and it can swim.
	cues, _, errs = ParseCues("{fox:go to pond by swim} a {fox:go back by swim} b {fox:enter by swim} c")
	if len(errs) != 0 || cues[0].Target != "pond" || cues[0].By != "swim" || cues[1].GoKind != GoBack || cues[1].Target != "" || cues[1].By != "swim" || cues[2].By != "swim" {
		t.Fatalf("by parsed wrong: %+v %v", cues, errs)
	}
	if _, _, errs := ParseCues("{fox:go away by} a"); len(errs) == 0 {
		t.Error("by without a move was accepted")
	}
	pack.Moves = map[string][]Animation{"fox": {{ID: "trot"}, {ID: "swim"}}}
	if is := Validate(withText(" {fox:go to pond by swim} Fox swam off {fox:go back} and trotted back."), pack, cat); len(is.Errors) != 0 || len(is.Warnings) != 0 {
		t.Errorf("a move by another way is fine: %v %v", is.Errors, is.Warnings)
	}
	if e := strings.Join(Validate(withText(" {fox:go to pond by fly} x."), pack, cat).Errors, "\n"); !strings.Contains(e, `no move "fly" (its moves: trot, swim)`) {
		t.Errorf("an unknown way: %v", e)
	}
	if w := strings.Join(Validate(withText(" {fox:go to pond by trot} x."), pack, cat).Warnings, "\n"); !strings.Contains(w, "usual way") {
		t.Errorf("naming the usual way should warn: %v", w)
	}
}
