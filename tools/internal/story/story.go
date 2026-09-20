// Package story defines the intermediate story format authored by the
// author-stories skill (tools/author/stories/FORMAT.md) and validates it:
// structure, inline effect cues (sticker and canvas) against the effects
// catalogue and the pack's setting, word budgets, forbidden words, and
// sticker coverage across a pack's set of stories.
package story

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

// SupportedSchema is the only story.json schema this package accepts.
const SupportedSchema = 1

// Word budgets per language (words excluding cues). Narration at a gentle
// pace runs ~130–150 words a minute; 30–60 s ⇒ roughly 65–160 words with
// a target band inside that.
const (
	MinWords       = 65
	MaxWords       = 160
	TargetMinWords = 80
	TargetMaxWords = 140
	MaxTitleWords  = 6
	MaxFeatured    = 4
	MaxSupporting  = 4
	MaxTags        = 5
	MinFeaturedPer = 5 // each sticker should be featured at least this often (warning)
	MinFallbacks   = 3
	DefaultCount   = 50
	MaxCanvasCues  = 2 // canvas effects per story and language before a warning
	// Share of a pack's stories that may use canvas effects before a warning:
	// they are occasional weather, not the default.
	MaxCanvasShare = 0.4
)

// Story is one authored story with every language.
type Story struct {
	Schema      int                     `json:"schema"`
	ID          string                  `json:"id"`
	Pack        string                  `json:"pack"`
	Featured    []string                `json:"featured"`
	Supporting  []string                `json:"supporting"`
	Tags        []string                `json:"tags"`
	Premise     string                  `json:"premise"`
	Inspiration string                  `json:"inspiration"`
	Lesson      string                  `json:"lesson"`
	Languages   map[string]Localization `json:"languages"`
	Sound       []SoundHint             `json:"sound,omitempty"`

	// Dir is where the story was loaded from (not part of the JSON).
	Dir string `json:"-"`
}

// Localization is one language's title and cued text.
type Localization struct {
	Title string `json:"title"`
	Text  string `json:"text"`
}

// SoundHint is an optional suggestion for step 2 (audio).
type SoundHint struct {
	Cue  string `json:"cue"`
	Note string `json:"note"`
}

// CanvasTarget is the reserved cue target for canvas effects:
// {canvas:rain 0.7 12s}. A pack must not name a sticker "canvas".
const CanvasTarget = "canvas"

// Cue is one parsed inline effect cue. A canvas cue (Canvas true) has no
// sticker and takes only an intensity and a duration.
type Cue struct {
	Sticker   string // "" for a canvas cue
	Canvas    bool
	Effect    string
	Repeat    int // 0 = default (1)
	Loop      bool
	Hold      bool
	Color     string  // "#RRGGBB" or ""
	Duration  float64 // seconds, 0 = default
	Intensity float64 // 0 = default; -1 = explicitly zero
	WordIndex int     // index of the word the cue fires on (0-based; last word if trailing)
	Raw       string
}

// Effect is one entry of docs/effects/effects.json, the parts validation needs.
type Effect struct {
	Name          string    `json:"name"`
	Category      string    `json:"category"`
	Parameters    []string  `json:"parameters"`
	OneWay        bool      `json:"oneWay"`
	Hold          bool      `json:"hold"`
	RequiresColor bool      `json:"requiresColor"`
	DurationRange []float64 `json:"durationRange"`
}

// CanvasEffect is one entry of the catalogue's canvasEffects list.
type CanvasEffect struct {
	Name          string    `json:"name"`
	Settings      []string  `json:"settings"`
	Parameters    []string  `json:"parameters"`
	DurationRange []float64 `json:"durationRange"`
}

// Catalog is the effects library as tooling sees it: sticker effects and
// canvas effects, both closed lists.
type Catalog struct {
	Effects map[string]Effect
	Canvas  map[string]CanvasEffect
}

// LoadCatalog reads docs/effects/effects.json.
func LoadCatalog(path string) (*Catalog, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading effects catalogue: %w", err)
	}
	var file struct {
		Effects       []Effect       `json:"effects"`
		CanvasEffects []CanvasEffect `json:"canvasEffects"`
	}
	if err := json.Unmarshal(data, &file); err != nil {
		return nil, fmt.Errorf("decoding effects catalogue: %w", err)
	}
	c := &Catalog{Effects: make(map[string]Effect, len(file.Effects)), Canvas: make(map[string]CanvasEffect, len(file.CanvasEffects))}
	for _, e := range file.Effects {
		c.Effects[e.Name] = e
	}
	for _, e := range file.CanvasEffects {
		c.Canvas[e.Name] = e
	}
	if len(c.Effects) == 0 {
		return nil, fmt.Errorf("effects catalogue %s lists no effects", path)
	}
	return c, nil
}

