// Command storyaudio is step 2 of story authoring (tools/author/stories/
// README.md): it renders each authored story.json into narration audio with
// ElevenLabs, aligns the inline effect cues to the spoken words, mixes in
// the story's sound-effect hints and a calm background track, encodes AAC
// .m4a, and can install the results into a pack's manifest.
//
// Usage:
//
//	storyaudio render  -pack ../packs/forest [-only id,…] [-lang en-US] [-dry-run] [-force] [-retake]
//	                   [-voice en-US=<id>,es-ES=<id>] [-model eleven_v4] [-stability 0.5] [-rate 44100]
//	                   [-no-sfx] [-no-music] [-music-prompt "…"] [-sfx-db -12] [-music-db -14]
//	                   [-lead 3] [-intro-db -6] [-parallel 10]
//	storyaudio voices  -pack ../packs/forest            # list candidate voices per language
//	storyaudio install -pack ../packs/forest [-prune] [-bump] [-model eleven_v4]
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
	"strconv"
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
	toolVersion  = "6" // 3: held lights (render.HoldLights); 4: they clear as the next builds; 5: snow holds; 6: one take per story
	defaultModel = "eleven_v4"
	// mp3Format is what is asked for when the plan refuses 44.1 kHz PCM
	// (Creator): decoded here, it keeps the full bandwidth that 24 kHz PCM
	// would lose, and 192 kbps is far above the 64 kbps AAC the app gets.
	mp3Format = "mp3_44100_192"
	// maxTakeChars is the model's limit for one request: a story is read
	// in one take, so its narration must fit.
	maxTakeChars = 10000
	tailOut      = 2.0 // seconds of music after the narrator ends
	introRamp    = 1.0 // seconds over which the intro settles to the bed level
	voiceRMSdB   = -20.0
	// soloBreath is the silence either side of a solo sound, so the
	// narrator seems to stop for it rather than be cut off.
	soloBreath   = 0.25
	musicSeconds = 60
)

// stabilityNames are v3's three settings, still accepted as names for
// their values: lower is more expressive and varies more between takes,
// higher keeps a steadier read (v4 takes any value from 0 to 1).
var stabilityNames = map[string]float64{
	"creative": 0,
	"natural":  0.5,
	"robust":   1,
}

