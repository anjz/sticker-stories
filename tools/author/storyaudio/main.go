// Command storyaudio is step 2 of story authoring (tools/author/stories/
// README.md): it renders each authored story.json into narration audio with
// ElevenLabs, aligns the inline effect cues to the spoken words, mixes in
// the story's sound-effect hints and a calm background track, encodes AAC
// .m4a, and can install the results into a pack's manifest.
//
// Usage:
//
//	storyaudio render  -pack ../packs/forest [-only id,…] [-lang en-US] [-dry-run] [-force] [-retake]
//	                   [-voice en-US=<id>,es-ES=<id>] [-model eleven_v3] [-rate 44100]
//	                   [-no-sfx] [-no-music] [-music-prompt "…"] [-sfx-db -12] [-music-db -14]
//	                   [-lead 3] [-intro-db -6] [-parallel 10]
//	storyaudio voices  -pack ../packs/forest            # list candidate voices per language
//	storyaudio install -pack ../packs/forest [-prune] [-bump]
//
// The API key is read from ELEVENLABS_API_KEY, loaded from tools/.env or the
// repository's .env if present. Nothing here ships with the app.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"stickerstories/tools/internal/audio"
	"stickerstories/tools/internal/dotenv"
	"stickerstories/tools/internal/effects"
	"stickerstories/tools/internal/elevenlabs"
	"stickerstories/tools/internal/manifest"
	"stickerstories/tools/internal/render"
	"stickerstories/tools/internal/story"
)

const (
	toolVersion  = "2"
	defaultModel = "eleven_v3"
	fallbackTTS  = "eleven_multilingual_v2"
	tailOut      = 2.0 // seconds of music after the narrator ends
	introRamp    = 1.0 // seconds over which the intro settles to the bed level
	voiceRMSdB   = -20.0
	// soloBreath is the silence either side of a solo sound, so the
	// narrator seems to stop for it rather than be cut off.
	soloBreath   = 0.25
	musicSeconds = 60
)

// stabilityPresets are Eleven v3's three settings (docs: Creative is the
// most expressive and the most prone to say a tag aloud; Robust the most
// even and the least responsive to tags).
var stabilityPresets = map[string]float64{
	"creative": elevenlabs.StabilityCreative,
	"natural":  elevenlabs.StabilityNatural,
	"robust":   elevenlabs.StabilityRobust,
}

// musicConfig is <stories>/music.json: one Eleven Music prompt per mood tag
// plus a default. A story uses the first of its tags that has a prompt.
// The file is written with these defaults on first use so it can be edited.
type musicConfig struct {
	Default string            `json:"default"`
	Moods   map[string]string `json:"moods"`
}

const musicStyle = "instrumental, for a children's picture book read aloud, simple, no vocals, no drums, seamless loop"