// SuitsSetting reports whether the canvas effect may be used in a pack
// with the given setting.
func (e CanvasEffect) SuitsSetting(setting string) bool {
	for _, s := range e.Settings {
		if s == setting {
			return true
		}
	}
	return false
}

func (e Effect) accepts(param string) bool {
	for _, p := range e.Parameters {
		if p == param {
			return true
		}
	}
	return false
}

func inRange(v float64, r []float64) bool {
	return len(r) != 2 || (v >= r[0] && v <= r[1])
}

// Load reads one story.json.
func Load(path string) (*Story, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var s Story
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	s.Dir = filepath.Dir(path)
	return &s, nil
}

// LoadDir loads every <dir>/<id>/story.json, sorted by id. Folders without a
// story.json are skipped; unreadable stories are returned as errors.
func LoadDir(dir string) ([]*Story, []error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, []error{fmt.Errorf("reading stories directory: %w", err)}
	}
	var stories []*Story
	var errs []error
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		path := filepath.Join(dir, e.Name(), "story.json")
		if _, statErr := os.Stat(path); statErr != nil {
			continue
		}
		s, loadErr := Load(path)
		if loadErr != nil {
			errs = append(errs, loadErr)
			continue
		}
		stories = append(stories, s)
	}
	sort.Slice(stories, func(i, j int) bool { return stories[i].ID < stories[j].ID })
	return stories, errs
}

var (
	idPattern    = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)
	cuePattern   = regexp.MustCompile(`\{([^{}]*)\}`)
	colorPattern = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)
)

// ParseCues extracts the cues from a text and returns the plain narration
// (cues removed, whitespace normalised). Syntax problems are returned as
// errors; the cue is still dropped from the plain text. A cue fires on the
// word that follows it; trailing cues fire on the last word. Parsing is
// syntactic only — which parameters an effect accepts, and whether a canvas
// effect suits the pack, is Validate's job.
func ParseCues(text string) (cues []Cue, plain string, errs []error) {
	var parsed []Cue
	// Cues contain spaces ({butterfly:float loop 0.4}), so lift them out before
	// tokenising, leaving a marker where each one stood.
	marked := cuePattern.ReplaceAllStringFunc(text, func(m string) string {
		inner := strings.TrimSuffix(strings.TrimPrefix(m, "{"), "}")
		cue, err := parseCue(inner)
		if err != nil {
			errs = append(errs, fmt.Errorf("cue %q: %w", m, err))
			return " "
		}
		cue.Raw = m
		parsed = append(parsed, cue)
		return fmt.Sprintf(" \x00%d\x00 ", len(parsed)-1)
	})
	if strings.ContainsAny(marked, "{}") {
		errs = append(errs, fmt.Errorf("unbalanced braces in %q", text))
		marked = strings.NewReplacer("{", "", "}", "").Replace(marked)
	}
	var words []string
	var pending []int
	for _, tok := range strings.Fields(marked) {
		if strings.HasPrefix(tok, "\x00") && strings.HasSuffix(tok, "\x00") {
			idx, err := strconv.Atoi(strings.Trim(tok, "\x00"))
			if err == nil {
				pending = append(pending, idx)
			}
			continue
		}
		words = append(words, tok)
		for _, idx := range pending {
			parsed[idx].WordIndex = len(words) - 1
			cues = append(cues, parsed[idx])
		}
		pending = nil
	}
	last := len(words) - 1
	if last < 0 {
		last = 0
	}
	for _, idx := range pending {
		parsed[idx].WordIndex = last
		cues = append(cues, parsed[idx])
	}
	return cues, strings.Join(words, " "), errs
}

