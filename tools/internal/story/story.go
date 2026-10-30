// Package story defines the intermediate story format authored by the
// author-stories skill (tools/author/stories/FORMAT.md) and validates it:
// structure, inline effect cues (sticker, canvas and sound) against the
// effects catalogue and the pack's setting, Eleven v3 audio tags against
// the allowed list, word budgets, forbidden words, and coverage (stickers,
// effects, learning) across a pack's set of stories.
package story

import (
	"cmp"
	"encoding/json"
	"fmt"
	"maps"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"stickerstories/tools/internal/manifest"
)

// SupportedSchema is the only story.json schema this package accepts.
const SupportedSchema = 1

// Word budgets per language (words excluding cues). Eleven v4 narration
// with its sounds mixed in runs about two words a second; a 50–80 s story
// is about 100–150 words, the target band, inside a looser hard range.
const (
	MinWords       = 65
	MaxWords       = 170
	TargetMinWords = 100
	TargetMaxWords = 150
	MaxTitleWords  = 6
	MaxFeatured    = 4
	MaxSupporting  = 4
	MaxTags        = 5
	MinFeaturedPer = 5 // each sticker should be featured at least this often (warning)
	MinLivePer     = 3 // each sticker's action should play in at least this many stories (warning)
	MinFallbacks   = 3
	DefaultCount   = 50
	MaxCanvasCues  = 3 // canvas effects per story and language before a warning
	// Spoken words per cue on the stickers (effects, live animations, faces)
	// before a warning: past this the stage sits still for long stretches.
	MaxWordsPerCue = 12
	// Audio tags per story and language before a warning: a few well-placed
	// ones read as performance, many read as a tic (and v3 may say them).
	MaxAudioTags = 6
	// Sound effects (inline cues plus legacy hints) per story and language.
	MaxSounds = 6
	// Sound effect length the API accepts, seconds.
	MinSoundSeconds = 0.5
	MaxSoundSeconds = 30.0
	// Share of a pack's stories that should carry a small piece of learning.
	MinLearningShare = 0.3
	MaxLearningShare = 0.5
)

// Story is one authored story with every language.
type Story struct {
	Schema      int      `json:"schema"`
	ID          string   `json:"id"`
	Pack        string   `json:"pack"`
	Featured    []string `json:"featured"`
	Supporting  []string `json:"supporting"`
	Tags        []string `json:"tags"`
	Premise     string   `json:"premise"`
	Inspiration string   `json:"inspiration"`
	Lesson      string   `json:"lesson"`
	// Learning is the one small, true thing about the pack's world the
	// story shows in passing (how bees carry pollen, why owls hunt at
	// night); empty for a story that is just a story. About four in ten
	// stories carry one (GUIDE.md, "Learning").
	Learning  string                  `json:"learning,omitempty"`
	Languages map[string]Localization `json:"languages"`
	// Sounds are the story's sound effects, cued in the text as {sfx:id}
	// (played under the next word) or {sfx:id solo} (the narration pauses
	// and the sound plays instead of a word).
	Sounds map[string]SoundSpec `json:"sounds,omitempty"`
	// Sound is the older hint form: a sound played on a spoken word.
	Sound []SoundHint `json:"sound,omitempty"`

	// Dir is where the story was loaded from (not part of the JSON).
	Dir string `json:"-"`
}

// Localization is one language's title and cued text.
type Localization struct {
	Title string `json:"title"`
	Text  string `json:"text"`
}

// SoundSpec describes one sound effect for the sound-generation model.
type SoundSpec struct {
	// Prompt describes the sound in plain words ("gentle rain tapping on
	// big leaves"). The renderer adds the house style.
	Prompt string `json:"prompt"`
	// Seconds is the sound's length (0.5–30); 0 means 2 seconds. A solo
	// sound pauses the narration for exactly this long.
	Seconds float64 `json:"seconds,omitempty"`
	// Loop makes an ambience bed: generated seamless and played low under
	// the narration from its cue for Seconds (or to the end of the story).
	Loop bool `json:"loop,omitempty"`
}

// EffectiveSeconds returns the sound length, defaulting to 2 s.
func (s SoundSpec) EffectiveSeconds() float64 {
	if s.Seconds <= 0 {
		return 2
	}
	return s.Seconds
}

// SoundHint is the older hint form: a sound effect played on a spoken word
// (cue is a word in the text, note describes the sound).
type SoundHint struct {
	Cue  string `json:"cue"`
	Note string `json:"note"`
}

// AudioTag is one audio tag the narration may carry inline, in square
// brackets ([whispers], [giggles], [pause]), for Eleven v4 to perform.
// The list is curated for children's narration and for what the model
// performs reliably — and it names only ways of speaking: v4 also plays
// tags that name a sound ([applause], [light rain]), and a story's sounds
// come from its sounds table, mixed, never from the voice. The validator
// rejects anything else. Experimental tags are documented by ElevenLabs as
// less consistent — use them sparingly.
type AudioTag struct {
	Name         string
	Kind         string // pause | delivery | emotion | reaction | voice
	Note         string
	Experimental bool
}

// AudioTags lists every allowed audio tag.
var AudioTags = []AudioTag{
	{"pause", "pause", "a beat of silence; also written as an ellipsis (…) in the text", false},
	{"short pause", "pause", "a quick beat: a held breath before a reveal", false},
	{"long pause", "pause", "a real silence: the moment before something big, or a sleepy hush", false},
	{"whispers", "delivery", "a secret, a sleeping friend, a hush", false},
	{"softly", "delivery", "tender, close, bedtime", false},
	{"slowly", "delivery", "a snail, a sleepy voice, suspense", false},
	{"drawn out", "delivery", "stretches the next word (sloooowly)", false},
	{"rushed", "delivery", "hurry, excitement tumbling over itself", false},
	{"warmly", "delivery", "a kind word, a welcome, a hug in the voice", false},
	{"gently", "delivery", "a careful moment, a small creature, comfort", false},
	{"playfully", "delivery", "a game, a tease, a joke between friends", false},
	{"excited", "emotion", "big news, a game, a discovery", false},
	{"curious", "emotion", "a question, a peek, a wondering", false},
	{"happily", "emotion", "the warm ending, a reunion", false},
	{"surprised", "emotion", "a friend appears, a sneeze, a splash", false},
	{"sad", "emotion", "a small sorrow that the story mends", false},
	{"proudly", "emotion", "a job well done, a first time", false},
	{"in awe", "emotion", "something huge or beautiful: the Earth rising, a rocket, a rainbow", false},
	{"nervously", "emotion", "a small worry before it is solved (never fear)", false},
	{"mischievously", "emotion", "a secret plan, a trick about to be played", false},
	{"laughs", "reaction", "a good laugh", false},
	{"giggles", "reaction", "a small, playful laugh", false},
	{"gasps", "reaction", "a surprise, a wonder", false},
	{"sighs", "reaction", "relief, tiredness, contentment", false},
	{"exhales", "reaction", "a slow breath out, calm", false},
	{"yawns", "reaction", "bedtime", true},
	{"sings", "reaction", "a line sung rather than said", true},
}

var audioTagByName = func() map[string]AudioTag {
	m := make(map[string]AudioTag, len(AudioTags))
	for _, t := range AudioTags {
		m[t.Name] = t
	}
	return m
}()

// voiceTagPattern is the one open-ended tag: the narrator doing a
// character's voice, described the way v4 follows best — "[in a deep,
// slow voice]", "[in a tiny, squeaky voice]". It must end in "voice", so it
// can only ever direct the speaking.
var voiceTagPattern = regexp.MustCompile(`^in an? [a-z]+(?:,? [a-z-]+){0,4} voice$`)

// LookupAudioTag returns the allowed tag with this name, if any.
func LookupAudioTag(name string) (AudioTag, bool) {
	name = strings.ToLower(strings.TrimSpace(name))
	if t, ok := audioTagByName[name]; ok {
		return t, true
	}
	if voiceTagPattern.MatchString(name) {
		return AudioTag{name, "voice", "the narrator doing a character's voice, right before the line", false}, true
	}
	return AudioTag{}, false
}

// PlacedTag is an audio tag in a text and the spoken word it precedes.
type PlacedTag struct {
	Name      string
	WordIndex int // the word the tag colours; len(Words) for a trailing tag
	Raw       string
}

// CanvasTarget is the reserved cue target for canvas effects:
// {canvas:rain 0.7 12s}. SoundTarget is the reserved target for sound
// effects: {sfx:rain-taps} or {sfx:rain-taps solo}. A pack must not name a
// sticker after either.
const (
	CanvasTarget = "canvas"
	// CanvasStop ends a canvas effect on the word it is on ({canvas:rain
	// stop}): the effect started before it clears from there, so it lasts
	// exactly as long as the words keep it.
	CanvasStop  = "stop"
	SoundTarget = "sfx"
)

// LiveEffect is the reserved cue effect that plays one of a sticker's live
// animations (its own frames: the bear cub yawning, the frog catching a
// fly): {bear:live}, or {bear:live yawn} to name one when a sticker has
// several. An animation with a pause frame can also stop there and stay —
// {snail:live hold}, the snail tucked in its shell — until {snail:live
// resume} plays the rest (or the story ends with it held). It is not a
// sticker effect (docs/effects.md keeps character animation a separate
// system) and takes no other parameters.
const LiveEffect = "live"

// Live cue keywords: play up to the pause frame and stay; play on from it.
const (
	LiveHold   = "hold"
	LiveResume = "resume"
)

// AllTarget is the reserved cue target for every sticker on the canvas:
// {all:hop}, {all:face sleeping}. A pack must not name a sticker this.
const AllTarget = "all"

// FaceEffect is the reserved cue effect that changes a sticker's face to
// one of its expression variants: {bear:face happy}, {all:face sleeping},
// {bear:face normal}. A face has no duration: it stays until the next
// face cue for that sticker (or all), and the story's end resets it.
const FaceEffect = "face"

// Normal is the sticker's own face.
const Normal = "normal"

// EnterEffect is the reserved cue effect that marks where the story first
// names a sticker: {fox:enter}. If the child has not placed that sticker,
// the app brings it into the scene there, the way its manifest stage says
// (hopping or flying in from the side, or growing where it stands). Every
// featured and supporting sticker has exactly one per language, on the
// word that first names it. Its only parameter is another way in than the
// usual one: {ladybug:enter by fly} (GoBy, one of the sticker's moves).
const EnterEffect = "enter"

// GoEffect is the reserved cue effect that moves a sticker
// (docs/effects.md, "Movement"): {fox:go to rabbit} (beside it),
// {frog:go to pond} (a feature), {bee:go on flower}, {mouse:go under
// mushroom}, {fox:go away} (off the canvas), {fox:go back} (to its own
// spot). Only stickers that walk or fly move (a stage entrance of hop or
// fly); the target must be on stage already. A sticker with more than one
// move goes its usual way unless the cue names another:
// {ladybug:go on flower by fly}.
const GoEffect = "go"

// SaysEffect is the reserved cue that gives a character's line its own
// voice: {woman:says} right before a quoted line ("Look, a comet!") makes
// that line read by the sticker's character voice (character-voices.json
// beside the stories) instead of the narrator, and the narrator carries on
// after the closing quote. It is not an effect: the app never sees it.
const SaysEffect = "says"

// Quote marks that open and close a character's line: English and
// Spanish, German („…“), French and Italian («…»), Japanese and Chinese
// (「…」, 『…』).
const (
	openQuotes  = "\"“«„「『"
	closeQuotes = "\"”»“」』"
)

// GoBy introduces the move an entrance or a move goes by: {x:go … by fly}.
const GoBy = "by"

