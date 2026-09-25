// Package render turns an authored story (tools/author/stories, FORMAT.md)
// plus ElevenLabs character timings into the pack's per-language artefacts:
// the effect trigger sidecar (docs/effects.md) and the placement of sound
// effects on the narration timeline. A narration may be synthesised in
// several segments (the narrator pauses for a solo sound); each segment's
// timeline is built on its own and the pieces are assembled on one clock.
package render

import (
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"unicode"

	"stickerstories/tools/internal/effects"
	"stickerstories/tools/internal/elevenlabs"
	"stickerstories/tools/internal/story"
)

// Word is one narration word with its character span in the plain text.
type Word struct {
	Text  string
	Start int // byte offset in plain text
	End   int
}

// Words splits plain text into words with byte offsets (same tokenisation as
// story.ParseCues: whitespace-separated fields).
func Words(plain string) []Word {
	var out []Word
	inWord := false
	start := 0
	for i, r := range plain {
		if unicode.IsSpace(r) {
			if inWord {
				out = append(out, Word{plain[start:i], start, i})
				inWord = false
			}
		} else if !inWord {
			inWord, start = true, i
		}
	}
	if inWord {
		out = append(out, Word{plain[start:], start, len(plain)})
	}
	return out
}

// Timeline maps spoken-word indices to narration seconds using the
// character alignment ElevenLabs returns for exactly the text it was sent.
type Timeline struct {
	Words  []Word
	starts []float64 // per word, seconds
	ends   []float64
	Length float64 // last character end
}

// NewTimeline builds word timings for one synthesised text. wordStarts are
// the byte offsets of the spoken words within text (story.Narration.Spoken
// gives both; audio tags in the text are not words). The alignment's
// characters should be the runes of text in order; if they diverge (the
// API normalises text), the alignment is walked by rune index and lengths
// are reconciled proportionally, which keeps cues close enough for a 0.5 s
// effect.
func NewTimeline(text string, wordStarts []int, al *elevenlabs.Alignment) (*Timeline, error) {
	if al == nil || len(al.Starts) == 0 {
		return nil, fmt.Errorf("no alignment returned")
	}
	words := make([]Word, 0, len(wordStarts))
	for _, start := range wordStarts {
		end := start
		for end < len(text) && !unicode.IsSpace(rune(text[end])) {
			end++
		}
		words = append(words, Word{text[start:end], start, end})
	}
	plain := text
	tl := &Timeline{Words: words, starts: make([]float64, len(words)), ends: make([]float64, len(words))}
	runes := []rune(plain)
	n := len(al.Starts)
	if len(al.Ends) < n {
		n = len(al.Ends)
	}
	// Map byte offsets → rune index → alignment index (scaled when lengths differ).
	scale := 1.0
	if len(runes) > 0 && n != len(runes) {
		scale = float64(n) / float64(len(runes))
	}
	byteToRune := make(map[int]int, len(runes)+1)
	ri := 0
	for bi := range plain {
		byteToRune[bi] = ri
		ri++
	}
	byteToRune[len(plain)] = ri
	idx := func(b int) int {
		i := int(float64(byteToRune[b]) * scale)
		if i >= n {
			i = n - 1
		}
		if i < 0 {
			i = 0
		}
		return i
	}
	for i, w := range words {
		tl.starts[i] = al.Starts[idx(w.Start)]
		tl.ends[i] = al.Ends[idx(w.End-1)]
	}
	tl.Length = al.Ends[n-1]
	return tl, nil
}

// NewPlainTimeline builds word timings for a plain text with no tags,
// tokenised on whitespace (the legacy single-request path and tests).
func NewPlainTimeline(plain string, al *elevenlabs.Alignment) (*Timeline, error) {
	var starts []int
	for _, w := range Words(plain) {
		starts = append(starts, w.Start)
	}
	return NewTimeline(plain, starts, al)
}

// Shifted returns the timeline moved later by seconds (a segment placed
// after a lead-in or a solo sound).
func (t *Timeline) Shifted(seconds float64) *Timeline {
	out := &Timeline{Words: t.Words, starts: make([]float64, len(t.starts)), ends: make([]float64, len(t.ends)), Length: t.Length + seconds}
	for i := range t.starts {
		out.starts[i] = t.starts[i] + seconds
		out.ends[i] = t.ends[i] + seconds
	}
	return out
}