var defaultMusicConfig = musicConfig{
	Default: "Gentle, calm, warm lullaby: soft piano and light strings, slow, " + musicStyle,
	Moods: map[string]string{
		"bedtime":   "Very slow, hushed lullaby: music box and soft piano, sleepy and tender, very quiet, " + musicStyle,
		"funny":     "Light, playful, bouncy tune: pizzicato strings, marimba and a cheeky clarinet, gentle and smiling, " + musicStyle,
		"adventure": "Curious, gently marching tune: light woodwinds, plucked strings and a soft glockenspiel, hopeful, " + musicStyle,
		"weather":   "Airy, flowing piece: harp, soft flute and pattering piano like light rain and breeze, calm, " + musicStyle,
		"music":     "Sweet folk melody: acoustic guitar, ukulele and a humming flute, warm and singable, " + musicStyle,
		"counting":  "Simple, steady, nursery-rhyme tune: xylophone and soft piano, cheerful and even, " + musicStyle,
		"curiosity": "Wondering, twinkling piece: celesta, soft harp and warm strings, bright and gentle, " + musicStyle,
		"kindness":  "Warm, tender melody: soft piano and cello, hopeful and kind, " + musicStyle,
		"seasons":   "Pastoral tune: acoustic guitar, flute and light strings, breezy and content, " + musicStyle,
		"gentle":    "Gentle, calm, warm lullaby: soft piano and light strings, slow, " + musicStyle,
	},
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	dotenv.LoadFirst(".env", filepath.Join("..", ".env"))
	var err error
	switch os.Args[1] {
	case "render":
		err = runRender(os.Args[2:])
	case "voices":
		err = runVoices(os.Args[2:])
	case "install":
		err = runInstall(os.Args[2:])
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "✗ %v\n", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: storyaudio render|voices|install -pack <pack-dir> [flags]  (see -h on each)")
	os.Exit(2)
}

// ---------- shared setup ----------

type ctxt struct {
	pack       *manifest.Manifest
	packDir    string
	storiesDir string
	stories    []*story.Story
	declared   map[string]bool
	// story is the pack as story tools see it (live animations included);
	// animations the live-animation IDs by sticker, for the sidecar check.
	story       story.Manifest
	animations  effects.Animations
	expressions effects.Expressions
}

func load(packDir, storiesDir string) (*ctxt, error) {
	if packDir == "" {
		return nil, errors.New("-pack is required")
	}
	m, err := manifest.Load(packDir)
	if err != nil {
		return nil, err
	}
	if storiesDir == "" {
		storiesDir = filepath.Join("author", "stories", m.ID)
	}
	stories, errs := story.LoadDir(storiesDir)
	if len(errs) > 0 {
		return nil, fmt.Errorf("loading stories: %v", errs)
	}
	c := &ctxt{pack: m, packDir: packDir, storiesDir: storiesDir, stories: stories, declared: map[string]bool{}}
	for _, s := range m.Stickers {
		c.declared[s.ID] = true
	}
	if c.story, err = story.PackManifest(m, packDir); err != nil {
		return nil, err
	}
	c.expressions = effects.Expressions(c.story.Expressions)
	c.animations = effects.Animations{}
	for id, anims := range c.story.Animations {
		for _, a := range anims {
			c.animations[id] = append(c.animations[id], effects.Animation{ID: a.ID, Pausable: a.Pause != ""})
		}
	}
	return c, nil
}

func client() (*elevenlabs.Client, error) {
	key := os.Getenv("ELEVENLABS_API_KEY")
	if key == "" {
		return nil, errors.New("ELEVENLABS_API_KEY is not set (put it in tools/.env)")
	}
	c := elevenlabs.New(key)
	if os.Getenv("STORYAUDIO_DEBUG") != "" {
		c.Log = func(s string) { fmt.Fprintln(os.Stderr, "  ·", s) }
	}
	return c, nil
}

func primary(lang string) string {
	l, _, _ := strings.Cut(lang, "-")
	return strings.ToLower(l)
}

// ---------- voices ----------

type voiceChoice struct {
	VoiceID string `json:"voiceId"`
	Name    string `json:"name"`
	Gender  string `json:"gender,omitempty"`
	Source  string `json:"source"` // "flag" | "library"
}

// voiceSet is <stories>/voices.json: the voices used per language. Stories
// are shared out across a language's voices in a fixed order (sorted ids,
// round robin) so the same story always has the same voice and the split is
// even; with two voices that is half male, half female.
type voiceSet map[string][]voiceChoice

func voicesPath(c *ctxt) string { return filepath.Join(c.storiesDir, "voices.json") }

func loadVoices(c *ctxt) voiceSet {
	out := voiceSet{}
	data, err := os.ReadFile(voicesPath(c))
	if err != nil {
		return out
	}
	if json.Unmarshal(data, &out) == nil {
		return out
	}
	// Older single-voice shape: {lang: {voiceId,…}}.
	var old map[string]voiceChoice
	if json.Unmarshal(data, &old) == nil {
		for lang, v := range old {
			out[lang] = []voiceChoice{v}
		}
	}
	return out
}

func saveVoices(c *ctxt, v voiceSet) error {
	data, _ := json.MarshalIndent(v, "", "  ")
	return os.WriteFile(voicesPath(c), append(data, '\n'), 0o644)
}

func candidates(ctx context.Context, el *elevenlabs.Client, lang string) ([]elevenlabs.SharedVoice, error) {
	q := elevenlabs.SharedVoicesQuery{Language: primary(lang), Locale: lang, UseCases: []string{"narrative_story"}, Sort: "usage_character_count_1y", PageSize: 30}
	vs, err := el.SharedVoices(ctx, q)
	if err != nil {
		return nil, err
	}
	if len(vs) == 0 { // locale may be too narrow; widen to the language
		q.Locale = ""
		if vs, err = el.SharedVoices(ctx, q); err != nil {
			return nil, err
		}
	}
	return vs, nil
}

// pickByGender returns the most-used voice of each gender, in the order
// male, female (falling back to the top voices when a gender is missing).
func pickByGender(vs []elevenlabs.SharedVoice) []elevenlabs.SharedVoice {
	var out []elevenlabs.SharedVoice
	for _, want := range []string{"male", "female"} {
		for _, v := range vs {
			if strings.EqualFold(v.Gender, want) {
				out = append(out, v)
				break
			}
		}
	}
	for _, v := range vs {
		if len(out) >= 2 {
			break
		}
		dup := false
		for _, o := range out {
			dup = dup || o.VoiceID == v.VoiceID
		}
		if !dup {
			out = append(out, v)
		}
	}
	return out
}

// resolveVoices returns the voices per pack language, honouring -voice
// (lang=id+id,… or bare ids), then voices.json, then the most-used male and
// female storytelling voices in the public library.
func resolveVoices(ctx context.Context, el *elevenlabs.Client, c *ctxt, flagValue string, dry bool) (voiceSet, error) {
	chosen := loadVoices(c)
	if flagValue != "" {
		parse := func(ids string) []voiceChoice {
			var out []voiceChoice
			for _, id := range strings.Split(ids, "+") {
				if id = strings.TrimSpace(id); id != "" {
					out = append(out, voiceChoice{VoiceID: id, Name: id, Source: "flag"})
				}
			}
			return out
		}
		for _, part := range strings.Split(flagValue, ",") {
			lang, ids, ok := strings.Cut(strings.TrimSpace(part), "=")
			if !ok { // bare ids apply to every language
				for _, l := range c.pack.Languages {
					chosen[l] = parse(lang)
				}
				continue
			}
			if !slices.Contains(c.pack.Languages, lang) {
				return nil, fmt.Errorf("-voice: %q is not one of the pack's languages (%s)", lang, strings.Join(c.pack.Languages, ", "))
			}
			chosen[lang] = parse(ids)
		}
	}
	for _, lang := range c.pack.Languages {
		// Pinned by flag: use as given. From the library: make sure both
		// genders are present (tops up a voices.json from an older run).
		pinned := false
		have := map[string]bool{}
		for _, v := range chosen[lang] {
			pinned = pinned || v.Source == "flag"
			have[strings.ToLower(v.Gender)] = true
		}
		if pinned || (have["male"] && have["female"]) {
			continue
		}
		if dry {
			for _, g := range []string{"male", "female"} {
				if !have[g] && len(chosen[lang]) < 2 {
					chosen[lang] = append(chosen[lang], voiceChoice{VoiceID: "(auto)", Name: "(library voice, " + g + " if the other is not)", Gender: g, Source: "library"})
				}
			}
			continue
		}
		vs, err := candidates(ctx, el, lang)
		if err != nil {
			return nil, fmt.Errorf("finding voices for %s: %w", lang, err)
		}
		if len(vs) == 0 {
			return nil, fmt.Errorf("no storytelling voice found for %s; pass -voice %s=<id>+<id>", lang, lang)
		}
		for _, pick := range pickByGender(vs) {
			if have[strings.ToLower(pick.Gender)] {
				continue
			}
			already := false
			for i := range chosen[lang] { // an older run may hold it without a gender
				if chosen[lang][i].VoiceID == pick.VoiceID {
					chosen[lang][i].Gender = pick.Gender
					have[strings.ToLower(pick.Gender)] = true
					already = true
				}
			}
			if already {
				continue
			}
			id, err := el.AddSharedVoice(ctx, pick.PublicOwnerID, pick.VoiceID, fmt.Sprintf("Sticker Stories %s – %s", lang, pick.Name))
			if err != nil {
				// Already in the library is the common failure; use the ID as is.
				if !elevenlabs.IsClientError(err) {
					return nil, fmt.Errorf("adding voice %s: %w", pick.Name, err)
				}
				id = pick.VoiceID
			}
			chosen[lang] = append(chosen[lang], voiceChoice{VoiceID: id, Name: pick.Name, Gender: pick.Gender, Source: "library"})
			fmt.Printf("voice %s: %s (%s, %s, %s) — %d chars used last year\n", lang, pick.Name, pick.Gender, pick.Age, pick.Accent, pick.UsageChars1Y)
		}
	}
	if !dry {
		if err := saveVoices(c, chosen); err != nil {
			return nil, err
		}
	}
	return chosen, nil
}

// voiceFor assigns a story one of a language's voices. A story rendered
// before keeps the voice its render record names (while that voice is
// still one of the language's), so adding or removing stories never moves
// a narrator; a new story gets the round robin over stories sorted by id,
// which is even and gives it the same gender in every language.
func (r *renderer) voiceFor(s *story.Story, lang string) voiceChoice {
	vs := r.voices[lang]
	if data, err := os.ReadFile(filepath.Join(s.Dir, "audio", lang+".render.json")); err == nil {
		var rec renderRecord
		if json.Unmarshal(data, &rec) == nil {
			for _, v := range vs {
				if v.VoiceID == rec.VoiceID {
					return v
				}
			}
		}
	}
	idx := 0
	for i, st := range r.c.stories { // LoadDir sorts by id
		if st.ID == s.ID {
			idx = i
			break
		}
	}
	return vs[idx%len(vs)]
}

func runVoices(args []string) error {
	fs := flag.NewFlagSet("voices", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	storiesDir := fs.String("stories", "", "stories directory (default author/stories/<packID>)")
	fs.Parse(args)
	c, err := load(*packDir, *storiesDir)
	if err != nil {
		return err
	}
	el, err := client()
	if err != nil {
		return err
	}
	ctx := context.Background()
	current := loadVoices(c)
	for _, lang := range c.pack.Languages {
		fmt.Printf("\n%s", lang)
		for _, v := range current[lang] {
			fmt.Printf("  [current: %s %s %s]", v.Name, v.Gender, v.VoiceID)
		}
		fmt.Println()
		vs, err := candidates(ctx, el, lang)
		if err != nil {
			return err
		}
		for i, v := range vs {
			if i >= 10 {
				break
			}
			fmt.Printf("  %-22s %s  %s/%s/%s  used %dM chars\n", v.Name, v.VoiceID, v.Gender, v.Age, v.Accent, v.UsageChars1Y/1_000_000)
		}
	}
	fmt.Println("\nPin with: storyaudio render -voice en-US=<id>+<id>,es-ES=<id>+<id> …  (one id per language, or several joined with + to share stories out)")
	return nil
}

// ---------- render ----------

type renderOpts struct {
	model, rate    string
	sampleRate     int
	noSFX, noMusic bool
	musicPrompt    string
	sfxDB, musicDB float64
	ambienceDB     float64
	lead, introDB  float64
	stability      string
	parallel       int
	force, dry     bool
	retake         bool
	only           map[string]bool
	lang           string
	bitrate        int
}

type renderRecord struct {
	Fingerprint string   `json:"fingerprint"`
	VoiceID     string   `json:"voiceId"`
	Voice       string   `json:"voice"`
	Model       string   `json:"model"`
	SampleRate  int      `json:"sampleRate"`
	Duration    float64  `json:"duration"`
	Sounds      []string `json:"sounds,omitempty"`
	Music       string   `json:"music,omitempty"`
	Missing     []string `json:"missingSoundCues,omitempty"`
	LiveOverlap []string `json:"liveOverlaps,omitempty"`
	RenderedAt  string   `json:"renderedAt"`
}

func runRender(args []string) error {
	fs := flag.NewFlagSet("render", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	storiesDir := fs.String("stories", "", "stories directory (default author/stories/<packID>)")
	only := fs.String("only", "", "comma-separated story ids to render")
	lang := fs.String("lang", "", "render only this language")
	voice := fs.String("voice", "", "lang=id pairs (en-US=…,es-ES=…), several ids per language joined with +; bare ids apply to every language; saved to voices.json")
	model := fs.String("model", defaultModel, "TTS model (falls back to "+fallbackTTS+" if timestamps are unavailable)")
	rate := fs.Int("rate", 44100, "PCM sample rate requested from ElevenLabs (44100 needs Pro+; falls back to 24000)")
	noSFX := fs.Bool("no-sfx", false, "skip sound-effect hints")
	noMusic := fs.Bool("no-music", false, "skip background music")
	musicPrompt := fs.String("music-prompt", "", "one Eleven Music prompt for every story, overriding <stories>/music.json")
	sfxDB := fs.Float64("sfx-db", -12, "sound effect level relative to narration, dB")
	ambienceDB := fs.Float64("ambience-db", -18, "looping ambience level under the narration, dB relative to the narrator")
	musicDB := fs.Float64("music-db", -14, "music level under the narration, dB relative to the narrator")
	stability := fs.String("stability", "natural", "v3 voice stability: creative | natural | robust (natural follows audio tags without saying them)")
	lead := fs.Float64("lead", 3, "seconds of music alone before the narrator starts")
	introDB := fs.Float64("intro-db", -6, "music level during the lead-in, dB relative to the narrator (ramps down to -music-db over the last second)")
	bitrate := fs.Int("bitrate", 64000, "AAC bitrate (64 kbps mono is transparent for narration)")
	parallel := fs.Int("parallel", 10, "renditions rendered concurrently")
	force := fs.Bool("force", false, "re-render (re-mix) even if nothing changed; cached narration is reused")
	retake := fs.Bool("retake", false, "synthesise the narration again even when a cached take exists — v3 varies between runs, so this is how you ask for another performance (implies -force)")
	dry := fs.Bool("dry-run", false, "print what would be rendered and the characters that would be synthesised (cached narration excluded); no API calls that cost")
	fs.Parse(args)

	c, err := load(*packDir, *storiesDir)
	if err != nil {
		return err
	}
	if _, ok := stabilityPresets[*stability]; !ok {
		return fmt.Errorf("-stability must be creative, natural or robust")
	}
	if *lang != "" && !slices.Contains(c.pack.Languages, *lang) {
		return fmt.Errorf("-lang %q is not one of the pack's languages (%s)", *lang, strings.Join(c.pack.Languages, ", "))
	}
	o := renderOpts{model: *model, sampleRate: *rate, noSFX: *noSFX, noMusic: *noMusic, musicPrompt: *musicPrompt,
		sfxDB: *sfxDB, ambienceDB: *ambienceDB, musicDB: *musicDB, lead: *lead, introDB: *introDB, stability: *stability,
		parallel: *parallel, force: *force || *retake, retake: *retake, dry: *dry, lang: *lang, bitrate: *bitrate}
	if *only != "" {
		o.only = map[string]bool{}
		for _, id := range strings.Split(*only, ",") {
			o.only[strings.TrimSpace(id)] = true
		}
	}
	var el *elevenlabs.Client
	if !o.dry {
		if el, err = client(); err != nil {
			return err
		}
	} else {
		el = elevenlabs.New(os.Getenv("ELEVENLABS_API_KEY"))
	}
	ctx := context.Background()
	voices, err := resolveVoices(ctx, el, c, *voice, o.dry)
	if err != nil {
		return err
	}
	r := &renderer{c: c, el: el, o: o, voices: voices, ctx: ctx}
	return r.run()
}

type renderer struct {
	c      *ctxt
	el     *elevenlabs.Client
	o      renderOpts
	voices voiceSet
	ctx    context.Context
	music  map[string]*audio.Clip // by prompt
	moods  musicConfig
	mu     sync.Mutex // guards music, o.sampleRate, stdout
	locks  sync.Map   // cache key → *sync.Mutex, so one worker generates each asset
	// dry-run tallies
	chars      map[string]int
	sfxToMake  map[string]bool
	musicToGen map[string]bool // by mood
}

func (r *renderer) cacheDir(kind string) string {
	d := filepath.Join(r.c.storiesDir, "_cache", kind)
	os.MkdirAll(d, 0o755)
	return d
}

func hashOf(parts ...string) string {
	h := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return hex.EncodeToString(h[:])[:16]
}

func (r *renderer) run() error {
	r.chars = map[string]int{}
	r.sfxToMake = map[string]bool{}
	r.musicToGen = map[string]bool{}
	r.music = map[string]*audio.Clip{}
	if !r.o.noMusic {
		var err error
		if r.moods, err = r.loadMusicConfig(); err != nil {
			return err
		}
	}
	type job struct {
		s    *story.Story
		lang string
	}
	var jobs []job
	for _, s := range r.c.stories {
		if r.o.only != nil && !r.o.only[s.ID] {
			continue
		}
		for _, lang := range r.c.pack.Languages {
			if r.o.lang != "" && r.o.lang != lang {
				continue
			}
			jobs = append(jobs, job{s, lang})
		}
	}
	workers := r.o.parallel
	if workers < 1 || r.o.dry {
		workers = 1
	}
	var (
		wg            sync.WaitGroup
		todo, skipped int
		failures      []string
		queue         = make(chan job)
	)
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range queue {
				var log strings.Builder
				started := time.Now()
				done, err := r.renderOne(j.s, j.lang, &log)
				r.mu.Lock()
				switch {
				case err != nil:
					failures = append(failures, fmt.Sprintf("%s (%s): %v", j.s.ID, j.lang, err))
					fmt.Printf("✗ %s (%s): %v\n", j.s.ID, j.lang, err)
				case done:
					todo++
					fmt.Printf("✓ %s (%s) %s in %.0fs\n", j.s.ID, j.lang, strings.TrimSpace(log.String()), time.Since(started).Seconds())
				default:
					skipped++
					if !r.o.dry {
						fmt.Printf("· %s (%s) up to date\n", j.s.ID, j.lang)
					}
				}
				if r.o.dry {
					fmt.Print(log.String())
				}
				r.mu.Unlock()
			}
		}()
	}
	for _, j := range jobs {
		queue <- j
	}
	close(queue)
	wg.Wait()
	if len(failures) > 0 {
		return fmt.Errorf("%d rendition(s) failed (rerun to retry just those):\n  %s", len(failures), strings.Join(failures, "\n  "))
	}
	if r.o.dry {
		total := 0
		fmt.Printf("\nDry run: %d renditions to render, %d up to date.\n", todo, skipped)
		for _, lang := range r.c.pack.Languages {
			fmt.Printf("  %s: %d characters of narration\n", lang, r.chars[lang])
			total += r.chars[lang]
		}
		fmt.Printf("  total %d characters; %d sound effects to generate; %d music tracks to compose (%s)\n", total, len(r.sfxToMake), len(r.musicToGen), strings.Join(keys(r.musicToGen), ", "))
		return nil
	}
	fmt.Printf("\nRendered %d, up to date %d. Next: storyaudio install -pack %s\n", todo, skipped, r.c.packDir)
	return nil
}

func (r *renderer) renderOne(s *story.Story, lang string, log *strings.Builder) (bool, error) {
	loc, ok := s.Languages[lang]
	if !ok {
		return false, fmt.Errorf("missing language")
	}
	nar, errs := story.Parse(loc.Text)
	if len(errs) > 0 {
		return false, fmt.Errorf("cues: %v", errs)
	}
	plain := nar.Plain()
	voice := r.voiceFor(s, lang)
	outDir := filepath.Join(s.Dir, "audio")
	m4a := filepath.Join(outDir, lang+".m4a")
	fxPath := filepath.Join(outDir, lang+".effects.json")
	recPath := filepath.Join(outDir, lang+".render.json")

	var notes []string
	if !r.o.noSFX {
		for _, h := range s.Sound {
			notes = append(notes, h.Cue+"|"+h.Note)
		}
		for _, id := range sortedKeys(s.Sounds) {
			sp := s.Sounds[id]
			notes = append(notes, fmt.Sprintf("%s|%s|%g|%v", id, sp.Prompt, sp.EffectiveSeconds(), sp.Loop))
		}
	}
	musicPrompt, mood := "", ""
	if !r.o.noMusic {
		musicPrompt, mood = r.musicPromptFor(s)
	}
	musicKey := hashOf(musicPrompt, fmt.Sprint(musicSeconds))
	fp := hashOf(toolVersion, plain, loc.Text, voice.VoiceID, r.o.model, r.o.stability, fmt.Sprint(r.o.sampleRate),
		strings.Join(notes, ";"), musicKey, fmt.Sprint(r.o.sfxDB, r.o.ambienceDB, r.o.musicDB, r.o.lead, r.o.introDB, r.o.bitrate))

	if !r.o.force {
		if data, err := os.ReadFile(recPath); err == nil {
			var rec renderRecord
			if json.Unmarshal(data, &rec) == nil && rec.Fingerprint == fp && exists(m4a) && exists(fxPath) {
				return false, nil
			}
		}
	}

	// The narration is read in segments: a solo sound cue pauses the
	// narrator, so the text before and after it are synthesised apart and
	// the sound sits in the gap.
	segments := nar.Segments()
	pieces := make([]piece, len(segments))
	for i, seg := range segments {
		pieces[i].text, pieces[i].starts = nar.Spoken(seg.From, seg.To)
	}

	if r.o.dry {
		for i, p := range pieces {
			if p.text == "" {
				continue
			}
			// The same key speak() uses: a take is shaped by its neighbours.
			if _, _, cached := r.loadSpeech(speechKey(pieces, i), lang, voice.VoiceID, r.o.sampleRate); !cached {
				r.chars[lang] += len([]rune(p.text))
			}
		}
		if !r.o.noSFX {
			for _, h := range s.Sound {
				if !exists(r.sfxCachePath(h.Note, 2, false, r.o.sampleRate)) {
					r.sfxToMake[h.Note] = true
				}
			}
			for id, sp := range s.Sounds {
				if !exists(r.sfxCachePath(sp.Prompt, sp.EffectiveSeconds(), sp.Loop, r.o.sampleRate)) {
					r.sfxToMake[id+": "+sp.Prompt] = true
				}
			}
		}
		if !r.o.noMusic && !exists(r.musicCachePath(musicPrompt, r.o.sampleRate)) {
			r.musicToGen[mood] = true
		}
		fmt.Fprintf(log, "would render %s (%s): %d chars in %d segment(s), %d cues, %d audio tags, %d sounds, voice %s, music %s\n",
			s.ID, lang, len([]rune(plain)), len(segments), len(nar.Cues), len(nar.Tags), len(s.Sound)+len(s.Sounds), voice.Name, mood)
		return true, nil
	}

	r.mu.Lock()
	fmt.Printf("▶ %s (%s, %s, music %s)\n", s.ID, lang, voice.Name, orNone(mood))
	r.mu.Unlock()

	// Synthesise each segment with its neighbours as context, place it on
	// the clock after any solo sound that precedes it, and assemble one
	// timeline for the cues.
	var voiceClip *audio.Clip
	var parts []*render.Timeline
	var model string
	rate := r.rate()
	soloAt := map[int]float64{} // cue index → when the solo sound starts
	offset := 0.0
	type placedPiece struct {
		clip *audio.Clip
		at   float64
	}
	var placed []placedPiece
	for i, seg := range segments {
		if seg.Solo >= 0 {
			spec := s.Sounds[nar.Cues[seg.Solo].Effect]
			offset += soloBreath
			soloAt[seg.Solo] = offset
			offset += spec.EffectiveSeconds() + soloBreath
		}
		if pieces[i].text == "" {
			continue
		}
		prev, next := neighbours(pieces, i)
		speech, usedModel, usedRate, err := r.speak(pieces[i].text, prev, next, lang, voice.VoiceID, log)
		if err != nil {
			return false, err
		}
		if model == "" {
			model = usedModel
		}
		rate = usedRate
		tl, err := render.NewTimeline(pieces[i].text, pieces[i].starts, speech.Alignment)
		if err != nil {
			return false, err
		}
		clip := audio.FromPCM16(speech.Audio, rate)
		clip.NormalizeRMS(voiceRMSdB, 0.9)
		placed = append(placed, placedPiece{clip, offset})
		parts = append(parts, tl.Shifted(offset))
		offset += clip.Duration()
	}
	voiceClip = audio.Silence(rate, offset)
	for _, p := range placed {
		voiceClip.MixAt(p.clip, p.at, 1)
	}
	tl := render.Assemble(parts...)

	// Triggers: shift by the lead-in, except cues on the first word, which
	// are pinned at 0 (scenery loops start with the story).
	triggers, err := render.Triggers(nar.Cues, tl, r.c.story)
	if err != nil {
		return false, err
	}
	for i := range triggers {
		if triggers[i].At > 0 {
			triggers[i].At = roundCs(triggers[i].At + r.leadIn())
		}
	}
	liveOverlaps := render.LiveOverlaps(triggers, r.c.story)
	features := map[string]bool{}
	for id := range r.c.pack.Features {
		features[id] = true
	}
	sidecar, err := render.EncodeSidecar(triggers, r.c.declared, r.c.animations, r.c.expressions, features, r.c.pack.EffectiveSetting())
	if err != nil {
		return false, err
	}

	mix := audio.Silence(rate, r.leadIn()+voiceClip.Duration()+tailOut)
	mix.MixAt(voiceClip, r.leadIn(), 1)

	rec := renderRecord{Fingerprint: fp, Music: mood, VoiceID: voice.VoiceID, Voice: voice.Name, Model: model, SampleRate: rate, LiveOverlap: liveOverlaps, RenderedAt: time.Now().Format(time.RFC3339)}

	if !r.o.noSFX {
		// Legacy hints: a sound on a spoken word.
		placedHints, missing := render.PlaceSounds(s.Sound, tl)
		rec.Missing = missing
		type sound struct {
			label   string
			prompt  string
			seconds float64
			loop    bool
			at      float64
			level   float64
		}
		var sounds []sound
		for _, p := range placedHints {
			sounds = append(sounds, sound{p.Hint.Cue, p.Hint.Note, 2, false, p.At + r.leadIn() - 0.05, r.o.sfxDB})
		}
		// Inline cues: under a word, solo in its gap, or looping from a word.
		for i, c := range nar.Cues {
			if !c.Sound {
				continue
			}
			spec := s.Sounds[c.Effect]
			at := tl.At(c.WordIndex) + r.leadIn() - 0.05
			label := c.Effect
			switch {
			case c.Solo:
				at = soloAt[i] + r.leadIn()
				label += " (solo)"
			case spec.Loop:
				label += " (loop)"
			}
			level := r.o.sfxDB
			if spec.Loop {
				level = r.o.ambienceDB
			}
			sounds = append(sounds, sound{label, spec.Prompt, spec.EffectiveSeconds(), spec.Loop, at, level})
		}
		if len(sounds) > story.MaxSounds {
			fmt.Fprintf(log, "[%d sounds; only the first %d are used] ", len(sounds), story.MaxSounds)
			sounds = sounds[:story.MaxSounds]
		}
		for _, sd := range sounds {
			clip, err := r.soundEffect(sd.prompt, sd.seconds, sd.loop, rate, sd.level)
			if err != nil {
				return false, fmt.Errorf("sound %q: %w", sd.label, err)
			}
			at := math.Max(sd.at, 0)
			if sd.loop {
				// An ambience bed: from its cue for its length, faded, and
				// kept under the narrator.
				bed := clip.LoopTo(math.Min(sd.seconds, mix.Duration()-at), 1.0)
				bed.Fade(1.0, 1.5)
				control := audio.Silence(rate, bed.Duration())
				control.MixAt(voiceClip, r.leadIn()-at, 1)
				bed.Duck(control, 0.02, 0.7, 0.05, 0.6)
				mix.MixAt(bed, at, 1)
			} else {
				mix.MixAt(clip, at, 1)
			}
			rec.Sounds = append(rec.Sounds, fmt.Sprintf("%.2fs %s", at, sd.label))
		}
	}
	if !r.o.noMusic {
		music, err := r.musicLoop(musicPrompt, mood, rate, log)
		if err != nil {
			return false, fmt.Errorf("music (%s): %w", mood, err)
		}
		bed := music.LoopTo(mix.Duration(), 1.0)
		bed.NormalizeRMS(voiceRMSdB+r.o.musicDB, 0.6).Fade(1.0, tailOut)
		// Intro: louder while the music plays alone, settling to the bed
		// level over the last second before the narrator starts.
		bed.Ramp(audio.DB(r.o.introDB-r.o.musicDB), 1, r.leadIn()-introRamp, r.leadIn())
		// Duck under the narrator: the control signal is the voice on its own timeline.
		control := audio.Silence(rate, mix.Duration())
		control.MixAt(voiceClip, r.leadIn(), 1)
		bed.Duck(control, 0.02, 0.6, 0.05, 0.6)
		mix.MixAt(bed, 0, 1)
	}
	mix.Limit(0.95)

	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return false, err
	}
	wav := filepath.Join(outDir, lang+".wav")
	if err := mix.WriteWAV(wav); err != nil {
		return false, err
	}
	if err := audio.EncodeM4A(wav, m4a, r.o.bitrate); err != nil {
		return false, err
	}
	os.Remove(wav)
	if err := writeAtomic(fxPath, sidecar); err != nil {
		return false, err
	}
	rec.Duration = roundCs(mix.Duration())
	data, _ := json.MarshalIndent(rec, "", "  ")
	if err := writeAtomic(recPath, append(data, '\n')); err != nil {
		return false, err
	}
	fmt.Fprintf(log, "%.1fs, %d triggers, %d sounds, %s", rec.Duration, len(triggers), len(rec.Sounds), model)
	if len(rec.Missing) > 0 {
		fmt.Fprintf(log, " [sound cue word not in text: %s]", strings.Join(rec.Missing, ", "))
	}
	if len(rec.LiveOverlap) > 0 {
		fmt.Fprintf(log, " [effect during a live animation: %s]", strings.Join(rec.LiveOverlap, "; "))
	}
	return true, nil
}