// GoLeft and GoRight say which way across the screen a move goes, when
// the story says: {leaf:go away right} — what the wind carries goes
// right, the way the wind effect blows. On go to and go away only.
const (
	GoLeft  = "left"
	GoRight = "right"
)

// GoAnother sends a sticker to another part of the place it is at: {woodpecker:go
// to trunks another} flies on to the next tree. Without it, going to a
// place it is already at keeps it there.
const GoAnother = "another"

// GoBackwards has a sticker go the other way to the one it faces — only
// when the words say it goes backwards ({crab:go to rock backwards}):
// otherwise every sticker turns to face the way it goes.
const GoBackwards = "backwards"

// Move kinds.
const (
	GoTo    = "to"
	GoOn    = "on"
	GoUnder = "under"
	GoAway  = "away"
	GoBack  = "back"
)

// MaxLiveCues is how many live animations one story may start per language
// before a warning (a hold and its resume count once): they tell the
// story's moments, but a stage that never stops moving tells none.
const MaxLiveCues = 5

// Cue is one parsed inline cue. A canvas cue (Canvas true) has no sticker
// and takes only an intensity and a duration. A sound cue (Sound true)
// names an entry of the story's sounds table in Effect and may be Solo:
// the narration pauses for the sound instead of speaking over it.
type Cue struct {
	Sticker    string // "" for a canvas or sound cue
	Canvas     bool
	Animation  string // a live cue's animation id; "" = the sticker's only one
	Expression string // a face cue's expression
	GoKind     string // a move's kind: to, on, under, away, back
	Target     string // a move's target: a sticker or (to) a feature
	By         string // the move an entrance or a move goes by ("" = its usual one)
	Toward     string // the side a move goes toward: left, right ("" = where it goes decides); a flowing canvas effect's way
	Another    bool   // go to a place: another part of it than where it is ("on to the next tree")
	Backwards  bool   // a move: backwards, facing away from the way it goes (only when the words say so)
	Prop       string // go to a sticker: beside a prop it holds out ({seagull:go to girl kite})
	Sound      bool
	Solo       bool
	Effect     string
	Repeat     int // 0 = default (1)
	Loop       bool
	Hold       bool    // a sticker effect's hold, or a live cue that stops at the pause frame
	Resume     bool    // a live cue that plays on from the pause frame
	Stop       bool    // a canvas cue that ends the effect started before it
	Color      string  // "#RRGGBB" or ""
	Duration   float64 // seconds, 0 = default
	Intensity  float64 // 0 = default; -1 = explicitly zero
	WordIndex  int     // index of the word the cue fires on (0-based; last word if trailing)
	Raw        string
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
	// DefaultDuration is how long it stays on when the cue gives no time.
	DefaultDuration float64 `json:"defaultDuration"`
	// RampIn and RampOut are how long it takes to build up and to clear,
	// in seconds, within its duration.
	RampIn  float64 `json:"rampIn"`
	RampOut float64 `json:"rampOut"`
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

// Flows reports whether the canvas effect blows one way across the scene
// (it takes toward: the wind, the current), carrying what has no face.
func (e CanvasEffect) Flows() bool { return slices.Contains(e.Parameters, "toward") }

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
	idPattern = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)
	// numericParam is a repeat, a duration or a bare intensity: never an
	// animation id.
	numericParam = regexp.MustCompile(`^(x[0-9]+|[0-9.]+s?)$`)
	cuePattern   = regexp.MustCompile(`\{([^{}]*)\}`)
	tagPattern   = regexp.MustCompile(`\[([A-Za-z][A-Za-z ,'-]{0,40})\]`)
	colorPattern = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)
)

// Narration is a language's text taken apart: the words the narrator
// speaks, the cues that fire on them, and the audio tags that colour them.
// Everything the tools need downstream comes from here, so the text is
// tokenised exactly once.
type Narration struct {
	// Words are the spoken words in order (punctuation attached).
	Words []string
	// Cues fire on Words[WordIndex] (the last word when trailing).
	Cues []Cue
	// Tags colour Words[WordIndex]; a trailing tag has WordIndex len(Words).
	Tags []PlacedTag
	// Lines are the quoted lines read in a character's voice ({x:says}).
	Lines []Line
}

// Line is a character's line: Words[From:To], quotes included, read by
// Speaker's character voice.
type Line struct {
	Speaker  string
	From, To int
	Raw      string // the says cue as written
}

// Plain is the narration as prose: the words only, single-spaced (or not
// spaced at all between Japanese or Chinese words, joinSep). This is what
// word counts, forbidden-word checks and the pack manifest see.
func (n Narration) Plain() string {
	var b strings.Builder
	for i, w := range n.Words {
		if i > 0 {
			b.WriteString(joinSep(n.Words[i-1], w))
		}
		b.WriteString(w)
	}
	return b.String()
}

// wide reports a character of a script written without spaces between
// words — Han, hiragana, katakana — or their full-width punctuation.
func wide(r rune) bool {
	return unicode.In(r, unicode.Han, unicode.Hiragana, unicode.Katakana) ||
		r >= 0x3000 && r <= 0x303f || r >= 0xff00 && r <= 0xffef
}

// joinSep is what goes between two words of the narration: nothing where
// either side is Japanese or Chinese (a cue there splits the text, it
// does not mean a space), else a space.
func joinSep(prev, next string) string {
	last, _ := utf8.DecodeLastRuneInString(prev)
	first, _ := utf8.DecodeRuneInString(next)
	if wide(last) || wide(first) {
		return ""
	}
	return " "
}

// cjkCharsPerWord is how many Japanese or Chinese characters take as long
// to narrate as an English word (about two words a second): the word
// budgets and limits mean the same time in every language. Measured on
// Eleven v4: Japanese about 4.6 characters a second, Mandarin and
// Cantonese about 3.6.
var cjkCharsPerWord = map[string]float64{"ja": 2.2, "zh": 1.75}

// wordTime is how long a word of a spaced language takes to narrate
// against an English word, measured on Eleven v4 (German 149 words in
// 64.8 s, French 145 in 58.0 s, Italian 151 in 64.8 s, English 127 in
// 60.2 s). Missing languages count 1.
var wordTime = map[string]float64{"de": 0.92, "fr": 0.85, "it": 0.90}

// MaxDrift is how far a transcreation's narration may run from the
// English story's, as a share of it, before a warning.
const MaxDrift = 0.25

// CountWords counts a plain text's words as narration time in lang: words
// between spaces that hold a letter or a number (a spaced dash or ellipsis
// is not one), and in Japanese or Chinese, its characters (Han, kana, the
// long-vowel mark) by cjkCharsPerWord.
func CountWords(lang, plain string) int {
	per := cjkCharsPerWord[primarySubtag(lang)]
	chars, words := 0, 0
	for _, f := range strings.Fields(plain) {
		latin := false
		for _, r := range f {
			switch {
			case per > 0 && (unicode.In(r, unicode.Han, unicode.Hiragana, unicode.Katakana) || r == 'ー'):
				chars++
			case unicode.IsLetter(r) || unicode.IsNumber(r):
				latin = true
			}
		}
		if latin {
			words++
		}
	}
	n := float64(words)
	if t := wordTime[primarySubtag(lang)]; t > 0 {
		n *= t
	}
	if per > 0 {
		n += float64(chars) / per
	}
	return int(math.Round(n))
}

// Segment is a run of words the narrator reads in one go. A solo sound
// cue splits the narration: Solo is the index into Cues of the solo cue
// that plays before this segment (-1 for the first).
type Segment struct {
	From, To int // word range [From, To)
	Solo     int
}

// Segments splits the narration at solo sound cues. A solo cue before the
// first word (or two in a row) still yields a segment, possibly empty.
func (n Narration) Segments() []Segment {
	var out []Segment
	from, solo := 0, -1
	for i, c := range n.Cues {
		if !c.Sound || !c.Solo {
			continue
		}
		out = append(out, Segment{From: from, To: c.WordIndex, Solo: solo})
		from, solo = c.WordIndex, i
	}
	return append(out, Segment{From: from, To: len(n.Words), Solo: solo})
}

// Spoken renders a word range as the narrator reads it — the words with
// their audio tags in place, cues gone — and returns the byte offset of
// each word in that text, so timings from the synthesiser map back to
// word indices exactly.
func (n Narration) Spoken(from, to int) (text string, wordStarts []int) {
	var b strings.Builder
	tagIndex := 0
	for tagIndex < len(n.Tags) && n.Tags[tagIndex].WordIndex < from {
		tagIndex++
	}
	tagged := false // the last thing written is an audio tag
	emit := func(s string) {
		if b.Len() > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(s)
		tagged = true
	}
	for i := from; i < to; i++ {
		for tagIndex < len(n.Tags) && n.Tags[tagIndex].WordIndex == i {
			emit(n.Tags[tagIndex].Raw)
			tagIndex++
		}
		switch {
		case b.Len() == 0:
		case tagged || i == from:
			b.WriteByte(' ')
		default:
			// Japanese and Chinese words run on with no space between.
			b.WriteString(joinSep(n.Words[i-1], n.Words[i]))
		}
		tagged = false
		wordStarts = append(wordStarts, b.Len())
		b.WriteString(n.Words[i])
	}
	// Trailing tags belong to the last segment only.
	if to == len(n.Words) {
		for tagIndex < len(n.Tags) && n.Tags[tagIndex].WordIndex == to {
			emit(n.Tags[tagIndex].Raw)
			tagIndex++
		}
	}
	return b.String(), wordStarts
}

// StripTags removes audio tags from a text (for models that would read
// them aloud), turning [pause] into an ellipsis.
func StripTags(text string) string {
	out := tagPattern.ReplaceAllStringFunc(text, func(m string) string {
		if strings.EqualFold(strings.Trim(m, "[]"), "pause") {
			return "…"
		}
		return ""
	})
	return strings.Join(strings.Fields(out), " ")
}