// Assemble concatenates segment timelines that are already on one clock
// (Shifted to their offsets) into the narration's timeline.
func Assemble(parts ...*Timeline) *Timeline {
	out := &Timeline{}
	for _, p := range parts {
		if p == nil {
			continue
		}
		out.Words = append(out.Words, p.Words...)
		out.starts = append(out.starts, p.starts...)
		out.ends = append(out.ends, p.ends...)
		out.Length = math.Max(out.Length, p.Length)
	}
	return out
}

// At returns the start time of word i (clamped).
func (t *Timeline) At(i int) float64 {
	if len(t.starts) == 0 {
		return 0
	}
	if i < 0 {
		i = 0
	}
	if i >= len(t.starts) {
		i = len(t.starts) - 1
	}
	return t.starts[i]
}

// Find returns the index of the first word equal to cue ignoring case and
// surrounding punctuation, or -1.
func (t *Timeline) Find(cue string) int {
	want := normalizeWord(cue)
	for i, w := range t.Words {
		if normalizeWord(w.Text) == want {
			return i
		}
	}
	// Fall back to a prefix match (cue "Pitter" vs word "Pitter-patter,").
	for i, w := range t.Words {
		if strings.HasPrefix(normalizeWord(w.Text), want) {
			return i
		}
	}
	return -1
}

func normalizeWord(s string) string {
	return strings.ToLower(strings.TrimFunc(s, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsNumber(r) }))
}

// Trigger is one entry of the effects sidecar: a sticker trigger, or a
// canvas trigger (no sticker; intensity and duration only).
type Trigger struct {
	At         float64 `json:"at"`
	Cue        string  `json:"cue,omitempty"`
	Sticker    string  `json:"sticker,omitempty"`
	Effect     string  `json:"effect,omitempty"`
	Animation  string  `json:"animation,omitempty"`  // a live animation: no effect
	Mode       string  `json:"mode,omitempty"`       // a live animation's hold or resume
	Expression string  `json:"expression,omitempty"` // a face change: no effect
	Enter      bool    `json:"enter,omitempty"`      // an entrance: no effect
	Go         string  `json:"go,omitempty"`         // a move: no effect
	Target     string  `json:"target,omitempty"`     // a move's target
	By         string  `json:"by,omitempty"`         // the move an entrance or a move goes by
	Repeat     any     `json:"repeat,omitempty"`     // int or "loop"
	Duration   float64 `json:"duration,omitempty"`
	Intensity  float64 `json:"intensity,omitempty"`
	Color      string  `json:"color,omitempty"`
	Hold       bool    `json:"hold,omitempty"`
}

// Sidecar is the effects trigger file.
type Sidecar struct {
	Schema   int       `json:"schema"`
	Triggers []Trigger `json:"triggers"`
}