// leadIn is the music-only intro; without music the narrator starts almost at once.
func (r *renderer) leadIn() float64 {
	if r.o.noMusic {
		return 0.3
	}
	return r.o.lead
}

func (r *renderer) rate() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.o.sampleRate
}

func pcmFormat(rate int) string { return fmt.Sprintf("pcm_%d", rate) }

// piece is one stretch of narration read in one go (between solo sounds):
// the spoken text and the byte offset of each word in it.
type piece struct {
	text   string
	starts []int
}

// speechCacheKey is what a cached take is looked up by: the segment's text
// and the neighbouring text that shapes its delivery.
func speechCacheKey(text, previous, next string) string {
	return text + "\x00" + previous + "\x00" + next
}

// speechKey is speechCacheKey for pieces[i] of a narration.
func speechKey(pieces []piece, i int) string {
	prev, next := neighbours(pieces, i)
	return speechCacheKey(pieces[i].text, prev, next)
}

// neighbours returns the spoken text before and after pieces[i] ("" at the ends).
func neighbours(pieces []piece, i int) (prev, next string) {
	if i > 0 {
		prev = pieces[i-1].text
	}
	if i+1 < len(pieces) {
		next = pieces[i+1].text
	}
	return prev, next
}

// speak synthesises with timestamps, falling back to a lower sample rate
// (tier limit, remembered for the rest of the run) and to the v2 model (no
// alignment) when needed. Returns the audio, the model used and the rate.
func (r *renderer) speak(text, previous, next, lang, voiceID string, log *strings.Builder) (*elevenlabs.Speech, string, int, error) {
	rate := r.rate()
	// The synthesis is the expensive part; cache it so mix changes
	// (levels, music, bitrate) never cost another API call. The cache key
	// includes the neighbouring text, which shapes the delivery.
	key := speechCacheKey(text, previous, next)
	if !r.o.retake {
		if sp, model, ok := r.loadSpeech(key, lang, voiceID, rate); ok {
			return sp, model, rate, nil
		}
	}
	stability := stabilityPresets[r.o.stability]
	req := elevenlabs.SpeechRequest{
		VoiceID: voiceID, Text: text, ModelID: r.o.model, LanguageCode: primary(lang), OutputFormat: pcmFormat(rate),
		Settings: &elevenlabs.VoiceSettings{Stability: &stability}}
	if r.o.model != defaultModel {
		// v3 does not take previous_text / next_text yet ("not yet
		// supported with the 'eleven_v3' model"); v2 does.
		req.PreviousText, req.NextText = previous, next
	}
	sp, err := r.el.SpeechWithTimestamps(r.ctx, req)
	if err != nil && isRateRefusal(err) && rate == 44100 {
		fmt.Fprintf(log, "[44.1 kHz PCM refused: %s; using 24 kHz] ", shorten(err))
		r.mu.Lock()
		r.o.sampleRate = 24000
		r.mu.Unlock()
		rate = 24000
		req.OutputFormat = pcmFormat(rate)
		sp, err = r.el.SpeechWithTimestamps(r.ctx, req)
	}
	model := r.o.model
	if (err != nil && elevenlabs.IsClientError(err) || err == nil && sp.Alignment == nil) && r.o.model != fallbackTTS {
		reason := "no alignment"
		if err != nil {
			reason = shorten(err)
		}
		fmt.Fprintf(log, "[%s: %s; retried with %s] ", r.o.model, reason, fallbackTTS)
		req.ModelID = fallbackTTS
		model = fallbackTTS
		// v2 would read the audio tags aloud; it gets the words alone.
		req.Text = story.StripTags(text)
		req.PreviousText, req.NextText = story.StripTags(previous), story.StripTags(next)
		sp, err = r.el.SpeechWithTimestamps(r.ctx, req)
		if err == nil && sp.Alignment != nil && req.Text != text {
			// The alignment is for the stripped text; re-express it over
			// the tagged text so word offsets still line up.
			sp.Alignment = realign(text, req.Text, sp.Alignment)
		}
	}
	if err != nil {
		return nil, "", 0, err
	}
	if sp.Alignment == nil {
		return nil, "", 0, errors.New("no alignment returned")
	}
	r.saveSpeech(key, lang, voiceID, rate, model, sp)
	return sp, model, rate, nil
}