func parseCue(inner string) (Cue, error) {
	var c Cue
	head, params, _ := strings.Cut(strings.TrimSpace(inner), " ")
	sticker, effect, ok := strings.Cut(head, ":")
	if !ok || sticker == "" || effect == "" {
		return c, fmt.Errorf("want {sticker:effect …} or {canvas:effect …}")
	}
	c.Effect = effect
	if sticker == CanvasTarget {
		c.Canvas = true
	} else {
		c.Sticker = sticker
	}
	for _, p := range strings.Fields(params) {
		switch {
		case p == "loop":
			c.Loop = true
		case p == "hold":
			c.Hold = true
		case strings.HasPrefix(p, "#"):
			if !colorPattern.MatchString(p) {
				return c, fmt.Errorf("colour %q must be #RRGGBB", p)
			}
			c.Color = strings.ToUpper(p)
		case strings.HasPrefix(p, "x") && len(p) > 1:
			n, err := strconv.Atoi(p[1:])
			if err != nil || n < 1 || n > 50 {
				return c, fmt.Errorf("repeat %q must be x1…x50", p)
			}
			c.Repeat = n
		case strings.HasSuffix(p, "s"):
			// The per-effect range (0.05–30 s for a sticker effect's cycle,
			// 1–120 s for a canvas effect) is checked by Validate.
			d, err := strconv.ParseFloat(strings.TrimSuffix(p, "s"), 64)
			if err != nil || d < 0.05 || d > 120 {
				return c, fmt.Errorf("duration %q must be 0.05s…120s", p)
			}
			c.Duration = d
		default:
			v, err := strconv.ParseFloat(p, 64)
			if err != nil || v < 0 || v > 1 {
				return c, fmt.Errorf("unknown parameter %q (want xN, loop, hold, #RRGGBB, Ns or an intensity 0–1)", p)
			}
			if v == 0 {
				c.Intensity = -1
			} else {
				c.Intensity = v
			}
		}
	}
	if c.Loop && c.Repeat > 0 {
		return c, fmt.Errorf("loop and xN are exclusive")
	}
	return c, nil
}

// WordCount counts narration words (cues excluded).
func WordCount(text string) int {
	_, plain, _ := ParseCues(text)
	if plain == "" {
		return 0
	}
	return len(strings.Fields(plain))
}

// Forbidden words per language primary subtag, matched as whole words,
// case-insensitively. Passing this list is necessary, not sufficient —
// GUIDE.md holds the actual safety standard.
var forbidden = map[string][]string{
	"en": {"kill", "kills", "killed", "dead", "die", "dies", "died", "death", "blood", "bleed", "gun", "guns", "knife", "knives", "sword", "bomb",
		"monster", "monsters", "ghost", "ghosts", "witch", "witches", "scary", "terrified", "terrifying", "nightmare", "nightmares", "horror",
		"hate", "hates", "hated", "stupid", "dumb", "idiot", "ugly", "fat", "shut", "poison", "drown", "drowned", "trapped", "war", "fight", "fights", "fighting", "punch", "hit", "hits",
		"hell", "damn", "devil", "demon", "zombie", "vampire", "skeleton", "creepy", "evil", "wicked", "cruel", "hurt", "hurts", "wound", "wounded", "starving", "lost forever"},
	"es": {"matar", "mata", "mató", "muerto", "muerta", "muertos", "muerte", "morir", "murió", "sangre", "pistola", "cuchillo", "espada", "bomba",
		"monstruo", "monstruos", "fantasma", "fantasmas", "bruja", "brujas", "aterrador", "aterrorizado", "pesadilla", "pesadillas", "terror", "horror",
		"odio", "odia", "odiaba", "estúpido", "estúpida", "tonto", "tonta", "idiota", "feo", "fea", "gordo", "gorda", "cállate", "veneno", "ahogar", "ahogado", "atrapado", "guerra", "pelea", "peleas", "pegar", "golpe", "golpear",
		"infierno", "diablo", "demonio", "zombi", "vampiro", "esqueleto", "malvado", "malvada", "cruel", "herido", "herida", "hambriento"},
}

func primarySubtag(lang string) string {
	if i := strings.IndexAny(lang, "-_"); i > 0 {
		return strings.ToLower(lang[:i])
	}
	return strings.ToLower(lang)
}

// ForbiddenWords returns the forbidden words found in a plain text.
func ForbiddenWords(lang, plain string) []string {
	list := forbidden[primarySubtag(lang)]
	if len(list) == 0 {
		return nil
	}
	lower := strings.ToLower(plain)
	// Whole-word match: split on non-letters (accents count as letters).
	words := strings.FieldsFunc(lower, func(r rune) bool { return !unicode.IsLetter(r) && r != '\'' })
	set := make(map[string]bool, len(words))
	for _, w := range words {
		set[strings.Trim(w, "'")] = true
	}
	var found []string
	for _, f := range list {
		if strings.Contains(f, " ") {
			if strings.Contains(lower, f) {
				found = append(found, f)
			}
			continue
		}
		if set[f] {
			found = append(found, f)
		}
	}
	return found
}