// Triggers converts parsed cues to sidecar triggers on the timeline. Cues
// firing at the story start (word 0) are pinned to 0.0. A canvas cue
// becomes a trigger with no sticker and none of the sticker-only keys; a
// live cue a trigger naming the animation (resolved against the pack, so
// {bear:live} names the bear's only one) and no effect; sound cues are not
// triggers (they are mixed into the audio) and are skipped. An entrance
// cue becomes {at, sticker, enter: true}.
func Triggers(cues []story.Cue, tl *Timeline, pack story.Manifest) ([]Trigger, error) {
	out := make([]Trigger, 0, len(cues))
	for _, c := range cues {
		if c.Sound {
			continue
		}
		at := tl.At(c.WordIndex)
		if c.WordIndex == 0 {
			at = 0
		}
		at = round(at)
		if c.Effect == story.EnterEffect && !c.Canvas {
			t := Trigger{At: at, Sticker: c.Sticker, Enter: true, By: c.By}
			if c.WordIndex < len(tl.Words) {
				t.Cue = normalizeWord(tl.Words[c.WordIndex].Text)
			}
			out = append(out, t)
			continue
		}
		if c.Effect == story.GoEffect && !c.Canvas {
			t := Trigger{At: at, Sticker: c.Sticker, Go: c.GoKind, Target: c.Target, By: c.By}
			if c.WordIndex < len(tl.Words) {
				t.Cue = normalizeWord(tl.Words[c.WordIndex].Text)
			}
			out = append(out, t)
			continue
		}
		if c.Effect == story.FaceEffect && !c.Canvas {
			t := Trigger{At: at, Sticker: c.Sticker, Expression: c.Expression}
			if c.WordIndex < len(tl.Words) {
				t.Cue = normalizeWord(tl.Words[c.WordIndex].Text)
			}
			out = append(out, t)
			continue
		}
		if c.Effect == story.LiveEffect && !c.Canvas {
			anim, err := pack.ResolveAnimation(c.Sticker, c.Animation)
			if err != nil {
				return nil, fmt.Errorf("cue %s: %w", c.Raw, err)
			}
			t := Trigger{At: at, Sticker: c.Sticker, Animation: anim.ID}
			switch {
			case c.Hold:
				t.Mode = story.LiveHold
			case c.Resume:
				t.Mode = story.LiveResume
			}
			if c.WordIndex < len(tl.Words) {
				t.Cue = normalizeWord(tl.Words[c.WordIndex].Text)
			}
			out = append(out, t)
			continue
		}
		t := Trigger{At: at, Sticker: c.Sticker, Effect: c.Effect, Duration: c.Duration}
		if !c.Canvas {
			t.Color, t.Hold = c.Color, c.Hold
			if c.Loop {
				t.Repeat = "loop"
			} else if c.Repeat > 1 {
				t.Repeat = c.Repeat
			}
		}
		if c.WordIndex < len(tl.Words) {
			t.Cue = normalizeWord(tl.Words[c.WordIndex].Text)
		}
		switch {
		case c.Intensity > 0:
			t.Intensity = c.Intensity
		case c.Intensity < 0:
			// Explicit zero: emit intensity 0 by using a tiny value the
			// catalogue treats as "visually identical to no effect".
			t.Intensity = 0
		}
		out = append(out, t)
	}
	return out, nil
}

// LiveOverlaps reports sticker effects that start on a sticker while one
// of its live animations is still playing: the frames carry the whole
// moment, and a hop or a wobble on top of them fights it.
func LiveOverlaps(triggers []Trigger, pack story.Manifest) []string {
	var out []string
	for _, live := range triggers {
		if live.Animation == "" {
			continue
		}
		anim, err := pack.ResolveAnimation(live.Sticker, live.Animation)
		if err != nil {
			continue
		}
		// Held, the paused frame is as still as the sticker: only the way in
		// (or, resuming, the way out) is motion.
		end := live.At + anim.Seconds
		switch live.Mode {
		case story.LiveHold:
			end = live.At + anim.ToPause
		case story.LiveResume:
			end = live.At + anim.FromPause
		}
		for _, t := range triggers {
			if (t.Sticker == live.Sticker || t.Sticker == story.AllTarget) && t.Effect != "" && t.Repeat != "loop" && t.At > live.At && t.At < end {
				out = append(out, fmt.Sprintf("%s %s at %.1fs lands inside %s's %s (%.1f–%.1fs)", t.Sticker, t.Effect, t.At, live.Sticker, live.Animation, live.At, end))
			}
		}
	}
	return out
}

// EncodeSidecar serialises and strictly validates a sidecar for a pack
// with the given declared stickers, their live animations and setting.
func EncodeSidecar(triggers []Trigger, declared map[string]bool, animations effects.Animations, expressions effects.Expressions, features map[string]bool, setting string) ([]byte, error) {
	data, err := json.MarshalIndent(Sidecar{Schema: effects.SupportedSchema, Triggers: triggers}, "", "  ")
	if err != nil {
		return nil, err
	}
	data = append(data, '\n')
	if errs := effects.Validate(data, declared, animations, expressions, features, setting); len(errs) > 0 {
		return nil, fmt.Errorf("sidecar invalid: %v", errs)
	}
	return data, nil
}

// SoundPlacement is a sound hint located on the timeline.
type SoundPlacement struct {
	Hint story.SoundHint
	At   float64
}

// PlaceSounds finds each hint's cue word; hints whose word is absent are
// dropped and reported.
func PlaceSounds(hints []story.SoundHint, tl *Timeline) (placed []SoundPlacement, missing []string) {
	for _, h := range hints {
		i := tl.Find(h.Cue)
		if i < 0 {
			missing = append(missing, h.Cue)
			continue
		}
		placed = append(placed, SoundPlacement{Hint: h, At: round(tl.At(i))})
	}
	return placed, missing
}

func round(v float64) float64 { return float64(int(v*100+0.5)) / 100 }