// parseStability reads -stability: a name or a number from 0 to 1.
func parseStability(s string) (float64, error) {
	if v, ok := stabilityNames[s]; ok {
		return v, nil
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil || v < 0 || v > 1 {
		return 0, fmt.Errorf("-stability must be a number from 0 to 1 (or creative, natural, robust), not %q", s)
	}
	return v, nil
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
	// catalog is the effects catalogue (canvas ramps, for held lights).
	catalog *story.Catalog
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
	if c.catalog, err = story.LoadCatalog(filepath.Join("..", "docs", "effects", "effects.json")); err != nil {
		return nil, fmt.Errorf("effects catalogue (run from tools/): %w", err)
	}
	c.expressions = effects.Expressions(c.story.Expressions)
	c.animations = effects.Animations{}
	for id, anims := range c.story.Animations {
		for _, a := range anims {
			c.animations[id] = append(c.animations[id], effects.Animation{ID: a.ID, Pausable: a.Pause != ""})
		}
	}
	for id, moves := range c.story.Moves {
		for _, a := range moves {
			c.animations[id] = append(c.animations[id], effects.Animation{ID: a.ID, Move: true})
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
	stability      float64
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
	Stability   *float64 `json:"stability,omitempty"`
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
	model := fs.String("model", defaultModel, "TTS model; a rendition it cannot read fails (no fallback to another model)")
	rate := fs.Int("rate", 44100, "sample rate requested from ElevenLabs (44.1 kHz PCM needs Pro+; other plans get "+mp3Format+", decoded)")
	noSFX := fs.Bool("no-sfx", false, "skip sound-effect hints")
	noMusic := fs.Bool("no-music", false, "skip background music")
	musicPrompt := fs.String("music-prompt", "", "one Eleven Music prompt for every story, overriding <stories>/music.json")
	sfxDB := fs.Float64("sfx-db", -12, "sound effect level relative to narration, dB")
	ambienceDB := fs.Float64("ambience-db", -18, "looping ambience level under the narration, dB relative to the narrator")
	musicDB := fs.Float64("music-db", -14, "music level under the narration, dB relative to the narrator")
	stability := fs.String("stability", "0.5", "voice stability, 0–1: lower is more expressive and varies between takes, higher steadier (creative, natural, robust = 0, 0.5, 1)")
	lead := fs.Float64("lead", 3, "seconds of music alone before the narrator starts")
	introDB := fs.Float64("intro-db", -6, "music level during the lead-in, dB relative to the narrator (ramps down to -music-db over the last second)")
	bitrate := fs.Int("bitrate", 64000, "AAC bitrate (64 kbps mono is transparent for narration)")
	parallel := fs.Int("parallel", 10, "renditions rendered concurrently")
	force := fs.Bool("force", false, "re-render (re-mix) even if nothing changed; cached narration is reused")
	retake := fs.Bool("retake", false, "synthesise the narration again even when a cached take exists — every take is a new performance, so this is how you ask for another one (implies -force)")
	dry := fs.Bool("dry-run", false, "print what would be rendered and the characters that would be synthesised (cached narration excluded); no API calls that cost")
	fs.Parse(args)

	c, err := load(*packDir, *storiesDir)
	if err != nil {
		return err
	}
	stab, err := parseStability(*stability)
	if err != nil {
		return err
	}
	if *lang != "" && !slices.Contains(c.pack.Languages, *lang) {
		return fmt.Errorf("-lang %q is not one of the pack's languages (%s)", *lang, strings.Join(c.pack.Languages, ", "))
	}
	o := renderOpts{model: *model, sampleRate: *rate, noSFX: *noSFX, noMusic: *noMusic, musicPrompt: *musicPrompt,
		sfxDB: *sfxDB, ambienceDB: *ambienceDB, musicDB: *musicDB, lead: *lead, introDB: *introDB, stability: stab,
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
	mu     sync.Mutex // guards music, mp3, stdout
	// mp3 is set once the plan has refused 44.1 kHz PCM: from then on
	// every request asks for mp3Format and decodes it.
	mp3 bool
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
	fp := hashOf(toolVersion, plain, loc.Text, voice.VoiceID, r.o.model, stabilityKey(r.o.stability), fmt.Sprint(r.o.sampleRate),
		strings.Join(notes, ";"), musicKey, fmt.Sprint(r.o.sfxDB, r.o.ambienceDB, r.o.musicDB, r.o.lead, r.o.introDB, r.o.bitrate))

	if !r.o.force {
		if data, err := os.ReadFile(recPath); err == nil {
			var rec renderRecord
			if json.Unmarshal(data, &rec) == nil && rec.Fingerprint == fp && exists(m4a) && exists(fxPath) {
				return false, nil
			}
		}
	}

	// The narration is read in one take, so the voice carries from the
	// first word to the last; a solo sound cue then opens a gap in it at
	// its place (the segments are the stretches between solo sounds).
	segments := nar.Segments()
	pieces := make([]piece, len(segments))
	for i, seg := range segments {
		pieces[i].text, pieces[i].starts = nar.Spoken(seg.From, seg.To)
	}
	take := takeText(pieces)
	if n := len([]rune(take)); n > maxTakeChars {
		return false, fmt.Errorf("narration is %d characters; one take holds %d", n, maxTakeChars)
	}

	if r.o.dry {
		if _, cached := r.loadSpeech(take, lang, voice.VoiceID, r.o.sampleRate); !cached {
			r.chars[lang] += len([]rune(take))
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

	// Read the story in one take, cut it where the solo sounds go, place
	// each stretch on the clock after the sound before it, and assemble one
	// timeline for the cues.
	rate := r.o.sampleRate
	model := r.o.model
	speech, err := r.speak(take, lang, voice.VoiceID)
	if err != nil {
		return false, err
	}
	whole := audio.FromPCM16(speech.Audio, rate)
	whole.NormalizeRMS(voiceRMSdB, 0.9)
	stretches, err := splitTake(pieces, whole, speech.Alignment)
	if err != nil {
		return false, err
	}
	var parts []*render.Timeline
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
		tl, err := render.NewTimeline(pieces[i].text, pieces[i].starts, stretches[i].alignment)
		if err != nil {
			return false, err
		}
		placed = append(placed, placedPiece{stretches[i].clip, offset})
		parts = append(parts, tl.Shifted(offset))
		offset += stretches[i].clip.Duration()
	}
	voiceClip := audio.Silence(rate, offset)
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
	// Night, a sunset, a lamp turned low or snow holds until the story ends
	// it (the light changes, the sun comes out) or ends (the file ends after
	// the narrator and the tail).
	render.HoldLights(triggers, r.leadIn()+voiceClip.Duration()+tailOut, r.c.catalog)
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

	stab := r.o.stability
	rec := renderRecord{Fingerprint: fp, Music: mood, VoiceID: voice.VoiceID, Voice: voice.Name, Model: model, Stability: &stab, SampleRate: rate, LiveOverlap: liveOverlaps, RenderedAt: time.Now().Format(time.RFC3339)}

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

func pcmFormat(rate int) string { return fmt.Sprintf("pcm_%d", rate) }

// piece is one stretch of narration between solo sounds: the spoken text
// and the byte offset of each word in it.
type piece struct {
	text   string
	starts []int
}

// takeText is the whole narration as it is read in one take: the stretches
// between solo sounds, joined by a space.
func takeText(pieces []piece) string {
	var parts []string
	for _, p := range pieces {
		if p.text != "" {
			parts = append(parts, p.text)
		}
	}
	return strings.Join(parts, " ")
}

// stretch is one piece's audio cut out of the take, with its alignment
// re-timed from the cut.
type stretch struct {
	clip      *audio.Clip
	alignment *elevenlabs.Alignment
}

// splitTake cuts the one-take narration into the pieces takeText joined:
// each cut falls at the quietest moment between the last character of one
// piece and the first of the next (the narrator's pause where a solo sound
// goes), so no word is clipped. Empty pieces get no stretch.
func splitTake(pieces []piece, take *audio.Clip, al *elevenlabs.Alignment) ([]stretch, error) {
	if al == nil || len(al.Starts) != len(al.Characters) || len(al.Ends) != len(al.Characters) {
		return nil, errors.New("take came back without a usable alignment")
	}
	type span struct{ piece, from, to int } // rune range in the take text
	var spans []span
	at := 0
	for i, p := range pieces {
		if p.text == "" {
			continue
		}
		if len(spans) > 0 {
			at++ // the joining space
		}
		n := len([]rune(p.text))
		spans = append(spans, span{i, at, at + n})
		at += n
	}
	if at != len(al.Characters) {
		return nil, fmt.Errorf("alignment has %d characters for a %d-character take", len(al.Characters), at)
	}
	out := make([]stretch, len(pieces))
	cutFrom := 0.0
	for k, sp := range spans {
		cutTo := take.Duration()
		if k+1 < len(spans) {
			cutTo = quietest(take, al.Ends[sp.to-1], al.Starts[spans[k+1].from])
		}
		clip := take.Slice(cutFrom, cutTo).Fade(0.005, 0.005)
		sub := &elevenlabs.Alignment{Characters: al.Characters[sp.from:sp.to]}
		for j := sp.from; j < sp.to; j++ {
			sub.Starts = append(sub.Starts, math.Max(al.Starts[j]-cutFrom, 0))
			sub.Ends = append(sub.Ends, math.Max(al.Ends[j]-cutFrom, 0))
		}
		out[sp.piece] = stretch{clip, sub}
		cutFrom = cutTo
	}
	return out, nil
}

// quietest returns the middle of the quietest 10 ms of c between from and
// to (seconds); the middle of the range when it is shorter than that.
func quietest(c *audio.Clip, from, to float64) float64 {
	if to < from {
		from, to = to, from
	}
	win := c.Rate / 100
	a, b := int(from*float64(c.Rate)), int(to*float64(c.Rate))
	if b > len(c.Samples) {
		b = len(c.Samples)
	}
	if b-a <= win {
		return (from + to) / 2
	}
	best, bestAt := math.Inf(1), a
	for i := a; i+win <= b; i += win / 4 {
		e := 0.0
		for _, v := range c.Samples[i : i+win] {
			e += float64(v) * float64(v)
		}
		if e < best {
			best, bestAt = e, i
		}
	}
	return float64(bestAt+win/2) / float64(c.Rate)
}

// stabilityKey is the stability as it enters fingerprints and cache keys.
func stabilityKey(v float64) string { return strconv.FormatFloat(v, 'f', -1, 64) }

// speak reads a story's narration in one take with timestamps, from the
// cache when it has been read before. The model never changes behind the
// author's back: a refusal fails the rendition.
func (r *renderer) speak(text, lang, voiceID string) (*elevenlabs.Speech, error) {
	rate := r.o.sampleRate
	// The synthesis is the expensive part; cache it so mix changes
	// (levels, music, bitrate) never cost another API call.
	if !r.o.retake {
		if sp, ok := r.loadSpeech(text, lang, voiceID, rate); ok {
			return sp, nil
		}
	}
	stability := r.o.stability
	req := elevenlabs.SpeechRequest{
		VoiceID: voiceID, Text: text, ModelID: r.o.model, LanguageCode: primary(lang),
		Settings: &elevenlabs.VoiceSettings{Stability: &stability}}
	var sp *elevenlabs.Speech
	pcm, err := r.fetchPCM(rate, func(format string) ([]byte, error) {
		req.OutputFormat = format
		var err error
		sp, err = r.el.SpeechWithTimestamps(r.ctx, req)
		if err != nil {
			return nil, err
		}
		return sp.Audio, nil
	})
	if err != nil {
		return nil, err
	}
	if sp.Alignment == nil {
		return nil, errors.New("no alignment returned")
	}
	sp.Audio = pcm
	r.saveSpeech(text, lang, voiceID, rate, r.o.model, sp)
	return sp, nil
}

// fetchPCM makes a request for audio and returns 16-bit PCM at rate: raw
// PCM when the plan allows it, else (44.1 kHz on a plan below Pro) MP3 at
// 192 kbps, decoded — remembered for the rest of the run.
func (r *renderer) fetchPCM(rate int, call func(format string) ([]byte, error)) ([]byte, error) {
	r.mu.Lock()
	mp3 := r.mp3
	r.mu.Unlock()
	if !mp3 || rate != 44100 {
		data, err := call(pcmFormat(rate))
		if err == nil || rate != 44100 || !isRateRefusal(err) {
			return data, err
		}
		r.mu.Lock()
		if !r.mp3 {
			fmt.Printf("44.1 kHz PCM refused (%s): asking for %s and decoding it\n", shorten(err), mp3Format)
		}
		r.mp3 = true
		r.mu.Unlock()
	}
	data, err := call(mp3Format)
	if err != nil {
		return nil, err
	}
	return audio.DecodeToPCM16(data, "mp3", rate)
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

type speechCache struct {
	Model     string                `json:"model"`
	Alignment *elevenlabs.Alignment `json:"alignment"`
}

// speechCachePath keys a take by everything that shapes it: the text, the
// voice, the model, the stability and the rate. The audio is kept as PCM
// at the rate whatever format it came in.
func (r *renderer) speechCachePath(text, lang, voiceID string, rate int) string {
	return filepath.Join(r.cacheDir("tts"), hashOf(text, lang, voiceID, r.o.model, stabilityKey(r.o.stability), fmt.Sprint(rate)))
}

func (r *renderer) loadSpeech(text, lang, voiceID string, rate int) (*elevenlabs.Speech, bool) {
	base := r.speechCachePath(text, lang, voiceID, rate)
	meta, err := os.ReadFile(base + ".json")
	if err != nil {
		return nil, false
	}
	audio, err := os.ReadFile(base + ".pcm")
	if err != nil {
		return nil, false
	}
	var sc speechCache
	if json.Unmarshal(meta, &sc) != nil || sc.Alignment == nil || sc.Model != r.o.model {
		return nil, false
	}
	return &elevenlabs.Speech{Audio: audio, Alignment: sc.Alignment}, true
}

func (r *renderer) saveSpeech(text, lang, voiceID string, rate int, model string, sp *elevenlabs.Speech) {
	base := r.speechCachePath(text, lang, voiceID, rate)
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
		return r.fetchPCM(rate, func(format string) ([]byte, error) {
			return r.el.SoundEffect(r.ctx, elevenlabs.SoundRequest{Prompt: prompt + style, Seconds: seconds, Influence: 0.4, Loop: loop, OutputFormat: format})
		})
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
		return r.fetchPCM(rate, func(format string) ([]byte, error) {
			return r.el.Music(r.ctx, prompt, musicSeconds*1000, "", format)
		})
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
	model := fs.String("model", defaultModel, "the TTS model every installed rendition must have been read with")
	fs.Parse(args)
	c, err := load(*packDir, *storiesDir)
	if err != nil {
		return err
	}
	// A pack's narration is one recording: every rendition read by the same
	// model, so an old take never ships beside new ones by accident.
	var stale []string
	for _, s := range c.stories {
		for _, lang := range c.pack.Languages {
			data, err := os.ReadFile(filepath.Join(s.Dir, "audio", lang+".render.json"))
			if err != nil {
				continue // not rendered: skipped below
			}
			var rec renderRecord
			if json.Unmarshal(data, &rec) != nil || rec.Model != *model {
				stale = append(stale, fmt.Sprintf("%s (%s): %s", s.ID, lang, orNone(rec.Model)))
			}
		}
	}
	if len(stale) > 0 {
		return fmt.Errorf("%d rendition(s) were not read with %s; render them again (storyaudio render), or pass -model to install another model's recording:\n  %s",
			len(stale), *model, strings.Join(stale, "\n  "))
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
	// Each language's narration ships as its own asset pack, named for its
	// audio (docs/asset-delivery.md); a new recording gets a new name.
	c.pack.NarrationPacks = map[string]string{}
	for _, lang := range c.pack.Languages {
		id, err := c.pack.NarrationPackID(c.packDir, lang)
		if err != nil {
			return fmt.Errorf("naming the %s narration pack: %w", lang, err)
		}
		c.pack.NarrationPacks[lang] = id
	}
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