// isRateRefusal reports whether a client error is about the requested
// output format (44.1 kHz PCM needs a higher tier), as opposed to any
// other 400 — which must not silently downgrade the whole run.
func isRateRefusal(err error) bool {
	e, ok := err.(*elevenlabs.APIError)
	if !ok || e.Status < 400 || e.Status >= 500 {
		return false
	}
	body := strings.ToLower(e.Body)
	return strings.Contains(body, "output_format") || strings.Contains(body, "44100") || strings.Contains(body, "sample rate")
}

// realign maps an alignment made for stripped (the text without audio
// tags) onto tagged (the text as authored): tag characters get the timing
// of the character after them, so a word's onset is unchanged.
func realign(tagged, stripped string, al *elevenlabs.Alignment) *elevenlabs.Alignment {
	out := &elevenlabs.Alignment{}
	src := []rune(stripped)
	j := 0 // index into src / al
	for _, r := range tagged {
		if j < len(src) && j < len(al.Starts) && r == src[j] {
			out.Characters = append(out.Characters, string(r))
			out.Starts = append(out.Starts, al.Starts[j])
			out.Ends = append(out.Ends, al.Ends[j])
			j++
			continue
		}
		// A character the stripped text does not have (a tag, or its
		// surrounding space): zero-length at the next known time.
		t := 0.0
		if j < len(al.Starts) {
			t = al.Starts[j]
		} else if n := len(al.Ends); n > 0 {
			t = al.Ends[n-1]
		}
		out.Characters = append(out.Characters, string(r))
		out.Starts = append(out.Starts, t)
		out.Ends = append(out.Ends, t)
	}
	return out
}