// Manifest is the part of a pack manifest validation needs.
type Manifest struct {
	ID        string
	Languages []string
	Stickers  []string
	Setting   string // outdoors | indoors | none ("" reads as none)
}

// EffectiveSetting returns the pack's setting, defaulting to "none".
func (m Manifest) EffectiveSetting() string {
	if m.Setting == "" {
		return "none"
	}
	return m.Setting
}

// Issues collects errors (must fix) and warnings (should look) per story.
type Issues struct {
	Errors   []string
	Warnings []string
}

func (i *Issues) errorf(format string, args ...any) {
	i.Errors = append(i.Errors, fmt.Sprintf(format, args...))
}
func (i *Issues) warnf(format string, args ...any) {
	i.Warnings = append(i.Warnings, fmt.Sprintf(format, args...))
}

// Validate checks one story against the pack and the effects catalogue.
func Validate(s *Story, m Manifest, cat *Catalog) Issues {
	var is Issues
	if s.Schema != SupportedSchema {
		is.errorf("schema must be %d, got %d", SupportedSchema, s.Schema)
	}
	if !idPattern.MatchString(s.ID) {
		is.errorf("id %q must be lowercase a-z0-9 with single hyphens", s.ID)
	}
	if s.Dir != "" && filepath.Base(s.Dir) != s.ID {
		is.errorf("id %q does not match folder name %q", s.ID, filepath.Base(s.Dir))
	}
	if s.Pack != m.ID {
		is.errorf("pack %q does not match manifest id %q", s.Pack, m.ID)
	}
	declared := make(map[string]bool, len(m.Stickers))
	for _, st := range m.Stickers {
		declared[st] = true
	}
	if declared[CanvasTarget] {
		is.errorf("the pack has a sticker called %q, which is the reserved canvas-effect target; rename it", CanvasTarget)
	}
	inStory := make(map[string]bool)
	checkStickers := func(field string, ids []string, max int) {
		if len(ids) > max {
			is.errorf("%s lists %d stickers (max %d)", field, len(ids), max)
		}
		for _, id := range ids {
			if !declared[id] {
				is.errorf("%s: sticker %q is not in the pack", field, id)
			}
			if inStory[id] {
				is.errorf("%s: sticker %q listed twice (featured/supporting must be disjoint)", field, id)
			}
			inStory[id] = true
		}
	}
	checkStickers("featured", s.Featured, MaxFeatured)
	checkStickers("supporting", s.Supporting, MaxSupporting)
	if len(s.Featured) > 0 && len(s.Featured) < 3 {
		is.warnf("featured has %d stickers; stories usually centre on 3–4 (or none for a fallback)", len(s.Featured))
	}
	if len(s.Tags) == 0 || len(s.Tags) > MaxTags {
		is.errorf("tags: want 1–%d, got %d", MaxTags, len(s.Tags))
	}
	for _, t := range s.Tags {
		if !idPattern.MatchString(t) {
			is.errorf("tag %q must be lowercase kebab-case", t)
		}
	}
	if strings.TrimSpace(s.Premise) == "" {
		is.errorf("premise is required")
	}
	if strings.TrimSpace(s.Inspiration) == "" {
		is.warnf("inspiration is empty — name the classic structure or motif the story draws on")
	}
	if strings.TrimSpace(s.Lesson) == "" {
		is.warnf("lesson is empty (for reviewers; never in the text)")
	}

	// Languages: exactly the pack's.
	var cueShapes [][]string
	var cueLangs []string
	for _, lang := range m.Languages {
		loc, ok := s.Languages[lang]
		if !ok {
			is.errorf("missing language %q", lang)
			continue
		}
		if strings.TrimSpace(loc.Title) == "" {
			is.errorf("%s: title is required", lang)
		} else if n := len(strings.Fields(loc.Title)); n > MaxTitleWords {
			is.warnf("%s: title has %d words (max %d)", lang, n, MaxTitleWords)
		}
		cues, plain, cueErrs := ParseCues(loc.Text)
		for _, e := range cueErrs {
			is.errorf("%s: %v", lang, e)
		}
		n := len(strings.Fields(plain))
		switch {
		case n < MinWords || n > MaxWords:
			is.errorf("%s: %d words; must be %d–%d", lang, n, MinWords, MaxWords)
		case n < TargetMinWords || n > TargetMaxWords:
			is.warnf("%s: %d words; target is %d–%d", lang, n, TargetMinWords, TargetMaxWords)
		}
		if strings.ContainsAny(plain, "*_#`") {
			is.warnf("%s: text contains Markdown-looking characters", lang)
		}
		if bad := ForbiddenWords(lang, plain); len(bad) > 0 {
			is.errorf("%s: forbidden words: %s", lang, strings.Join(bad, ", "))
		}
		if len(cues) == 0 {
			is.errorf("%s: no effect cues (at least one required)", lang)
		}
		var shape []string
		canvasCues := 0
		for _, c := range cues {
			if c.Canvas {
				canvasCues++
				shape = append(shape, CanvasTarget+":"+c.Effect)
				validateCanvasCue(&is, lang, c, m, cat)
				continue
			}
			shape = append(shape, c.Sticker+":"+c.Effect)
			if !inStory[c.Sticker] {
				is.errorf("%s: cue %s targets %q, which is neither featured nor supporting", lang, c.Raw, c.Sticker)
			}
			e, known := cat.Effects[c.Effect]
			if !known {
				if _, isCanvas := cat.Canvas[c.Effect]; isCanvas {
					is.errorf("%s: cue %s: %s is a canvas effect; write {%s:%s …}", lang, c.Raw, c.Effect, CanvasTarget, c.Effect)
				} else {
					is.errorf("%s: cue %s: unknown effect %q", lang, c.Raw, c.Effect)
				}
				continue
			}
			if (c.Repeat > 0 || c.Loop) && !e.accepts("repeat") {
				is.errorf("%s: cue %s: %s ignores repeat/loop", lang, c.Raw, c.Effect)
			}
			if c.Hold && !e.Hold {
				is.errorf("%s: cue %s: %s does not support hold", lang, c.Raw, c.Effect)
			}
			if c.Color != "" && !e.accepts("color") {
				is.errorf("%s: cue %s: %s ignores colour", lang, c.Raw, c.Effect)
			}
			if e.RequiresColor && c.Color == "" {
				is.errorf("%s: cue %s: %s requires a colour (#RRGGBB)", lang, c.Raw, c.Effect)
			}
			if c.Duration > 0 && !inRange(c.Duration, e.DurationRange) {
				is.errorf("%s: cue %s: %s takes a cycle of %g–%g s", lang, c.Raw, c.Effect, e.DurationRange[0], e.DurationRange[1])
			}
		}
		if canvasCues > MaxCanvasCues {
			is.warnf("%s: %d canvas cues; canvas effects are occasional — at most %d per story", lang, canvasCues, MaxCanvasCues)
		}
		if canvasCues > 0 && canvasCues == len(cues) {
			is.warnf("%s: only canvas cues — the stickers should react too", lang)
		}
		cueShapes = append(cueShapes, shape)
		cueLangs = append(cueLangs, lang)
	}
	for lang := range s.Languages {
		found := false
		for _, l := range m.Languages {
			if l == lang {
				found = true
			}
		}
		if !found {
			is.errorf("language %q is not declared by the pack", lang)
		}
	}
	// Same beats, same cues: compare the multiset of sticker:effect per language.
	if len(cueShapes) > 1 {
		ref := sortedCopy(cueShapes[0])
		for i := 1; i < len(cueShapes); i++ {
			if strings.Join(sortedCopy(cueShapes[i]), ",") != strings.Join(ref, ",") {
				is.warnf("cues differ between %s and %s — the same beats should carry the same cues", cueLangs[0], cueLangs[i])
			}
		}
	}
	return is
}