// Parse takes a language's text apart (see Narration). Syntax problems
// and unknown audio tags are returned as errors; the offending cue or tag
// is dropped so the rest still parses. Parsing is syntactic only — which
// parameters an effect accepts, whether a canvas effect suits the pack and
// whether a sound exists is Validate's job.
func Parse(text string) (Narration, []error) {
	var n Narration
	var errs []error
	var cues []Cue
	var tags []PlacedTag
	// Cues and tags contain spaces ({butterfly:float loop 0.4}, [drawn out]),
	// so lift them out before tokenising, leaving a marker where each stood.
	marked := cuePattern.ReplaceAllStringFunc(text, func(m string) string {
		inner := strings.TrimSuffix(strings.TrimPrefix(m, "{"), "}")
		cue, err := parseCue(inner)
		if err != nil {
			errs = append(errs, fmt.Errorf("cue %q: %w", m, err))
			return " "
		}
		cue.Raw = m
		cues = append(cues, cue)
		return fmt.Sprintf(" \x00%d\x00 ", len(cues)-1)
	})
	if strings.ContainsAny(marked, "{}") {
		errs = append(errs, fmt.Errorf("unbalanced braces in %q", text))
		marked = strings.NewReplacer("{", "", "}", "").Replace(marked)
	}
	marked = tagPattern.ReplaceAllStringFunc(marked, func(m string) string {
		name := strings.ToLower(strings.Join(strings.Fields(strings.Trim(m, "[]")), " "))
		if _, ok := LookupAudioTag(name); !ok {
			errs = append(errs, fmt.Errorf("audio tag %q is not one the narration may use", m))
			return " "
		}
		tags = append(tags, PlacedTag{Name: name, Raw: "[" + name + "]"})
		return fmt.Sprintf(" \x01%d\x01 ", len(tags)-1)
	})
	if strings.ContainsAny(marked, "[]") {
		errs = append(errs, fmt.Errorf("stray square bracket in %q (audio tags are [name])", text))
		marked = strings.NewReplacer("[", "", "]", "").Replace(marked)
	}
	var pendingCues, pendingTags []int
	for _, tok := range strings.Fields(marked) {
		switch {
		case strings.HasPrefix(tok, "\x00") && strings.HasSuffix(tok, "\x00"):
			if idx, err := strconv.Atoi(strings.Trim(tok, "\x00")); err == nil {
				pendingCues = append(pendingCues, idx)
			}
			continue
		case strings.HasPrefix(tok, "\x01") && strings.HasSuffix(tok, "\x01"):
			if idx, err := strconv.Atoi(strings.Trim(tok, "\x01")); err == nil {
				pendingTags = append(pendingTags, idx)
			}
			continue
		}
		n.Words = append(n.Words, tok)
		here := len(n.Words) - 1
		for _, idx := range pendingCues {
			cues[idx].WordIndex = here
			if cues[idx].Effect == SaysEffect && cues[idx].Sticker != "" {
				n.Lines = append(n.Lines, Line{Speaker: cues[idx].Sticker, From: here, Raw: cues[idx].Raw})
				continue
			}
			n.Cues = append(n.Cues, cues[idx])
		}
		for _, idx := range pendingTags {
			tags[idx].WordIndex = here
			n.Tags = append(n.Tags, tags[idx])
		}
		pendingCues, pendingTags = nil, nil
	}
	last := max(len(n.Words)-1, 0)
	for _, idx := range pendingCues {
		if cues[idx].Effect == SaysEffect && cues[idx].Sticker != "" {
			errs = append(errs, fmt.Errorf("cue %s: a line follows it, in quotes", cues[idx].Raw))
			continue
		}
		cues[idx].WordIndex = last
		n.Cues = append(n.Cues, cues[idx])
	}
	for _, idx := range pendingTags {
		tags[idx].WordIndex = len(n.Words)
		n.Tags = append(n.Tags, tags[idx])
	}
	errs = append(errs, n.closeLines()...)
	return n, errs
}

// closeLines finds where each character's line ends: the first word from
// its start (the opening quote aside) that holds a closing quote. A line
// must open with a quote, close, and not run into the next one.
func (n *Narration) closeLines() []error {
	var errs []error
	kept := n.Lines[:0]
	for i, l := range n.Lines {
		first := n.Words[l.From]
		r, size := utf8.DecodeRuneInString(first)
		if !strings.ContainsRune(openQuotes, r) {
			errs = append(errs, fmt.Errorf("cue %s: the line it gives a voice must start with a quote (\"…\", “…”, «…», „…“ or 「…」), not %q", l.Raw, first))
			continue
		}
		limit := len(n.Words)
		if i+1 < len(n.Lines) {
			limit = n.Lines[i+1].From
		}
		end := -1
		for w := l.From; w < limit; w++ {
			rest := n.Words[w]
			if w == l.From {
				rest = rest[size:]
			}
			if strings.ContainsAny(rest, closeQuotes) {
				end = w + 1
				break
			}
		}
		if end < 0 {
			errs = append(errs, fmt.Errorf("cue %s: its line never closes its quote", l.Raw))
			continue
		}
		l.To = end
		kept = append(kept, l)
	}
	n.Lines = kept
	return errs
}

// ParseCues extracts the cues from a text and returns the plain narration
// (cues and audio tags removed, whitespace normalised). See Parse.
func ParseCues(text string) (cues []Cue, plain string, errs []error) {
	n, errs := Parse(text)
	return n.Cues, n.Plain(), errs
}