type speechCache struct {
	Model     string                `json:"model"`
	Alignment *elevenlabs.Alignment `json:"alignment"`
}

// speechCachePath keys a take by everything that shapes it: the text and
// its neighbours, the voice, the model, the stability preset and the rate.
func (r *renderer) speechCachePath(plain, lang, voiceID string, rate int) string {
	return filepath.Join(r.cacheDir("tts"), hashOf(plain, lang, voiceID, r.o.model, r.o.stability, fmt.Sprint(rate)))
}

func (r *renderer) loadSpeech(plain, lang, voiceID string, rate int) (*elevenlabs.Speech, string, bool) {
	base := r.speechCachePath(plain, lang, voiceID, rate)
	meta, err := os.ReadFile(base + ".json")
	if err != nil {
		return nil, "", false
	}
	audio, err := os.ReadFile(base + ".pcm")
	if err != nil {
		return nil, "", false
	}
	var sc speechCache
	if json.Unmarshal(meta, &sc) != nil || sc.Alignment == nil {
		return nil, "", false
	}
	return &elevenlabs.Speech{Audio: audio, Alignment: sc.Alignment}, sc.Model, true
}

func (r *renderer) saveSpeech(plain, lang, voiceID string, rate int, model string, sp *elevenlabs.Speech) {
	base := r.speechCachePath(plain, lang, voiceID, rate)
	meta, _ := json.Marshal(speechCache{Model: model, Alignment: sp.Alignment})
	if writeAtomic(base+".pcm", sp.Audio) == nil {
		writeAtomic(base+".json", meta)
	}
}