// validateCanvasCue checks a {canvas:…} cue: a known canvas effect that
// suits the pack's setting, with only an intensity and a duration.
func validateCanvasCue(is *Issues, lang string, c Cue, m Manifest, cat *Catalog) {
	e, known := cat.Canvas[c.Effect]
	if !known {
		if _, isSticker := cat.Effects[c.Effect]; isSticker {
			is.errorf("%s: cue %s: %s is a sticker effect, not a canvas effect", lang, c.Raw, c.Effect)
		} else {
			is.errorf("%s: cue %s: unknown canvas effect %q", lang, c.Raw, c.Effect)
		}
		return
	}
	if setting := m.EffectiveSetting(); !e.SuitsSetting(setting) {
		is.errorf("%s: cue %s: %s suits %s packs; this pack's setting is %q", lang, c.Raw, c.Effect, strings.Join(e.Settings, "/"), setting)
	}
	if c.Repeat > 0 || c.Loop || c.Hold || c.Color != "" {
		is.errorf("%s: cue %s: a canvas effect takes only an intensity and a duration (Ns)", lang, c.Raw)
	}
	if c.Duration > 0 && !inRange(c.Duration, e.DurationRange) {
		is.errorf("%s: cue %s: %s stays on for %g–%g s", lang, c.Raw, c.Effect, e.DurationRange[0], e.DurationRange[1])
	}
}