func parseCue(inner string) (Cue, error) {
	var c Cue
	head, params, _ := strings.Cut(strings.TrimSpace(inner), " ")
	target, effect, ok := strings.Cut(head, ":")
	if !ok || target == "" || effect == "" {
		return c, fmt.Errorf("want {sticker:effect …}, {canvas:effect …} or {sfx:sound …}")
	}
	c.Effect = effect
	switch target {
	case CanvasTarget:
		c.Canvas = true
	case SoundTarget:
		c.Sound = true
	default:
		c.Sticker = target
	}
	fields := strings.Fields(params)
	for i := 0; i < len(fields); i++ {
		p := fields[i]
		switch {
		case p == GoBy && c.Sticker != "" && (c.Effect == GoEffect || c.Effect == EnterEffect):
			if i+1 >= len(fields) || !idPattern.MatchString(fields[i+1]) || c.By != "" {
				return c, fmt.Errorf("by names one of the sticker's moves: by fly")
			}
			i++
			c.By = fields[i]
		case p == "loop":
			c.Loop = true
		case p == "hold":
			c.Hold = true
		case p == "solo":
			c.Solo = true
		case p == CanvasStop && c.Canvas:
			c.Stop = true
		case p == LiveResume && c.Effect == LiveEffect:
			c.Resume = true
		case c.Effect == GoEffect && c.Sticker != "" && c.GoKind == "" && (p == GoTo || p == GoOn || p == GoUnder || p == GoAway || p == GoBack):
			c.GoKind = p
		case c.Effect == GoEffect && c.Sticker != "" && c.GoKind != "" && p == GoAnother:
			c.Another = true
		case c.Effect == GoEffect && c.Sticker != "" && c.GoKind != "" && p == GoBackwards:
			c.Backwards = true
		case (c.Effect == GoEffect && c.Sticker != "" && c.GoKind != "" || c.Canvas) && (p == GoLeft || p == GoRight):
			if c.Toward != "" {
				return c, fmt.Errorf("a move goes one way: left or right")
			}
			c.Toward = p
		case c.Effect == GoEffect && c.Sticker != "" && c.GoKind != "" && c.Target == "" && idPattern.MatchString(p):
			c.Target = p
		case c.Effect == GoEffect && c.Sticker != "" && c.GoKind == GoTo && c.Target != "" && c.Prop == "" && idPattern.MatchString(p) && !numericParam.MatchString(p):
			c.Prop = p
		case c.Effect == FaceEffect && c.Sticker != "" && idPattern.MatchString(p) && !numericParam.MatchString(p):
			if c.Expression != "" {
				return c, fmt.Errorf("a face cue names one expression")
			}
			c.Expression = p
		case c.Effect == LiveEffect && c.Sticker != "" && idPattern.MatchString(p) && !numericParam.MatchString(p):
			// A live cue's only parameter is an animation id ("wings",
			// "tap-tap"); anything else on it is an error in Validate.
			if c.Animation != "" {
				return c, fmt.Errorf("a live cue names at most one animation")
			}
			c.Animation = p
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
				return c, fmt.Errorf("unknown parameter %q (want xN, loop, hold, solo, #RRGGBB, Ns or an intensity 0–1)", p)
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
	if c.Solo && !c.Sound {
		return c, fmt.Errorf("solo is for sound cues only")
	}
	if c.Effect == SaysEffect && !c.Sound && !c.Canvas {
		if c.Sticker == AllTarget {
			return c, fmt.Errorf("a line is said by one character; name it")
		}
		if len(fields) > 0 {
			return c, fmt.Errorf("{%s:%s} takes no parameters", c.Sticker, SaysEffect)
		}
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
	"de": {"töten", "tötet", "getötet", "tot", "tote", "toten", "tod", "sterben", "stirbt", "starb", "blut", "bluten", "pistole", "gewehr", "messer", "schwert", "bombe",
		"monster", "gespenst", "gespenster", "geist", "geister", "hexe", "hexen", "gruselig", "unheimlich", "albtraum", "albträume", "horror", "entsetzlich",
		"hass", "hasse", "hasst", "dumm", "doof", "idiot", "hässlich", "fett", "gift", "ertrinken", "ertrunken", "gefangen", "krieg", "kampf", "kämpfen", "prügeln",
		"hölle", "verdammt", "teufel", "dämon", "zombie", "vampir", "skelett", "böse", "grausam", "verletzt", "wunde", "verhungern"},
	"fr": {"tuer", "tue", "tué", "mort", "morte", "morts", "mourir", "meurt", "sang", "pistolet", "fusil", "couteau", "épée", "bombe",
		"monstre", "monstres", "fantôme", "fantômes", "sorcière", "sorcières", "effrayant", "terrifiant", "terrifié", "cauchemar", "cauchemars", "horreur",
		"haine", "déteste", "stupide", "idiot", "idiote", "moche", "laid", "laide", "tais-toi", "poison", "noyer", "noyé", "piégé", "guerre", "bagarre",
		"enfer", "diable", "démon", "zombie", "vampire", "squelette", "méchant", "méchante", "cruel", "cruelle", "blessé", "blessée", "blessure", "affamé"},
	"it": {"uccidere", "uccide", "ucciso", "morto", "morta", "morti", "morte", "morire", "muore", "sangue", "pistola", "fucile", "coltello", "spada", "bomba",
		"mostro", "mostri", "fantasma", "fantasmi", "strega", "streghe", "spaventoso", "terrificante", "terrorizzato", "incubo", "incubi", "orrore",
		"odio", "odia", "stupido", "stupida", "scemo", "scema", "idiota", "grasso", "grassa", "veleno", "annegare", "annegato", "intrappolato", "guerra", "lotta", "picchiare",
		"inferno", "diavolo", "demone", "zombie", "vampiro", "scheletro", "cattivo", "cattiva", "crudele", "ferito", "ferita", "affamato"},
	"ja": {"殺", "死", "血", "銃", "ナイフ", "剣", "爆弾", "怪物", "モンスター", "おばけ", "お化け", "幽霊", "ゆうれい", "魔女", "こわい", "怖い", "恐ろしい", "悪夢", "ホラー",
		"大嫌い", "バカ", "アホ", "ブス", "デブ", "だまれ", "黙れ", "毒", "おぼれ", "溺れ", "戦争", "けんか", "喧嘩", "殴", "地獄", "悪魔", "ゾンビ", "吸血鬼", "がいこつ", "骸骨", "残酷", "怪我"},
	"zh": {"殺", "死", "血", "手槍", "刀子", "劍", "炸彈", "怪物", "鬼魂", "鬼怪", "巫婆", "女巫", "可怕", "恐怖", "惡夢", "噩夢", "討厭", "恨", "笨蛋", "白痴", "醜八怪", "肥豬", "閉嘴", "毒",
		"溺", "戰爭", "打架", "打人", "地獄", "魔鬼", "惡魔", "殭屍", "吸血鬼", "骷髏", "壞蛋", "殘忍", "受傷", "傷口", "餓死"},
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
	if cjkCharsPerWord[primarySubtag(lang)] > 0 {
		// No spaces between words: any occurrence counts.
		var found []string
		for _, f := range list {
			if strings.Contains(lower, f) {
				found = append(found, f)
			}
		}
		return found
	}
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
	Setting   string // outdoors | indoors | space | underwater | none ("" reads as none)
	// Animations are each sticker's live actions, in manifest order;
	// Moves each sticker's moves (the walk or flight its entrances and
	// moves play), its usual one first.
	Animations map[string][]Animation
	Moves      map[string][]Animation
	// Expressions are each sticker's face variants (besides normal).
	Expressions map[string][]string
	// Names are each sticker's display names by language, for checking
	// that an entrance sits on the first mention.
	Names map[string]map[string]string
	// Stages are each sticker's entrance ("hop", "fly", "grow"); a sticker
	// without a stage in the manifest is absent.
	Stages map[string]string
	// LandsOn are the features each sticker lands on, in order of
	// preference; Features describe the pack's features by id.
	LandsOn  map[string][]string
	Features map[string]string
	// Edges are the features with an edge (the pond): any walker or flyer
	// can be there, the ones that do not go in standing at its edge.
	Edges map[string]bool
	// Air are the features that are open air (the sky), where a flyer is
	// flying: it lands elsewhere before a perched action.
	Air map[string]bool
	// PlaceWords are the words each feature is named by, per language
	// (feature → language → words), for sentences that put a character
	// there.
	PlaceWords map[string]map[string][]string
}

// HasExpression reports whether a face cue on target may show expression:
// normal always; for all, if any sticker has it.
func (m Manifest) HasExpression(target, expression string) bool {
	if expression == Normal {
		return true
	}
	for id, list := range m.Expressions {
		if target != AllTarget && id != target {
			continue
		}
		for _, e := range list {
			if e == expression {
				return true
			}
		}
	}
	return false
}

// Animation is one live animation a sticker carries, as story authors
// need it: what it shows and how long it plays. An action with a pause
// frame says what that frame shows (Pause) and how long it takes to get
// there and, from there, to the end.
type Animation struct {
	ID          string
	Description string
	Seconds     float64
	Pause       string
	ToPause     float64
	FromPause   float64
	// Flies: a move that is a flight. On: where a move brings it in
	// (entrances by that way), empty for its stage's.
	Flies bool
	On    []string
	// Perched: an action it plays sitting on something, never in the air.
	Perched bool
	// Place: the features an action happens at (the woodpecker taps on
	// the trunks).
	Place []string
	// Props: what an action holds out in its paused frame (the girl's
	// kite), where a flyer can go while it is held.
	Props []string
}

// PackManifest reads what story validation needs from a loaded pack
// manifest, live animations included (dir is the pack root).
func PackManifest(m *manifest.Manifest, dir string) (Manifest, error) {
	pack := Manifest{ID: m.ID, Languages: m.Languages, Setting: m.EffectiveSetting(), Animations: map[string][]Animation{}, Moves: map[string][]Animation{}, Expressions: map[string][]string{}, Names: map[string]map[string]string{}, Stages: map[string]string{}, LandsOn: map[string][]string{}, Features: map[string]string{}}
	pack.Air = map[string]bool{}
	pack.Edges = map[string]bool{}
	pack.PlaceWords = map[string]map[string][]string{}
	for id, f := range m.Features {
		pack.Features[id] = f.Description
		if len(f.Edge) > 0 {
			pack.Edges[id] = true
		}
		if len(f.Words) > 0 {
			pack.PlaceWords[id] = f.Words
		}
		if f.Air {
			pack.Air[id] = true
		}
	}
	for _, st := range m.Stickers {
		pack.Stickers = append(pack.Stickers, st.ID)
		pack.Names[st.ID] = st.Name
		if st.Stage != nil {
			pack.Stages[st.ID] = st.Stage.Entrance
			pack.LandsOn[st.ID] = st.Stage.On
		}
		for name := range st.Expressions {
			pack.Expressions[st.ID] = append(pack.Expressions[st.ID], name)
		}
		sort.Strings(pack.Expressions[st.ID])
	}
	anims, err := m.LoadAnimations(dir)
	if err != nil {
		return Manifest{}, err
	}
	for id, list := range anims {
		for _, a := range list {
			anim := Animation{ID: a.ID, Description: a.Description, Seconds: a.Duration(), Flies: a.Flies, On: a.On, Perched: a.Perched, Place: a.Place, Props: slices.Sorted(maps.Keys(a.Props))}
			if a.EffectiveKind() == manifest.KindMove {
				pack.Moves[id] = append(pack.Moves[id], anim)
				continue
			}
			if a.Pause != nil {
				anim.Pause = a.Pause.Shows
				anim.ToPause, anim.FromPause = a.PlaySeconds()
			}
			pack.Animations[id] = append(pack.Animations[id], anim)
		}
	}
	return pack, nil
}

// landsInAir reports whether sticker, coming in by the move by ("" for
// its usual way), lands in open air: the first place it lands is a
// feature marked air (a butterfly in the sky).
func (m Manifest) landsInAir(sticker, by string) bool {
	on := m.LandsOn[sticker]
	for _, a := range m.Moves[sticker] {
		if by != "" && a.ID == by && len(a.On) > 0 {
			on = a.On
		}
	}
	return len(on) > 0 && m.Air[on[0]]
}

// fliesBy reports whether sticker goes by a flight: the move by names, or
// its usual way (a stage entrance of fly).
func (m Manifest) fliesBy(sticker, by string) bool {
	if by != "" {
		for _, a := range m.Moves[sticker] {
			if a.ID == by {
				return a.Flies
			}
		}
	}
	return m.Stages[sticker] == "fly"
}

// ResolveAnimation returns the animation a live cue on sticker plays: the
// named one, or the sticker's only one when id is empty.
func (m Manifest) ResolveAnimation(sticker, id string) (Animation, error) {
	anims := m.Animations[sticker]
	switch {
	case len(anims) == 0:
		return Animation{}, fmt.Errorf("sticker %q has no live animation", sticker)
	case id == "" && len(anims) > 1:
		ids := make([]string, len(anims))
		for i, a := range anims {
			ids[i] = a.ID
		}
		return Animation{}, fmt.Errorf("sticker %q has several live animations; name one (%s)", sticker, strings.Join(ids, ", "))
	case id == "":
		return anims[0], nil
	}
	for _, a := range anims {
		if a.ID == id {
			return a, nil
		}
	}
	return Animation{}, fmt.Errorf("sticker %q has no live animation %q", sticker, id)
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
	if declared[AllTarget] {
		is.errorf("the pack has a sticker called %q, which is the reserved every-sticker target; rename it", AllTarget)
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

	if declared[SoundTarget] {
		is.errorf("the pack has a sticker called %q, which is the reserved sound-effect target; rename it", SoundTarget)
	}
	validateSounds(&is, s)

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
		} else if n := CountWords(lang, loc.Title); n > MaxTitleWords {
			is.warnf("%s: title has %d words (max %d)", lang, n, MaxTitleWords)
		}
		nar, parseErrs := Parse(loc.Text)
		for _, e := range parseErrs {
			is.errorf("%s: %v", lang, e)
		}
		cues, plain := nar.Cues, nar.Plain()
		validateTags(&is, lang, nar)
		n := CountWords(lang, plain)
		// A transcreation is held to its English story (below) rather
		// than to the band, with room for languages that need more words
		// for the same time.
		_, transcreated := s.Languages["en-US"]
		transcreated = transcreated && lang != "en-US"
		maxWords := MaxWords
		if transcreated {
			maxWords = MaxWords + MaxWords/4 // MaxDrift
		}
		switch {
		case n < MinWords || n > maxWords:
			is.errorf("%s: %d words; must be %d–%d", lang, n, MinWords, maxWords)
		case !transcreated && (n < TargetMinWords || n > TargetMaxWords):
			is.warnf("%s: %d words; target is %d–%d", lang, n, TargetMinWords, TargetMaxWords)
		}
		if en, ok := s.Languages["en-US"]; ok && lang != "en-US" {
			ref, _ := Parse(en.Text)
			if e := CountWords("en-US", ref.Plain()); e > 0 && math.Abs(float64(n-e)) > MaxDrift*float64(e) {
				is.warnf("%s: %d words' narration time against the English story's %d; keep within %.0f %%", lang, n, e, MaxDrift*100)
			}
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
		canvasCues, sounds, liveCues, faceCues, enterCues := 0, len(s.Sound), 0, 0, 0
		held := map[string]string{} // sticker → the action it holds paused
		enterAt := map[string]int{}
		away := map[string]bool{}  // stickers a move took off the canvas
		moved := map[string]bool{} // stickers a move took somewhere
		// Stickers up in the air (flying in the sky, hovering beside
		// someone): a perched action needs them landed first.
		aloft := map[string]bool{}
		// The feature each sticker is on ("" when beside or on another,
		// or off the canvas), for actions that happen in one place.
		place := map[string]string{}
		// The way each flowing canvas effect blows (the wind), while it does.
		blowing := map[string]string{}
		home := func(id string) string {
			if on := m.LandsOn[id]; len(on) > 0 {
				return on[0]
			}
			return ""
		}
		for id := range inStory {
			aloft[id] = m.landsInAir(id, "")
			place[id] = home(id)
		}
		for _, c := range cues {
			if c.Sticker != "" && away[c.Sticker] && !(c.Effect == GoEffect && c.GoKind == GoBack) {
				is.warnf("%s: cue %s: %s has gone away (off the canvas) — bring it back first ({%s:%s %s})", lang, c.Raw, c.Sticker, c.Sticker, GoEffect, GoBack)
			}
			if c.Sound {
				sounds++
				shape = append(shape, SoundTarget+":"+c.Effect)
				validateSoundCue(&is, lang, c, s, nar)
				continue
			}
			if c.Canvas {
				if c.Stop {
					shape = append(shape, CanvasTarget+":"+c.Effect+":"+CanvasStop)
					delete(blowing, c.Effect)
				} else {
					canvasCues++
					shape = append(shape, CanvasTarget+":"+c.Effect+":"+c.Toward)
					if cat.Canvas[c.Effect].Flows() {
						blowing[c.Effect] = cmp.Or(c.Toward, GoRight)
					}
				}
				validateCanvasCue(&is, lang, c, m, cat)
				continue
			}
			if c.Effect == EnterEffect {
				enterCues++
				shape = append(shape, c.Sticker+":"+EnterEffect+":"+c.By)
				switch {
				case c.Sticker == AllTarget:
					is.errorf("%s: cue %s: an entrance names one sticker", lang, c.Raw)
				case !inStory[c.Sticker]:
					is.errorf("%s: cue %s targets %q, which is neither featured nor supporting", lang, c.Raw, c.Sticker)
				default:
					if _, twice := enterAt[c.Sticker]; twice {
						is.errorf("%s: cue %s: %s already enters earlier; one entrance per sticker, on its first mention", lang, c.Raw, c.Sticker)
					} else {
						enterAt[c.Sticker] = c.WordIndex
						aloft[c.Sticker] = m.landsInAir(c.Sticker, c.By)
						// Coming in by a way that lands it somewhere (paddling
						// in: the sea), it is there.
						for _, mv := range m.Moves[c.Sticker] {
							if mv.ID == c.By && len(mv.On) > 0 {
								place[c.Sticker] = mv.On[0]
							}
						}
					}
				}
				if c.Repeat > 0 || c.Loop || c.Hold || c.Color != "" || c.Duration > 0 || c.Intensity != 0 {
					is.errorf("%s: cue %s: an entrance takes no parameters but the way it comes in (by …)", lang, c.Raw)
				}
				validateBy(&is, lang, c, m)
				continue
			}
			if c.Effect == GoEffect {
				shape = append(shape, c.Sticker+":go:"+c.GoKind+":"+c.Target+":"+c.By+":"+c.Toward+":"+fmt.Sprint(c.Another)+":"+fmt.Sprint(c.Backwards)+":"+c.Prop)
				validateGoCue(&is, lang, c, m, inStory, enterAt)
				// What has no face goes with the wind (render.CarryWithFlows
				// sends it that way when the cue does not say).
				if len(m.Expressions[c.Sticker]) == 0 && c.Toward != "" {
					for _, fx := range slices.Sorted(maps.Keys(blowing)) {
						if blowing[fx] != c.Toward {
							is.warnf("%s: cue %s: the %s blows %s, and %s goes with it — drop %s or turn the %s first ({%s:%s %s})", lang, c.Raw, fx, blowing[fx], c.Sticker, c.Toward, fx, CanvasTarget, fx, c.Toward)
						}
					}
				}
				if c.Prop != "" {
					validatePropGo(&is, lang, c, m, held[c.Target])
				}
				switch c.GoKind {
				case GoTo:
					if _, isPlace := m.Features[c.Target]; isPlace {
						place[c.Sticker] = c.Target
					} else {
						place[c.Sticker] = ""
					}
				case GoBack:
					place[c.Sticker] = home(c.Sticker)
				default:
					place[c.Sticker] = ""
				}
				switch c.GoKind {
				case GoOn, GoUnder:
					aloft[c.Sticker] = false
				case GoTo:
					// To a place: in the air if that place is; beside someone:
					// a flyer hovers there.
					if _, place := m.Features[c.Target]; place {
						aloft[c.Sticker] = m.Air[c.Target]
					} else {
						aloft[c.Sticker] = m.fliesBy(c.Sticker, c.By)
					}
				case GoAway:
					away[c.Sticker] = true
				case GoBack:
					if !away[c.Sticker] && !moved[c.Sticker] {
						is.warnf("%s: cue %s: %s has not gone anywhere to come back from", lang, c.Raw, c.Sticker)
					}
					delete(away, c.Sticker)
					aloft[c.Sticker] = m.landsInAir(c.Sticker, "")
				}
				moved[c.Sticker] = true
				continue
			}
			if c.Effect == FaceEffect {
				faceCues++
				shape = append(shape, c.Sticker+":face:"+c.Expression)
				if c.Sticker != AllTarget && !inStory[c.Sticker] {
					is.errorf("%s: cue %s targets %q, which is neither featured nor supporting", lang, c.Raw, c.Sticker)
				}
				if a, ok := held[c.Sticker]; ok {
					is.warnf("%s: cue %s: %s is held paused in its %s, so the face shows only once it resumes", lang, c.Raw, c.Sticker, a)
				}
				validateFaceCue(&is, lang, c, m)
				continue
			}
			shape = append(shape, c.Sticker+":"+c.Effect)
			if c.Sticker == AllTarget && c.Effect == LiveEffect {
				is.errorf("%s: cue %s: live animations play on one sticker at a time; name it", lang, c.Raw)
				continue
			}
			if c.Sticker != AllTarget && !inStory[c.Sticker] {
				is.errorf("%s: cue %s targets %q, which is neither featured nor supporting", lang, c.Raw, c.Sticker)
			}
			if c.Effect == LiveEffect {
				if !c.Resume {
					liveCues++
				}
				validateLiveCue(&is, lang, c, m)
				anim, _ := m.ResolveAnimation(c.Sticker, c.Animation)
				if len(anim.Place) > 0 && !c.Resume && !slices.Contains(anim.Place, place[c.Sticker]) {
					is.errorf("%s: cue %s: %s's %s happens only on the %s, and the story has taken it elsewhere — take it back first a few words before ({%s:go to %s})", lang, c.Raw, c.Sticker, anim.ID, strings.Join(anim.Place, " or "), c.Sticker, anim.Place[0])
				}
				if anim.Perched && !c.Resume && aloft[c.Sticker] {
					is.errorf("%s: cue %s: %s is up in the air, and its %s needs somewhere to sit — land it first a few words before ({%s:go on flower}, {%s:go to meadow}, {%s:go under mushroom})", lang, c.Raw, c.Sticker, anim.ID, c.Sticker, c.Sticker, c.Sticker)
				}
				holding, isHeld := held[c.Sticker]
				switch {
				case c.Resume && !isHeld:
					is.errorf("%s: cue %s: nothing to resume — %s is not held (cue {%s:%s %s} first)", lang, c.Raw, c.Sticker, c.Sticker, LiveEffect, LiveHold)
				case c.Resume && anim.ID != "" && holding != anim.ID:
					is.errorf("%s: cue %s: %s holds its %s, not %s", lang, c.Raw, c.Sticker, holding, anim.ID)
				case c.Resume:
					delete(held, c.Sticker)
				case isHeld:
					is.errorf("%s: cue %s: %s is still held in its %s; {%s:%s %s} it first", lang, c.Raw, c.Sticker, holding, c.Sticker, LiveEffect, LiveResume)
				case c.Hold:
					held[c.Sticker] = anim.ID
				}
				continue
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
		validateEntrances(&is, lang, s, nar, enterAt, m)
		if stage := len(cues) - canvasCues - enterCues - (sounds - len(s.Sound)); stage > 0 && n > MaxWordsPerCue*stage {
			is.warnf("%s: %d cues on the stickers for %d words — the stage sits still too long; give most sentences a beat (a reaction, a face, everyone at once), about one cue per %d words", lang, stage, n, MaxWordsPerCue)
		}
		if faceCues == 0 && len(m.Expressions) > 0 {
			is.warnf("%s: no face changes — cue {sticker:face happy|sad|sleeping|surprised|normal} (or {%s:face …}) where the feelings change", lang, AllTarget)
		}
		if liveCues > MaxLiveCues {
			is.warnf("%s: %d live animations; they are the characters' big moments — at most %d per story", lang, liveCues, MaxLiveCues)
		}
		if canvasCues > MaxCanvasCues {
			is.warnf("%s: %d canvas cues; keep it to the %d biggest changes of weather or light", lang, canvasCues, MaxCanvasCues)
		}
		validateCanvasMentions(&is, lang, nar, m, cat, inStory)
		validatePlaceMentions(&is, lang, nar, m, inStory)
		if canvasCues > 0 && canvasCues == len(cues) {
			is.warnf("%s: only canvas cues — the stickers should react too", lang)
		}
		if sounds > MaxSounds {
			is.warnf("%s: %d sound effects; keep them to %d so they stay special", lang, sounds, MaxSounds)
		}
		if stickerCues := len(cues) - canvasCues - enterCues - (sounds - len(s.Sound)); stickerCues == 0 {
			is.errorf("%s: no sticker effect cues (at least one required)", lang)
		}
		validateLines(&is, lang, nar, inStory)
		for _, l := range nar.Lines {
			shape = append(shape, l.Speaker+":"+SaysEffect)
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

// validateSounds checks the story's sounds table.
func validateSounds(is *Issues, s *Story) {
	for id, spec := range s.Sounds {
		if !idPattern.MatchString(id) {
			is.errorf("sounds: id %q must be lowercase kebab-case", id)
		}
		if strings.TrimSpace(spec.Prompt) == "" {
			is.errorf("sounds: %q needs a prompt describing the sound", id)
		}
		if spec.Seconds != 0 && (spec.Seconds < MinSoundSeconds || spec.Seconds > MaxSoundSeconds) {
			is.errorf("sounds: %q lasts %g s; the range is %g–%g", id, spec.Seconds, MinSoundSeconds, MaxSoundSeconds)
		}
		if spec.Loop && spec.Seconds != 0 && spec.Seconds < 5 {
			is.warnf("sounds: %q loops but lasts only %g s — a bed usually runs 10 s or more", id, spec.Seconds)
		}
	}
}

// validateSoundCue checks an {sfx:…} cue against the sounds table and its
// place in the text: a solo sound pauses the narration, so it belongs
// between sentences.
func validateSoundCue(is *Issues, lang string, c Cue, s *Story, nar Narration) {
	spec, ok := s.Sounds[c.Effect]
	if !ok {
		is.errorf("%s: cue %s: no sound %q in the story's sounds table", lang, c.Raw, c.Effect)
		return
	}
	if c.Repeat > 0 || c.Loop || c.Hold || c.Color != "" || c.Duration > 0 || c.Intensity != 0 {
		is.errorf("%s: cue %s: a sound cue takes only solo", lang, c.Raw)
	}
	if c.Solo {
		if spec.Loop {
			is.errorf("%s: cue %s: a looping ambience cannot play solo", lang, c.Raw)
		}
		if c.WordIndex > 0 && c.WordIndex < len(nar.Words) {
			if prev := nar.Words[c.WordIndex-1]; !strings.ContainsRune(".!?…。！？」』", lastRune(prev)) {
				is.warnf("%s: cue %s pauses the narration mid-sentence (after %q); put solo sounds between sentences", lang, c.Raw, prev)
			}
		}
		if spec.EffectiveSeconds() > 4 {
			is.warnf("%s: cue %s pauses the story for %g s — long for a four-year-old", lang, c.Raw, spec.EffectiveSeconds())
		}
	}
}

// lastRune returns the final rune of s (an ellipsis is one rune, three bytes).
func lastRune(s string) rune {
	r, _ := utf8.DecodeLastRuneInString(s)
	return r
}

// Limits on character lines ({x:says}).
const (
	// MaxLines is how many lines a story gives its characters' voices
	// before the narrator stops being the one telling it (warning).
	MaxLines = 6
	// MaxLineWords keeps a line a line, not a speech (warning).
	MaxLineWords = 25
	// MaxVoicedChars is the most a story with character lines may hold in
	// one language, tags included: it is read in one multi-voice take, and
	// ElevenLabs keeps those reliable up to 2,000 characters.
	MaxVoicedChars = 2000
)

// validateLines checks the lines read in a character's voice: by someone
// in the story who is on stage, short, not split by a solo sound, and few
// enough — the narrator still tells the story.
func validateLines(is *Issues, lang string, nar Narration, inStory map[string]bool) {
	if len(nar.Lines) == 0 {
		return
	}
	if len(nar.Lines) > MaxLines {
		is.warnf("%s: %d character lines; the narrator tells the story — keep it to %d", lang, len(nar.Lines), MaxLines)
	}
	if text, _ := nar.Spoken(0, len(nar.Words)); len([]rune(text)) > MaxVoicedChars {
		is.errorf("%s: a story with character lines is read in one multi-voice take of at most %d characters; this one has %d", lang, MaxVoicedChars, len([]rune(text)))
	}
	for _, l := range nar.Lines {
		if !inStory[l.Speaker] {
			is.errorf("%s: cue %s: %s is neither featured nor supporting", lang, l.Raw, l.Speaker)
			continue
		}
		for _, c := range nar.Cues {
			if c.Sticker == l.Speaker && c.Effect == EnterEffect && c.WordIndex > l.From {
				is.warnf("%s: cue %s: %s speaks before it enters — name it and bring it in first", lang, l.Raw, l.Speaker)
			}
			if c.Sound && c.Solo && c.WordIndex > l.From && c.WordIndex < l.To {
				is.errorf("%s: cue %s: a solo sound inside %s's line; put it before or after the line", lang, c.Raw, l.Speaker)
			}
		}
		if n := CountWords(lang, Narration{Words: nar.Words[l.From:l.To]}.Plain()); n > MaxLineWords {
			is.warnf("%s: cue %s: %s's line is %d words; keep a character's line under %d", lang, l.Raw, l.Speaker, n, MaxLineWords)
		}
	}
}

// validateTags checks a language's audio tags: few, and never stacked.
func validateTags(is *Issues, lang string, nar Narration) {
	if len(nar.Tags) > MaxAudioTags {
		is.warnf("%s: %d audio tags; a few well-placed ones read as performance, more read as a tic (max %d)", lang, len(nar.Tags), MaxAudioTags)
	}
	experimental := 0
	for i, t := range nar.Tags {
		if tag, _ := LookupAudioTag(t.Name); tag.Experimental {
			experimental++
		}
		if strings.EqualFold(t.Name, "long pause") {
			is.warnf("%s: %s: no long silences; a short pause is fine, but the narration never stops for the child to guess or wait", lang, t.Raw)
		}
		if i > 0 && nar.Tags[i-1].WordIndex == t.WordIndex && !isPause(t.Name) && !isPause(nar.Tags[i-1].Name) {
			is.warnf("%s: tags %s and %s stacked on one word; one direction at a time", lang, nar.Tags[i-1].Raw, t.Raw)
		}
	}
	if experimental > 1 {
		is.warnf("%s: %d experimental audio tags ([yawns], [sings]); they are less reliable, use at most one", lang, experimental)
	}
}

// isPause reports whether a tag is a silence, which may sit beside a
// direction ([long pause] [whispers]) without stacking two.
func isPause(name string) bool {
	t, _ := LookupAudioTag(name)
	return t.Kind == "pause"
}

// canvasWords are the words that put a canvas effect's weather or light
// into a story, by effect and language (primary subtag). Only words that
// describe the scene itself: a story that says them should show it.
var canvasWords = map[string]map[string]*regexp.Regexp{
	"fog":           {"en": regexp.MustCompile(`\b(fog|foggy|mist|misty)\b`), "es": regexp.MustCompile(`\b(niebla|bruma)\b`)},
	"rain":          {"en": regexp.MustCompile(`\b(rain|raining|rained|rainy|drizzle|pitter-patter)\b`), "es": regexp.MustCompile(`\b(lluvia|llueve|llover|lloviendo|llovió|chispear)\b`)},
	"snow":          {"en": regexp.MustCompile(`\b(snow|snowing|snowflakes?)\b`), "es": regexp.MustCompile(`\b(nieve|nevando|nevar|nevó|copos?)\b`)},
	"rainbow":       {"en": regexp.MustCompile(`\brainbow\b`), "es": regexp.MustCompile(`\barcoíris\b`)},
	"night":         {"en": regexp.MustCompile(`\b(moon|moonlight)\b`), "es": regexp.MustCompile(`\bluna\b`)},
	"sunset":        {"en": regexp.MustCompile(`\b(sunset|sun (went|goes|had gone|is going) down)\b`), "es": regexp.MustCompile(`\b(atardecer|sol se (puso|ponía|pone|esconde)|sol ya se había puesto)\b`)},
	"clouds":        {"en": regexp.MustCompile(`\b(clouds?|cloudy)\b`), "es": regexp.MustCompile(`\b(nubes?|nublad[oa])\b`)},
	"wind":          {"en": regexp.MustCompile(`\b(wind|windy|gust)\b`), "es": regexp.MustCompile(`\b(viento|ráfaga)\b`)},
	"fireflies":     {"en": regexp.MustCompile(`\bfireflies\b`), "es": regexp.MustCompile(`\bluciérnagas\b`)},
	"leaves":        {"en": regexp.MustCompile(`\b(autumn|leaves (fell|fall|came down|came tumbling))\b`), "es": regexp.MustCompile(`\botoño\b`)},
	"confetti":      {"en": regexp.MustCompile(`\b(party|confetti)\b`), "es": regexp.MustCompile(`\b(fiesta|confeti)\b`)},
	"bubbles":       {"en": regexp.MustCompile(`\bbubbles\b`), "es": regexp.MustCompile(`\bburbujas\b`)},
	"shootingstars": {"en": regexp.MustCompile(`\bshooting stars?\b`), "es": regexp.MustCompile(`\bestrellas? fugac?(es|z)\b`)},
	"comet":         {"en": regexp.MustCompile(`\bcomets?\b`), "es": regexp.MustCompile(`\bcometas?\b`)},
	"nightfall":     {"en": regexp.MustCompile(`\b(nightfall|night (fell|falls|came|was falling)|(long|lunar) night)\b`), "es": regexp.MustCompile(`\b(anocheció|anochecer|(cayó|caía|llegó) la noche|noche lunar|larga noche)\b`)},
	"daybreak":      {"en": regexp.MustCompile(`\b(daybreak|sunrise|dawn|the sun (rose|came up|comes up|rises|was rising))\b`), "es": regexp.MustCompile(`\b(amanecer|amaneció|amanece|(salió|sale|salía) el sol)\b`)},
	"eclipse":       {"en": regexp.MustCompile(`\beclipse\b`), "es": regexp.MustCompile(`\beclipse\b`)},
	"milkyway":      {"en": regexp.MustCompile(`\bmilky way\b`), "es": regexp.MustCompile(`\bvía láctea\b`)},
	"dust":          {"en": regexp.MustCompile(`\b(cloud of dust|dust cloud|dust (flew|sprayed|sprays|rose|billowed))\b`), "es": regexp.MustCompile(`\b(nube de polvo|polvareda)\b`)},
	"floodlights":   {"en": regexp.MustCompile(`\bfloodlights?\b`), "es": regexp.MustCompile(`\b(focos|reflectores)\b`)},
}

// The canvas words of the languages added later: Japanese and Chinese
// with no word boundaries (none between their words).
func init() {
	more := map[string]map[string]string{
		"fog":           {"de": `\b(nebel|neblig|dunst)\b`, "fr": `\b(brouillard|brume)\b`, "it": `\b(nebbia|foschia)\b`, "ja": `(霧)`, "zh": `(霧|薄霧)`},
		"rain":          {"de": `\b(regen|regnet|regnete|nieselregen)\b`, "fr": `\b(pluie|pleut|pleuvait|pleuvoir|bruine)\b`, "it": `\b(pioggia|piove|pioveva|piovere|pioggerella)\b`, "ja": `(雨)`, "zh": `(雨)`},
		"snow":          {"de": `\b(schnee|schneit|schneite|schneeflocken?)\b`, "fr": `\b(neige|neigeait|flocons?)\b`, "it": `\b(neve|nevica|nevicava|fiocchi)\b`, "ja": `(雪)`, "zh": `(雪)`},
		"rainbow":       {"de": `\bregenbogen\b`, "fr": `\barc-en-ciel\b`, "it": `\barcobaleno\b`, "ja": `(虹|にじ)`, "zh": `(彩虹)`},
		"night":         {"de": `\b(mond|mondschein)\b`, "fr": `\b(lune|clair de lune)\b`, "it": `\b(luna|chiaro di luna)\b`, "ja": `(月|お月さま)`, "zh": `(月亮|月光)`},
		"sunset":        {"de": `\b(sonnenuntergang|sonne ging unter)\b`, "fr": `\b(coucher du soleil|soleil se couch)`, "it": `\b(tramonto)\b`, "ja": `(夕焼け|夕日|ゆうひ|ゆうやけ)`, "zh": `(夕陽|日落|黃昏)`},
		"clouds":        {"de": `\b(wolken?|wolkig|bewölkt)\b`, "fr": `\b(nuages?|nuageux)\b`, "it": `\b(nuvol[ae]|nuvoloso)\b`, "ja": `(雲)`, "zh": `(雲)`},
		"wind":          {"de": `\b(wind|windig|windstoß)\b`, "fr": `\b(vent|venteux|rafale)\b`, "it": `\b(vento|ventoso|raffica)\b`, "ja": `(風)`, "zh": `(大風|微風|颳風|刮風|吹風|風吹|起風|一陣風|風好大)`},
		"fireflies":     {"de": `\bglühwürmchen\b`, "fr": `\blucioles\b`, "it": `\blucciole\b`, "ja": `(ほたる|ホタル|蛍)`, "zh": `(螢火蟲)`},
		"leaves":        {"de": `\bherbst\b`, "fr": `\bautomne\b`, "it": `\bautunno\b`, "ja": `(秋)`, "zh": `(秋天)`},
		"confetti":      {"de": `\b(party|konfetti)\b`, "fr": `\b(fête|confettis)\b`, "it": `\b(festa|coriandoli)\b`, "ja": `(パーティー|紙吹雪)`, "zh": `(派對|彩紙)`},
		"bubbles":       {"de": `\bseifenblasen\b`, "fr": `\bbulles\b`, "it": `\bbolle\b`, "ja": `(しゃぼん玉|シャボン玉)`, "zh": `(泡泡)`},
		"shootingstars": {"de": `\bsternschnuppen?\b`, "fr": `\bétoiles? filantes?\b`, "it": `\bstelle? cadent[ei]\b`, "ja": `(流れ星|ながれぼし)`, "zh": `(流星)`},
	}
	for effect, byLang := range more {
		for lang, pattern := range byLang {
			canvasWords[effect][lang] = regexp.MustCompile(pattern)
		}
	}
	// \b only knows ASCII letters (vent in éventé would count): word
	// boundaries that know every letter, for every spaced language.
	for _, byLang := range canvasWords {
		for lang, re := range byLang {
			byLang[lang] = regexp.MustCompile(strings.ReplaceAll(re.String(), `\b`, `(?:^|$|[^\p{L}\p{N}])`))
		}
	}
}

// validateCanvasMentions warns when the words put weather or light into the
// scene that a canvas effect for the pack's setting can show, and the story
// never cues it: the child should see the snow the narrator talks about.
// A word that names one of the story's stickers (a comet sticker) is that
// sticker, not the weather.
func validateCanvasMentions(is *Issues, lang string, nar Narration, m Manifest, cat *Catalog, inStory map[string]bool) {
	cued := map[string]bool{}
	running := map[string]bool{}
	for _, c := range nar.Cues {
		switch {
		case c.Canvas && c.Stop && !running[c.Effect]:
			is.errorf("%s: cue %s: no %s is running to stop; start it first ({%s:%s})", lang, c.Raw, c.Effect, CanvasTarget, c.Effect)
		case c.Canvas && c.Stop:
			running[c.Effect] = false
		case c.Canvas:
			running[c.Effect] = true
			cued[c.Effect] = true
		}
	}
	plain := strings.ToLower(nar.Plain())
	names := make([]string, 0, len(canvasWords))
	for name := range canvasWords {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		e, known := cat.Canvas[name]
		if !known || cued[name] || !e.SuitsSetting(m.EffectiveSetting()) {
			continue
		}
		if re := canvasWords[name][primarySubtag(lang)]; re != nil {
			namesSticker := false
			for id := range inStory {
				namesSticker = namesSticker || re.MatchString(strings.ToLower(m.Names[id][lang]))
			}
			word := strings.TrimFunc(re.FindString(plain), func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsNumber(r) })
			if word != "" && !namesSticker {
				is.warnf("%s: the text mentions %q but never cues {%s:%s} — cue it a beat before those words", lang, word, CanvasTarget, name)
			}
		}
	}
}

// validateEntrances checks that every featured and supporting sticker
// enters exactly once, on the word that first names it: an entrance after
// the first mention leaves the narrator talking about a sticker that is
// not there yet, and a cue before it plays on a sticker that has not
// arrived (loops and faces are fine: they carry on once it is in).
func validateEntrances(is *Issues, lang string, s *Story, nar Narration, enterAt map[string]int, m Manifest) {
	cast := append(append([]string(nil), s.Featured...), s.Supporting...)
	for _, id := range cast {
		at, ok := enterAt[id]
		if !ok {
			is.errorf("%s: %s never enters — put {%s:%s} right before the word that first names it", lang, id, id, EnterEffect)
			continue
		}
		if first := firstMention(nar.Words, id, lang, m); first >= 0 && first < at {
			is.warnf("%s: {%s:%s} fires on word %d (%q) but %s is named earlier, at word %d (%q) — move it to the first mention", lang, id, EnterEffect, at+1, nar.Words[at], id, first+1, nar.Words[first])
		}
		for _, c := range nar.Cues {
			if c.Sticker != id || c.WordIndex >= at || c.Loop || c.Effect == FaceEffect || c.Effect == EnterEffect {
				continue
			}
			is.warnf("%s: cue %s fires before %s enters — a child who has not placed it would not see it; cue it on or after the entrance", lang, c.Raw, id)
		}
	}
	if len(m.Stages) > 0 {
		for _, id := range cast {
			if _, ok := m.Stages[id]; !ok {
				is.warnf("%s: sticker %q has no stage in the manifest; it will grow in the default area", lang, id)
			}
		}
	}
}

// firstMention returns the index of the first word that names sticker id
// in lang (its manifest name, case- and punctuation-insensitive, a
// possessive counting), or -1. A name that is the start of a longer sticker
// name found at the same spot ("Pájaro" in "Pájaro carpintero") does not
// count.
func firstMention(words []string, id, lang string, m Manifest) int {
	tokens := func(name string) []string {
		var out []string
		for _, w := range strings.Fields(name) {
			out = append(out, mentionWord(w))
		}
		return out
	}
	want := tokens(m.Names[id][lang])
	if len(want) == 0 {
		return -1
	}
	if name := strings.Join(want, ""); cjkName(name) {
		// Japanese and Chinese run a name on into the words around it.
		for i, w := range words {
			if !strings.Contains(w, name) {
				continue
			}
			shadowed := false
			for other, names := range m.Names {
				longer := strings.Join(tokens(names[lang]), "")
				shadowed = shadowed || other != id && len(longer) > len(name) && strings.Contains(longer, name) && strings.Contains(w, longer)
			}
			if !shadowed {
				return i
			}
		}
		return -1
	}
	var longer [][]string
	for other, names := range m.Names {
		if other == id {
			continue
		}
		if t := tokens(names[lang]); len(t) > len(want) && strings.Join(t[:len(want)], " ") == strings.Join(want, " ") {
			longer = append(longer, t)
		}
	}
	matchAt := func(i int, t []string) bool {
		if i+len(t) > len(words) {
			return false
		}
		for k, w := range t {
			if !sameWord(lang, mentionWord(words[i+k]), w) {
				return false
			}
		}
		return true
	}
	for i := range words {
		if !matchAt(i, want) {
			continue
		}
		shadowed := false
		for _, t := range longer {
			shadowed = shadowed || matchAt(i, t)
		}
		if !shadowed {
			return i
		}
	}
	return -1
}

// splitSentences splits the words of Japanese or Chinese narration where a
// sentence ends inside one (their words run on between cues: 「蝸牛擠了進
// 去。池塘那邊，」 is one word, two sentences), cues kept on the piece that
// starts their word, so sentence by sentence checks see each sentence.
func splitSentences(nar Narration) Narration {
	var words []string
	first := make([]int, len(nar.Words)) // each word's first piece
	for i, w := range nar.Words {
		first[i] = len(words)
		runes := []rune(w)
		start := 0
		for k := 0; k < len(runes); k++ {
			if !strings.ContainsRune("。！？", runes[k]) {
				continue
			}
			// Closing quotes after the stop stay with their sentence.
			for k+1 < len(runes) && strings.ContainsRune("」』）", runes[k+1]) {
				k++
			}
			words = append(words, string(runes[start:k+1]))
			start = k + 1
		}
		if start < len(runes) || first[i] == len(words) {
			words = append(words, string(runes[start:]))
		}
	}
	if len(words) == len(nar.Words) {
		return nar
	}
	out := nar
	out.Words = words
	out.Cues = make([]Cue, len(nar.Cues))
	for i, c := range nar.Cues {
		if c.WordIndex < len(first) {
			c.WordIndex = first[c.WordIndex]
		}
		out.Cues[i] = c
	}
	return out
}

// cjkName reports a name written in Japanese or Chinese, matched inside
// the words around it rather than as whole words.
func cjkName(name string) bool {
	for _, r := range name {
		if wide(r) {
			return true
		}
	}
	return false
}

// sameWord reports a word of the text that is target (both normalised by
// mentionWord) or, in German, one of its declined forms (des Rehs, den
// Hasen, dem Waschbären, des Teiches).
func sameWord(lang, word, target string) bool {
	if word == target {
		return true
	}
	if primarySubtag(lang) != "de" || !strings.HasPrefix(word, strings.TrimSuffix(target, "e")) {
		return false
	}
	for _, end := range []string{"s", "es", "n", "en", "e"} {
		if word == target+end || word == strings.TrimSuffix(target, "e")+end {
			return true
		}
	}
	return false
}

// mentionWord normalises a word for name matching: lower case, no
// surrounding punctuation, no possessive 's, no elided article or
// preposition in front (French l'eau, d'Ourson; Italian dell'acqua).
func mentionWord(w string) string {
	w = strings.ToLower(strings.TrimFunc(w, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsNumber(r) }))
	for _, suffix := range []string{"'s", "’s"} {
		w = strings.TrimSuffix(w, suffix)
	}
	if i := strings.LastIndexAny(w, "'’"); i > 0 && i <= 5 {
		_, size := utf8.DecodeRuneInString(w[i:])
		if rest := w[i+size:]; utf8.RuneCountInString(rest) >= 2 {
			w = rest
		}
	}
	return w
}

// validateFaceCue checks a {sticker:face expression} cue: an expression
// the sticker has (for all, one some sticker has; normal always), and
// nothing else set.
func validateFaceCue(is *Issues, lang string, c Cue, m Manifest) {
	switch {
	case c.Expression == "":
		is.errorf("%s: cue %s: name the expression ({%s:%s happy}, or normal to go back)", lang, c.Raw, c.Sticker, FaceEffect)
	case !m.HasExpression(c.Sticker, c.Expression):
		if c.Sticker == AllTarget {
			is.errorf("%s: cue %s: no sticker has the expression %q", lang, c.Raw, c.Expression)
		} else {
			is.errorf("%s: cue %s: sticker %q has no expression %q (it has %s)", lang, c.Raw, c.Sticker, c.Expression, strings.Join(append([]string{Normal}, m.Expressions[c.Sticker]...), ", "))
		}
	}
	if c.Repeat > 0 || c.Loop || c.Hold || c.Color != "" || c.Duration > 0 || c.Intensity != 0 {
		is.errorf("%s: cue %s: a face change takes no parameters (it lasts until the next one)", lang, c.Raw)
	}
}

// validateGoCue checks a {sticker:go …} cue: one sticker in the story
// that can move (it walks or flies: its stage entrance is hop or fly), on
// stage already (its entrance earlier), a kind, and a target — for to a
// sticker in the story (on stage already) or a feature of the pack, for on
// and under a sticker, none for away and back — and nothing else.
func validateGoCue(is *Issues, lang string, c Cue, m Manifest, inStory map[string]bool, enterAt map[string]int) {
	if c.Sticker == AllTarget {
		is.errorf("%s: cue %s: a move names one sticker", lang, c.Raw)
		return
	}
	if !inStory[c.Sticker] {
		is.errorf("%s: cue %s targets %q, which is neither featured nor supporting", lang, c.Raw, c.Sticker)
		return
	}
	if e, ok := m.Stages[c.Sticker]; ok && e != "hop" && e != "fly" {
		is.errorf("%s: cue %s: %s stays where it is (its stage entrance is %s); only walkers and flyers move", lang, c.Raw, c.Sticker, e)
	}
	if at, ok := enterAt[c.Sticker]; !ok || at > c.WordIndex {
		is.errorf("%s: cue %s: %s moves before it enters — put {%s:%s} on its first mention, before this", lang, c.Raw, c.Sticker, c.Sticker, EnterEffect)
	}
	switch c.GoKind {
	case GoTo, GoOn, GoUnder:
		_, feature := m.Features[c.Target]
		switch {
		case c.Target == "":
			is.errorf("%s: cue %s: go %s needs a target (a sticker%s)", lang, c.Raw, c.GoKind, map[bool]string{true: " or a place", false: ""}[c.GoKind == GoTo])
		case c.Target == c.Sticker:
			is.errorf("%s: cue %s: a sticker cannot go %s itself", lang, c.Raw, c.GoKind)
		case c.GoKind == GoTo && feature:
			// A place in the scene (the pond): always there.
		case !inStory[c.Target]:
			is.errorf("%s: cue %s: the target %q is neither featured nor supporting%s", lang, c.Raw, c.Target, map[bool]string{true: ", nor a place in the scene", false: ""}[c.GoKind == GoTo])
		default:
			if at, ok := enterAt[c.Target]; !ok || at > c.WordIndex {
				is.errorf("%s: cue %s: %s is not on stage yet — its {%s:%s} must come before this", lang, c.Raw, c.Target, c.Target, EnterEffect)
			}
		}
	case GoAway, GoBack:
		if c.Target != "" {
			is.errorf("%s: cue %s: go %s takes no target", lang, c.Raw, c.GoKind)
		}
	default:
		is.errorf("%s: cue %s: say where it goes — to, on, under, away or back ({fox:go to rabbit}, {bee:go on flower}, {fox:go away})", lang, c.Raw)
	}
	if c.Repeat > 0 || c.Loop || c.Hold || c.Color != "" || c.Duration > 0 || c.Intensity != 0 || c.Animation != "" {
		is.errorf("%s: cue %s: a move takes only where it goes and the way it goes (by …)", lang, c.Raw)
	}
	if _, place := m.Features[c.Target]; c.Another && (c.GoKind != GoTo || !place) {
		is.errorf("%s: cue %s: another is for going to a place (go to trunks another: on to the next tree)", lang, c.Raw)
	}
	if c.Toward != "" && c.GoKind != GoTo && c.GoKind != GoAway {
		is.errorf("%s: cue %s: left and right are for go to and go away (the way it goes across the screen)", lang, c.Raw)
	}
	validateBy(is, lang, c, m)
}

// validatePropGo checks a move to a prop another sticker holds out
// ({seagull:go to girl kite}): a flyer, to a sticker holding (paused, held
// is that action) an action that holds out that prop — the kite is only
// up there while the girl holds it.
func validatePropGo(is *Issues, lang string, c Cue, m Manifest, held string) {
	if _, place := m.Features[c.Target]; place {
		is.errorf("%s: cue %s: %s is a place; a prop is something a character holds out (go to girl kite)", lang, c.Raw, c.Target)
		return
	}
	if !m.fliesBy(c.Sticker, c.By) {
		is.errorf("%s: cue %s: only a flyer goes to %s's %s, up where it is held out", lang, c.Raw, c.Target, c.Prop)
	}
	var holders []string
	for _, a := range m.Animations[c.Target] {
		if slices.Contains(a.Props, c.Prop) {
			holders = append(holders, a.ID)
		}
	}
	switch {
	case len(holders) == 0:
		is.errorf("%s: cue %s: %s holds out no %s in any action", lang, c.Raw, c.Target, c.Prop)
	case !slices.Contains(holders, held):
		is.errorf("%s: cue %s: %s's %s is only out while %s holds its %s — {%s:%s %s %s} a few words before", lang, c.Raw, c.Target, c.Prop, c.Target, holders[0], c.Target, LiveEffect, holders[0], LiveHold)
	}
	if c.Toward != "" || c.Another {
		is.errorf("%s: cue %s: going to a prop takes no side and no another", lang, c.Raw)
	}
}

// validateBy checks the way an entrance or a move names (by fly): one of
// the sticker's moves. Its usual way needs no naming.
func validateBy(is *Issues, lang string, c Cue, m Manifest) {
	if c.By == "" || c.Sticker == AllTarget {
		return
	}
	moves := m.Moves[c.Sticker]
	var ids []string
	for _, a := range moves {
		if a.ID == c.By {
			if a.ID == moves[0].ID {
				is.warnf("%s: cue %s: %s is %s's usual way; drop the by", lang, c.Raw, c.By, c.Sticker)
			}
			return
		}
		ids = append(ids, a.ID)
	}
	is.errorf("%s: cue %s: %s has no move %q (its moves: %s)", lang, c.Raw, c.Sticker, c.By, strings.Join(ids, ", "))
}

// validatePlaceMentions warns when a sentence puts a character in a place
// of the scene ("Bird flew down onto a branch", "Frog hopped to the pond",
// "Mouse sat by the water") that no move of the story has taken it to: a
// visitor may come in there, but a sticker the child put in the middle of
// the meadow stays there unless a {bird:go to branches} takes it (and one
// that is there already stays put). Any walker or flyer can be at a place
// with an edge (the pond): the ones that do not go in stop at its edge.
func validatePlaceMentions(is *Issues, lang string, nar Narration, m Manifest, inStory map[string]bool) {
	if len(m.PlaceWords) == 0 {
		return
	}
	nar = splitSentences(nar)
	at := map[string]string{}   // where the story's moves have put each sticker
	with := map[string]string{} // whom a move has put it with (beside, on, under)
	canBe := func(id, place string) bool {
		if e := m.Stages[id]; e != "hop" && e != "fly" {
			return false
		}
		if m.Edges[place] || slices.Contains(m.LandsOn[id], place) {
			return true
		}
		for _, mv := range m.Moves[id] {
			if slices.Contains(mv.On, place) {
				return true
			}
		}
		return false
	}
	start := 0
	for end := range nar.Words {
		w := nar.Words[end]
		last := end == len(nar.Words)-1
		if !last && !strings.ContainsAny(strings.TrimRight(w, "»\"”“'’)」』）"), ".!?…。！？") {
			continue
		}
		words := nar.Words[start : end+1]
		mentioned := map[string]bool{}
		for _, c := range nar.Cues {
			if c.WordIndex < start || c.WordIndex > end || c.Sticker == "" || c.Sticker == AllTarget || !inStory[c.Sticker] {
				continue
			}
			mentioned[c.Sticker] = true
			if c.Effect == GoEffect {
				with[c.Sticker] = ""
				if _, place := m.Features[c.Target]; place && c.GoKind == GoTo {
					at[c.Sticker] = c.Target
				} else {
					at[c.Sticker] = ""
					if inStory[c.Target] {
						with[c.Sticker] = c.Target
					}
				}
			}
		}
		for id := range inStory {
			if firstMention(words, id, lang, m) >= 0 {
				mentioned[id] = true
			}
		}
		ids := make([]string, 0, len(mentioned))
		for id := range mentioned {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		// Words of a sticker's name are not its place (Étoile de mer is not
		// at the sea, nor 海龜 or 海星).
		inName := map[int]bool{}
		var names []string
		for _, byID := range m.Names {
			name := byID[lang]
			if cjkName(name) {
				names = append(names, name)
				continue
			}
			tokens := strings.Fields(name)
			for i := 0; len(tokens) > 1 && i+len(tokens) <= len(words); i++ {
				match := true
				for k, t := range tokens {
					match = match && sameWord(lang, mentionWord(words[i+k]), mentionWord(t))
				}
				for k := range tokens {
					inName[i+k] = inName[i+k] || match
				}
			}
		}
		// Japanese and Chinese place words sit inside the words: the longest
		// first, so a shorter one inside it (波 in 波打ち際) is not named too.
		type placeWord struct{ place, word string }
		var cjkWords []placeWord
		for place, byLang := range m.PlaceWords {
			for _, pw := range byLang[lang] {
				if cjkName(pw) {
					cjkWords = append(cjkWords, placeWord{place, pw})
				}
			}
		}
		slices.SortFunc(cjkWords, func(a, b placeWord) int { return cmp.Compare(len(b.word), len(a.word)) })
		cjkNamed := map[string]bool{}
		for i, word := range words {
			if inName[i] || len(cjkWords) == 0 {
				continue
			}
			bare := word
			for _, name := range names {
				bare = strings.ReplaceAll(bare, name, "\x00")
			}
			for _, pw := range cjkWords {
				if strings.Contains(bare, pw.word) {
					cjkNamed[pw.place] = true
					bare = strings.ReplaceAll(bare, pw.word, "\x00")
				}
			}
		}
		for place, byLang := range m.PlaceWords {
			named := cjkNamed[place]
			for i, word := range words {
				if named {
					break
				}
				if !inName[i] && slices.ContainsFunc(byLang[lang], func(pw string) bool { return sameWord(lang, mentionWord(word), pw) }) {
					named = true
				}
			}
			if !named {
				continue
			}
			// By someone there (Nico by his bucket on the sand), it is there too.
			there := func(id string) bool {
				t := with[id]
				return at[id] == place || t != "" && (at[t] == place || at[t] == "" && slices.Contains(m.LandsOn[t], place))
			}
			for _, id := range ids {
				if !there(id) && canBe(id, place) {
					snippet := strings.Join(words[:min(len(words), 9)], " ")
					is.warnf("%s: %q… puts %s at the %s, but no move takes it there — cue {%s:go to %s} (a sticker already there stays; one the child put elsewhere goes)", lang, snippet, id, place, id, place)
				}
			}
		}
		start = end + 1
	}
}

// validateLiveCue checks a {sticker:live} cue: the sticker has the live
// animation it asks for, hold/resume only on one with a pause frame, and
// nothing else is set.
func validateLiveCue(is *Issues, lang string, c Cue, m Manifest) {
	anim, err := m.ResolveAnimation(c.Sticker, c.Animation)
	if err != nil {
		is.errorf("%s: cue %s: %v", lang, c.Raw, err)
	}
	if c.Hold && c.Resume {
		is.errorf("%s: cue %s: hold or resume, not both", lang, c.Raw)
	} else if (c.Hold || c.Resume) && err == nil && anim.Pause == "" {
		is.errorf("%s: cue %s: %s's %s has no pause frame; play it whole ({%s:%s})", lang, c.Raw, c.Sticker, anim.ID, c.Sticker, LiveEffect)
	}
	if c.Repeat > 0 || c.Loop || c.Color != "" || c.Duration > 0 || c.Intensity != 0 {
		is.errorf("%s: cue %s: a live animation takes no parameters (only an animation id, and hold or resume)", lang, c.Raw)
	}
}

// flowing lists the canvas effects that blow a way, sorted.
func flowing(cat *Catalog) []string {
	var out []string
	for name, e := range cat.Canvas {
		if e.Flows() {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
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
		is.errorf("%s: cue %s: a canvas effect takes only an intensity and a duration (Ns), or stop", lang, c.Raw)
	}
	if c.Toward != "" && !e.Flows() {
		is.errorf("%s: cue %s: %s does not blow a way; only %s take left or right", lang, c.Raw, c.Effect, strings.Join(flowing(cat), " and "))
	}
	if c.Stop && (c.Duration > 0 || c.Intensity != 0 || c.Toward != "") {
		is.errorf("%s: cue %s: a stop takes nothing else; it ends the %s started before it", lang, c.Raw, c.Effect)
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
	// LiveUse counts, per sticker, the stories whose first language plays
	// one of its live animations; ActionUse the same per action
	// ("<sticker>.<id>"; "<sticker>." for a cue naming none);
	// LiveStories the stories that play any.
	LiveUse     map[string]int
	ActionUse   map[string]int
	LiveStories int
	// GoStories counts the stories that move a sticker ({fox:go …}).
	GoStories int
	// FaceUse counts the stories whose first language shows each
	// expression; FaceStories those with any face cue, AllStories those
	// with any cue on every sticker ({all:…}).
	FaceUse     map[string]int
	FaceStories int
	AllStories  int
	// LearningStories counts the stories that carry a piece of learning.
	LearningStories int
	// SoundStories / SoloStories count stories with sound effects, and with
	// solo sounds (the narration pausing for a sound); TagUse counts the
	// stories whose first language uses each audio tag.
	SoundStories int
	SoloStories  int
	TagUse       map[string]int
	Duplicate    []string // ids sharing a featured set with another story
	Errors       []string
	Warnings     []string
}

// Cover computes coverage and set-level issues.
func Cover(stories []*Story, m Manifest, expected int) Coverage {
	c := Coverage{Stories: len(stories), Featured: map[string]int{}, Used: map[string]int{}, EffectUse: map[string]int{}, TagUse: map[string]int{}, LiveUse: map[string]int{}, ActionUse: map[string]int{}, FaceUse: map[string]int{}}
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
		if strings.TrimSpace(s.Learning) != "" {
			c.LearningStories++
		}
		if len(m.Languages) > 0 {
			nar, _ := Parse(s.Languages[m.Languages[0]].Text)
			seen := map[string]bool{}
			usesCanvas, usesSound, usesSolo, usesLive, usesFace, usesAll := false, len(s.Sound) > 0, false, false, false, false
			usesGo := false
			for _, cue := range nar.Cues {
				key := cue.Effect
				usesAll = usesAll || cue.Sticker == AllTarget
				switch {
				case cue.Effect == EnterEffect && !cue.Canvas && !cue.Sound:
					continue
				case cue.Effect == GoEffect && !cue.Canvas && !cue.Sound:
					usesGo = true
					continue
				case cue.Effect == FaceEffect && !cue.Canvas && !cue.Sound:
					usesFace = true
					if !seen["face:"+cue.Expression] {
						seen["face:"+cue.Expression] = true
						c.FaceUse[cue.Expression]++
					}
					continue
				case cue.Effect == LiveEffect && !cue.Canvas && !cue.Sound:
					usesLive = true
					if !seen["live:"+cue.Sticker] {
						seen["live:"+cue.Sticker] = true
						c.LiveUse[cue.Sticker]++
					}
					if action := cue.Sticker + "." + cue.Animation; !seen["action:"+action] {
						seen["action:"+action] = true
						c.ActionUse[action]++
					}
					continue
				case cue.Sound:
					usesSound = true
					usesSolo = usesSolo || cue.Solo
					continue
				case cue.Canvas && cue.Stop:
					continue
				case cue.Canvas:
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
			if usesGo {
				c.GoStories++
			}
			if usesLive {
				c.LiveStories++
			}
			if usesFace {
				c.FaceStories++
			}
			if usesAll {
				c.AllStories++
			}
			if usesSound {
				c.SoundStories++
			}
			if usesSolo {
				c.SoloStories++
			}
			seenTags := map[string]bool{}
			for _, t := range nar.Tags {
				if !seenTags[t.Name] {
					seenTags[t.Name] = true
					c.TagUse[t.Name]++
				}
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
	for _, st := range m.Stickers {
		if len(m.Animations[st]) > 0 && c.Featured[st] >= MinFeaturedPer && c.LiveUse[st] < MinLivePer {
			c.Warnings = append(c.Warnings, fmt.Sprintf("sticker %q's actions play in %d stories; aim for at least %d ({%s:%s %s})", st, c.LiveUse[st], MinLivePer, st, LiveEffect, m.Animations[st][0].ID))
		}
	}
	if c.Fallbacks < MinFallbacks {
		c.Warnings = append(c.Warnings, fmt.Sprintf("%d fallback stories (no featured stickers); want ≥ %d", c.Fallbacks, MinFallbacks))
	}
	if n := len(stories); n >= 10 {
		share := float64(c.LearningStories) / float64(n)
		if share < MinLearningShare || share > MaxLearningShare {
			c.Warnings = append(c.Warnings, fmt.Sprintf("%d of %d stories carry a piece of learning (%.0f%%); aim for about 40%% (%.0f–%.0f%%)", c.LearningStories, n, share*100, MinLearningShare*100, MaxLearningShare*100))
		}
	}
	if expected > 0 && len(stories) != expected {
		c.Warnings = append(c.Warnings, fmt.Sprintf("%d stories; the set should have %d", len(stories), expected))
	}
	return c
}