// cached returns the cache file at path, generating it once even when
// several workers ask for the same asset at the same time.
func (r *renderer) cached(path string, generate func() ([]byte, error)) ([]byte, error) {
	m, _ := r.locks.LoadOrStore(path, &sync.Mutex{})
	mu := m.(*sync.Mutex)
	mu.Lock()
	defer mu.Unlock()
	if data, err := os.ReadFile(path); err == nil {
		return data, nil
	}
	data, err := generate()
	if err != nil {
		return nil, err
	}
	return data, writeAtomic(path, data)
}

func (r *renderer) sfxCachePath(prompt string, seconds float64, loop bool, rate int) string {
	// One-shots keep the key they always had, so sounds generated before
	// loops existed stay cached.
	parts := []string{prompt, fmt.Sprint(seconds), fmt.Sprint(rate)}
	if loop {
		parts = append(parts, "loop")
	}
	return filepath.Join(r.cacheDir("sfx"), hashOf(parts...)+".pcm")
}

// soundEffect generates (once, cached) a sound for a story: a one-shot
// trimmed and faded to sit under or between words, or a seamless
// ambience loop; normalised to levelDB under the narrator.
func (r *renderer) soundEffect(prompt string, seconds float64, loop bool, rate int, levelDB float64) (*audio.Clip, error) {
	data, err := r.cached(r.sfxCachePath(prompt, seconds, loop, rate), func() ([]byte, error) {
		style := " (single sound effect, gentle, for a children's story, no music, no voices)"
		if loop {
			style = " (seamless ambience loop, soft and even, for a children's story, no music, no voices)"
		}
		return r.el.SoundEffect(r.ctx, elevenlabs.SoundRequest{Prompt: prompt + style, Seconds: seconds, Influence: 0.4, Loop: loop, OutputFormat: pcmFormat(rate)})
	})
	if err != nil {
		return nil, err
	}
	clip := audio.FromPCM16(data, rate)
	if loop {
		clip.NormalizeRMS(voiceRMSdB+levelDB, 0.6)
	} else {
		// The model does not honour short lengths exactly (a 1 s request
		// came back as 2 s), and a solo sound's gap is sized from the
		// requested length, so one-shots are cut to it.
		clip.TrimSilence(0.01, 0.05).Cut(seconds, 0.3).Fade(0.02, 0.3).NormalizeRMS(voiceRMSdB+levelDB, 0.7)
	}
	return clip, nil
}

