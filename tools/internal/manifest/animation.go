package manifest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// StickerAnimation is a live-animation sidecar (docs/pack-format.md, "Live
// animations"): a sprite sheet of frames the app plays over the placed
// sticker, with the timing and the mapping of its rest frame onto the
// sticker. stickeranim writes it; the packager validates it strictly;
// the app reads it leniently.
type StickerAnimation struct {
	ID      string `json:"id"`
	Sticker string `json:"sticker"`
	// Kind is what the animation is for: an "action" (the default) is a
	// moment a story cues ({snail:live}); a "move" is how the character
	// gets about — a walk, a hop, a flight, a sprout — and plays while a
	// story brings it into the scene (docs/effects.md, "Entrances"). A
	// sticker has at most one move.
	Kind string `json:"kind,omitempty"`
	// Description says in one plain sentence what the animation shows
	// ("the bear cub yawns and stretches…"), for story authors: a story
	// cues it ({bear:live}) on the words that tell that moment. The app
	// ignores it.
	Description string `json:"description"`
	// Sheet is the pack-relative path of the sprite sheet: Columns frames
	// per row, Count frames read left to right, top to bottom, each
	// Frame.Width×Frame.Height px.
	Sheet string `json:"sheet"`
	Frame struct {
		Width  int `json:"width"`
		Height int `json:"height"`
	} `json:"frame"`
	Columns int `json:"columns"`
	Count   int `json:"count"`
	// Rest is the first frame's bordered art within a frame and StickerBox
	// the same art within the sticker image, both as fractions of their
	// image with a top-left origin: the app scales and offsets the frames
	// so Rest lands on StickerBox.
	Rest       UnitBox `json:"rest"`
	StickerBox UnitBox `json:"stickerBox"`
	// Hold is how long each frame shows, in seconds, one entry per frame.
	Hold []float64 `json:"hold"`
	// Pause is the frame an action can stop on and stay ({snail:live
	// hold}) until the story resumes it ({snail:live resume}) or ends:
	// the snail tucked inside its shell. Actions only; optional.
	Pause *AnimationPause `json:"pause,omitempty"`
	// Loop is the run of frames a move repeats while the character
	// travels (a walk cycle); the frames after it bring it back to rest
	// when it arrives. Moves only; a move without one (a sprout) plays
	// once.
	Loop *FrameRange `json:"loop,omitempty"`
	// Facing is the way a looping move travels in its frames ("left" or
	// "right"): the app mirrors a visitor that has to go the other way.
	Facing string `json:"facing,omitempty"`
	// Stride is how far one loop carries the character, in multiples of
	// the sticker's width, so it travels at the pace its legs move.
	Stride float64 `json:"stride,omitempty"`
	// Hops says the loop's frames are hops drawn in place: the app lifts
	// the character in an arc once per loop as it travels.
	Hops bool `json:"hops,omitempty"`
}

// Animation kinds.
const (
	KindAction = "action"
	KindMove   = "move"
)

// AnimationPause is the frame an action can stop on (0-based) and what it
// shows there, in plain words for story authors.
type AnimationPause struct {
	Frame int    `json:"frame"`
	Shows string `json:"shows"`
}

// FrameRange is a run of frames, 0-based, both ends included.
type FrameRange struct {
	From int `json:"from"`
	To   int `json:"to"`
}

// EffectiveKind is the animation's kind, "action" when unset.
func (a *StickerAnimation) EffectiveKind() string {
	if a.Kind == "" {
		return KindAction
	}
	return a.Kind
}