func sortedCopy(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}

// Coverage summarises a set of stories against the pack.
type Coverage struct {
	Stories   int
	Fallbacks int
	Featured  map[string]int // sticker → stories featuring it
	Used      map[string]int // sticker → stories featuring or supporting it
	// EffectUse counts the stories whose first language cues each effect
	// (sticker effects by name, canvas effects as "canvas:<name>").
	EffectUse map[string]int
	// CanvasStories counts the stories that use any canvas effect.
	CanvasStories int
	Duplicate     []string // ids sharing a featured set with another story
	Errors        []string
	Warnings      []string
}

// Cover computes coverage and set-level issues.
func Cover(stories []*Story, m Manifest, expected int) Coverage {
	c := Coverage{Stories: len(stories), Featured: map[string]int{}, Used: map[string]int{}, EffectUse: map[string]int{}}
	for _, st := range m.Stickers {
		c.Featured[st] = 0
		c.Used[st] = 0
	}
	ids := map[string]bool{}
	titles := map[string]string{}
	sets := map[string][]string{}
	for _, s := range stories {
		if ids[s.ID] {
			c.Errors = append(c.Errors, fmt.Sprintf("duplicate story id %q", s.ID))
		}
		ids[s.ID] = true
		if len(s.Featured) == 0 {
			c.Fallbacks++
		}
		if len(m.Languages) > 0 {
			cues, _, _ := ParseCues(s.Languages[m.Languages[0]].Text)
			seen := map[string]bool{}
			usesCanvas := false
			for _, cue := range cues {
				key := cue.Effect
				if cue.Canvas {
					key = CanvasTarget + ":" + cue.Effect
					usesCanvas = true
				}
				if !seen[key] {
					seen[key] = true
					c.EffectUse[key]++
				}
			}
			if usesCanvas {
				c.CanvasStories++
			}
		}
		for _, st := range s.Featured {
			c.Featured[st]++
			c.Used[st]++
		}
		for _, st := range s.Supporting {
			c.Used[st]++
		}
		key := strings.Join(sortedCopy(s.Featured), "+")
		if key != "" {
			sets[key] = append(sets[key], s.ID)
		}
		for lang, loc := range s.Languages {
			k := lang + ":" + strings.ToLower(strings.TrimSpace(loc.Title))
			if other, dup := titles[k]; dup {
				c.Warnings = append(c.Warnings, fmt.Sprintf("%s and %s share the %s title %q", other, s.ID, lang, loc.Title))
			}
			titles[k] = s.ID
		}
	}
	for key, group := range sets {
		if len(group) > 1 {
			sort.Strings(group)
			c.Duplicate = append(c.Duplicate, fmt.Sprintf("%s: %s", key, strings.Join(group, ", ")))
		}
	}
	sort.Strings(c.Duplicate)
	for _, d := range c.Duplicate {
		c.Warnings = append(c.Warnings, "same featured set in several stories — make sure the premises differ: "+d)
	}
	for _, st := range m.Stickers {
		switch n := c.Featured[st]; {
		case n == 0:
			c.Errors = append(c.Errors, fmt.Sprintf("sticker %q is never featured", st))
		case n < MinFeaturedPer:
			c.Warnings = append(c.Warnings, fmt.Sprintf("sticker %q is featured in only %d stories (want ≥ %d)", st, n, MinFeaturedPer))
		}
	}
	if c.Fallbacks < MinFallbacks {
		c.Warnings = append(c.Warnings, fmt.Sprintf("%d fallback stories (no featured stickers); want ≥ %d", c.Fallbacks, MinFallbacks))
	}
	if len(stories) > 0 && float64(c.CanvasStories) > MaxCanvasShare*float64(len(stories)) {
		c.Warnings = append(c.Warnings, fmt.Sprintf("canvas effects in %d of %d stories; they are occasional weather — keep them under %.0f%%", c.CanvasStories, len(stories), MaxCanvasShare*100))
	}
	if expected > 0 && len(stories) != expected {
		c.Warnings = append(c.Warnings, fmt.Sprintf("%d stories; the set should have %d", len(stories), expected))
	}
	return c
}