func sortedKeys(m map[string]story.SoundSpec) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func (r *renderer) musicConfigPath() string { return filepath.Join(r.c.storiesDir, "music.json") }

// loadMusicConfig reads music.json, writing the defaults first if absent.
func (r *renderer) loadMusicConfig() (musicConfig, error) {
	data, err := os.ReadFile(r.musicConfigPath())
	if os.IsNotExist(err) {
		data, _ = json.MarshalIndent(defaultMusicConfig, "", "  ")
		if !r.o.dry {
			if err := os.WriteFile(r.musicConfigPath(), append(data, '\n'), 0o644); err != nil {
				return musicConfig{}, err
			}
			fmt.Printf("wrote %s with default prompts per mood; edit to taste\n", r.musicConfigPath())
		}
		return defaultMusicConfig, nil
	}
	if err != nil {
		return musicConfig{}, err
	}
	var mc musicConfig
	if err := json.Unmarshal(data, &mc); err != nil {
		return musicConfig{}, fmt.Errorf("%s: %w", r.musicConfigPath(), err)
	}
	if mc.Default == "" {
		mc.Default = defaultMusicConfig.Default
	}
	return mc, nil
}

// musicPromptFor picks the prompt for a story: -music-prompt if given, else
// the first of the story's tags that music.json knows, else the default.
func (r *renderer) musicPromptFor(s *story.Story) (prompt, mood string) {
	if r.o.musicPrompt != "" {
		return r.o.musicPrompt, "custom"
	}
	for _, t := range s.Tags {
		if p, ok := r.moods.Moods[t]; ok && p != "" {
			return p, t
		}
	}
	return r.moods.Default, "default"
}