// UnitBox is a rectangle as fractions of an image, top-left origin.
type UnitBox struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"width"`
	Height float64 `json:"height"`
}

// Hold bounds in seconds: shorter than a frame at 50 fps is not a hold,
// and a frame shown for more than five seconds is a still.
const (
	MinHold = 0.02
	MaxHold = 5.0
)

// LoadStickerAnimation reads a sidecar strictly: unknown keys are errors.
func LoadStickerAnimation(file string) (*StickerAnimation, error) {
	data, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var a StickerAnimation
	if err := dec.Decode(&a); err != nil {
		return nil, err
	}
	return &a, nil
}

// Validate applies the sidecar rules (docs/pack-format.md, rule 12) for
// an animation declared by the sticker with the given ID; dir is the
// pack root.
func (a *StickerAnimation) Validate(dir, stickerID string) []error {
	var errs []error
	fail := func(format string, args ...any) {
		errs = append(errs, fmt.Errorf(format, args...))
	}
	if a.ID == "" {
		fail("id must not be empty")
	}
	if strings.TrimSpace(a.Description) == "" {
		fail("description must say what the animation shows")
	}
	if a.Sticker != stickerID {
		fail("sticker %q does not match the declaring sticker %q", a.Sticker, stickerID)
	}
	switch ext := path.Ext(a.Sheet); {
	case a.Sheet == "":
		fail("sheet must not be empty")
	case filepath.IsAbs(a.Sheet) || pathEscapes(a.Sheet):
		fail("sheet: path %q must be pack-relative and must not escape the pack", a.Sheet)
	case ext != ".png" && ext != ".webp":
		fail("sheet: %q must be a .png or .webp file", a.Sheet)
	default:
		if _, err := os.Stat(filepath.Join(dir, filepath.FromSlash(a.Sheet))); err != nil {
			fail("sheet: file %q not found in pack", a.Sheet)
		}
	}
	if a.Frame.Width < 1 || a.Frame.Height < 1 {
		fail("frame size must be positive, got %dx%d", a.Frame.Width, a.Frame.Height)
	}
	if a.Columns < 1 {
		fail("columns must be >= 1, got %d", a.Columns)
	}
	if a.Count < 1 {
		fail("count must be >= 1, got %d", a.Count)
	}
	if len(a.Hold) != a.Count {
		fail("hold has %d entries for %d frames", len(a.Hold), a.Count)
	}
	for i, h := range a.Hold {
		if h < MinHold || h > MaxHold {
			fail("hold[%d] = %g is outside %g–%g s", i, h, MinHold, MaxHold)
		}
	}
	switch a.EffectiveKind() {
	case KindAction:
		if a.Loop != nil || a.Facing != "" || a.Stride != 0 || a.Hops {
			fail("loop, facing, stride and hops belong to a move, not an action")
		}
		if p := a.Pause; p != nil {
			if p.Frame < 1 || p.Frame > a.Count-2 {
				fail("pause.frame %d must be a middle frame (1–%d)", p.Frame, a.Count-2)
			}
			if strings.TrimSpace(p.Shows) == "" {
				fail("pause.shows must say what the paused frame shows")
			}
		}
	case KindMove:
		if a.Pause != nil {
			fail("pause belongs to an action, not a move")
		}
		if l := a.Loop; l != nil {
			if l.From < 0 || l.To < l.From || l.To >= a.Count {
				fail("loop %d–%d must be frames within 0–%d", l.From, l.To, a.Count-1)
			}
			if a.Facing != "left" && a.Facing != "right" {
				fail("a looping move needs facing left or right, got %q", a.Facing)
			}
			if a.Stride <= 0 || a.Stride > 5 {
				fail("stride %g must be above 0 and at most 5 sticker widths", a.Stride)
			}
		} else if a.Facing != "" || a.Stride != 0 || a.Hops {
			fail("facing, stride and hops need a loop")
		}
	default:
		fail("kind %q must be action or move", a.Kind)
	}
	for name, b := range map[string]UnitBox{"rest": a.Rest, "stickerBox": a.StickerBox} {
		if b.Width <= 0 || b.Height <= 0 || b.X < 0 || b.Y < 0 || b.X+b.Width > 1.0001 || b.Y+b.Height > 1.0001 {
			fail("%s must be a non-empty box inside the unit square, got %+v", name, b)
		}
	}
	return errs
}

// Duration is how long the animation plays, in seconds: the sum of its
// holds.
func (a *StickerAnimation) Duration() float64 {
	total := 0.0
	for _, h := range a.Hold {
		total += h
	}
	return total
}

// PlaySeconds is how long an action takes to reach its pause frame (the
// whole animation up to and including that frame's hold, as when it plays
// through), and how long it takes from there to the end; without a pause,
// the whole duration and 0.
func (a *StickerAnimation) PlaySeconds() (toPause, fromPause float64) {
	if a.Pause == nil {
		return a.Duration(), 0
	}
	for i, h := range a.Hold {
		if i < a.Pause.Frame {
			toPause += h
		} else if i > a.Pause.Frame {
			fromPause += h
		}
	}
	return toPause, fromPause
}

// LoadAnimations reads every live animation the manifest declares, by
// sticker ID in declaration order, for the story tools. A sidecar that
// does not load is an error (the packager reports the details).
func (m *Manifest) LoadAnimations(dir string) (map[string][]*StickerAnimation, error) {
	out := map[string][]*StickerAnimation{}
	for _, st := range m.Stickers {
		for _, rel := range st.Animations {
			a, err := LoadStickerAnimation(filepath.Join(dir, filepath.FromSlash(rel)))
			if err != nil {
				return nil, fmt.Errorf("sticker %q animation %s: %w", st.ID, rel, err)
			}
			out[st.ID] = append(out[st.ID], a)
		}
	}
	return out, nil
}