func (r *renderer) musicCachePath(prompt string, rate int) string {
	return filepath.Join(r.cacheDir("music"), hashOf(prompt, fmt.Sprint(musicSeconds), fmt.Sprint(rate))+".pcm")
}

func (r *renderer) musicLoop(prompt, mood string, rate int, log *strings.Builder) (*audio.Clip, error) {
	key := fmt.Sprintf("%s@%d", prompt, rate)
	r.mu.Lock()
	clip, ok := r.music[key]
	r.mu.Unlock()
	if ok {
		return clip, nil
	}
	data, err := r.cached(r.musicCachePath(prompt, rate), func() ([]byte, error) {
		fmt.Fprintf(log, "[composed %s music] ", mood)
		return r.el.Music(r.ctx, prompt, musicSeconds*1000, "", pcmFormat(rate))
	})
	if err != nil {
		return nil, err
	}
	clip = audio.FromPCM16(data, rate).TrimSilence(0.005, 0.1)
	r.mu.Lock()
	r.music[key] = clip
	r.mu.Unlock()
	return clip, nil
}

// ---------- install ----------

func runInstall(args []string) error {
	fs := flag.NewFlagSet("install", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	storiesDir := fs.String("stories", "", "stories directory (default author/stories/<packID>)")
	prune := fs.Bool("prune", false, "remove manifest stories that are not in the authored set")
	bump := fs.Bool("bump", false, "increment the pack's content version")
	fs.Parse(args)
	c, err := load(*packDir, *storiesDir)
	if err != nil {
		return err
	}
	authored := map[string]bool{}
	installed := 0
	for _, s := range c.stories {
		entry := manifest.Story{ID: s.ID, RequiredStickers: nonNil(s.Featured), OptionalStickers: nonNil(s.Supporting), Tags: nonNil(s.Tags), Localizations: map[string]manifest.StoryLocalization{}}
		w := 1.0
		entry.Weight = &w
		complete := true
		for _, lang := range c.pack.Languages {
			src := filepath.Join(s.Dir, "audio", lang+".m4a")
			fx := filepath.Join(s.Dir, "audio", lang+".effects.json")
			if !exists(src) || !exists(fx) {
				complete = false
				break
			}
			nar, _ := story.Parse(s.Languages[lang].Text)
			plain := nar.Plain()
			rel := filepath.ToSlash(filepath.Join("audio", lang, s.ID+".m4a"))
			relFx := filepath.ToSlash(filepath.Join("audio", lang, s.ID+".effects.json"))
			if err := copyFile(src, filepath.Join(c.packDir, rel)); err != nil {
				return err
			}
			if err := copyFile(fx, filepath.Join(c.packDir, relFx)); err != nil {
				return err
			}
			entry.Localizations[lang] = manifest.StoryLocalization{Title: s.Languages[lang].Title, Text: plain, Audio: rel, Effects: relFx}
		}
		if !complete {
			fmt.Printf("skip %s: not rendered in every language\n", s.ID)
			continue
		}
		authored[s.ID] = true
		replaced := false
		for i := range c.pack.Stories {
			if c.pack.Stories[i].ID == s.ID {
				c.pack.Stories[i] = entry
				replaced = true
			}
		}
		if !replaced {
			c.pack.Stories = append(c.pack.Stories, entry)
		}
		installed++
	}
	var pruned []manifest.Story
	if *prune {
		kept := c.pack.Stories[:0]
		for _, st := range c.pack.Stories {
			if authored[st.ID] {
				kept = append(kept, st)
			} else {
				fmt.Printf("prune %s\n", st.ID)
				pruned = append(pruned, st)
			}
		}
		c.pack.Stories = kept
	}
	sort.SliceStable(c.pack.Stories, func(i, j int) bool { return c.pack.Stories[i].ID < c.pack.Stories[j].ID })
	if *bump {
		c.pack.Version++
	}
	if errs := c.pack.Validate(c.packDir); len(errs) > 0 {
		for _, e := range errs {
			fmt.Printf("  ✗ %v\n", e)
		}
		return errors.New("manifest would not validate; manifest.json left unchanged (audio files were copied)")
	}
	data, err := json.MarshalIndent(c.pack, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(c.packDir, "manifest.json"), append(data, '\n'), 0o644); err != nil {
		return err
	}
	// The manifest no longer references the pruned stories, so their audio
	// and sidecars would only ship as dead weight in the bundle.
	for _, st := range pruned {
		for _, loc := range st.Localizations {
			for _, rel := range []string{loc.Audio, loc.Effects} {
				if rel == "" {
					continue
				}
				if err := os.Remove(filepath.Join(c.packDir, filepath.FromSlash(rel))); err != nil && !os.IsNotExist(err) {
					return fmt.Errorf("removing pruned %s: %w", rel, err)
				}
			}
		}
	}
	fmt.Printf("✓ installed %d stories into %s (manifest now has %d, version %d) and it validates\n", installed, c.packDir, len(c.pack.Stories), c.pack.Version)
	return nil
}

// ---------- helpers ----------

// writeAtomic writes via a temp file and rename so a cancelled run never
// leaves a truncated file that a later run would trust.
func writeAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o644)
}

func keys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func orNone(s string) string {
	if s == "" {
		return "none"
	}
	return s
}

func roundCs(v float64) float64 { return float64(int(v*100+0.5)) / 100 }

func shorten(err error) string {
	s := err.Error()
	if len(s) > 120 {
		s = s[:120] + "…"
	}
	return s
}
