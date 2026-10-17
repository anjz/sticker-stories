package manifest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
)

// StickerAnimation is a live-animation sidecar (docs/pack-format.md, "Live
// animations"): a sprite sheet of frames the app plays over the placed
// sticker, with the timing and the mapping of its rest frame onto the
// sticker — or, without a sheet, keys the sticker's puppet plays
// (Puppet; docs/pack-format.md, "Puppets"), whose keys are then its
// frames: Pause, Loop and Particles count keys. stickeranim writes sheet
// sidecars and stickerrig puppet ones; the packager validates them
// strictly; the app reads them leniently.
type StickerAnimation struct {
	ID      string `json:"id"`
	Sticker string `json:"sticker"`
	// Kind is what the animation is for: an "action" (the default) is a
	// moment a story cues ({snail:live}); a "move" is how the character
	// gets about — a walk, a hop, a flight, a sprout — and plays while a
	// story brings it into the scene or moves it (docs/effects.md,
	// "Entrances", "Movement"). A sticker's first move is its usual way;
	// any other is another way it can go (the ladybug crawls, and flies
	// when a story says so: {ladybug:go on flower by fly}).
	Kind string `json:"kind,omitempty"`
	// Description says in one plain sentence what the animation shows
	// ("the bear cub yawns and stretches…"), for story authors: a story
	// cues it ({bear:live}) on the words that tell that moment. The app
	// ignores it.
	Description string `json:"description"`
	// Sheet is the pack-relative path of the sprite sheet: Columns frames
	// per row, Count frames read left to right, top to bottom, each
	// Frame.Width×Frame.Height px. Empty for a puppet's animation.
	Sheet string `json:"sheet,omitempty"`
	Frame struct {
		Width  int `json:"width"`
		Height int `json:"height"`
	} `json:"frame,omitzero"`
	Columns int `json:"columns,omitempty"`
	Count   int `json:"count,omitempty"`
	// Rest is the first frame's bordered art within a frame and StickerBox
	// the same art within the sticker image, both as fractions of their
	// image with a top-left origin: the app scales and offsets the frames
	// so Rest lands on StickerBox. A puppet's animation has no Rest; its
	// StickerBox is the sticker's drawing in its image all the same.
	Rest       UnitBox `json:"rest,omitzero"`
	StickerBox UnitBox `json:"stickerBox"`
	// Hold is how long each frame shows, in seconds, one entry per frame
	// (a puppet's keys carry their own).
	Hold []float64 `json:"hold,omitempty"`
	// Pause is the frame an action can stop on and stay ({snail:live
	// hold}) until the story resumes it ({snail:live resume}) or ends:
	// the snail tucked inside its shell. Actions only; optional.
	Pause *AnimationPause `json:"pause,omitempty"`
	// Perched says the action needs the character sitting on something
	// (the butterfly folding its wings to rest): a story lands a flyer
	// before it plays it, never in open air (a feature marked air).
	// Actions only; optional; the app ignores it.
	Perched bool `json:"perched,omitempty"`
	// Idle marks a small, gentle action (a look around, an ear flick) the
	// app plays now and then on its own while the story leaves the
	// character be, so it looks alive. Actions only; optional.
	Idle bool `json:"idle,omitempty"`
	// Place are the features an action happens at (the woodpecker's tap:
	// the trunks). Before it plays, the app takes the character to the
	// nearest spot on one unless it is there; stories that move it
	// elsewhere take it back first. Actions only; optional.
	Place []string `json:"place,omitempty"`
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
	// Flies says the loop is a flight: the app glides the character along
	// with a gentle bob, and it stops beside others at their height.
	Flies bool `json:"flies,omitempty"`
	// Hovers says the flight can hold still in the air, its wings going
	// (a bee, a butterfly). Without it a flyer never stops in the air:
	// the app keeps it flying a slow loop round its spot (a bird). Needs
	// Flies.
	Hovers bool `json:"hovers,omitempty"`
	// On, for a move, are the features a story that brings the character
	// in this way lands it on ({duckling:enter by swim}: the pond), in
	// order of preference; empty for its stage's. Moves with a loop only.
	// For an action, On are the places it is done in (riding a wave: the
	// sea): while a move that Stays keeps the character in water, an
	// action whose On does not name that water shows only its face over
	// the move (the surfer laughs as he paddles on). Optional.
	On []string `json:"on,omitempty"`
	// Away is another looping move of the sticker's, played instead while
	// a leg this way goes away from the viewer, deeper into the scene
	// (paddle's "paddle-out", his back to us); resting or coming back it
	// plays this one. Moves with a loop only; optional.
	Away string `json:"away,omitempty"`
	// Faces is the way the character faces on screen while the action
	// plays ("left" or "right"; riding a wave: right): the app mirrors the
	// whole puppet as needed and turns it back after. Actions only;
	// optional.
	Faces string `json:"faces,omitempty"`
	// Stays says that once this way has taken the character into one of
	// On (the surfer out on the waves), the loop keeps going where it is
	// instead of settling into the sticker pose. Needs On.
	Stays bool `json:"stays,omitempty"`
	// Waterline is how deep the character floats while it is in water
	// among On: the fraction of its drawing's height, from its feet, that
	// is under the water (a duckling swimming: its feet and the bottom of
	// its belly). The app hides that part and draws a ripple where it
	// meets the water, whatever the character does there. Needs On.
	Waterline float64 `json:"waterline,omitempty"`
	// Particles are bursts the frames fire as they come on show — a
	// landing's dust, a splash — since stickers never draw particles
	// themselves (docs/effects.md, "Particles"). Optional.
	Particles []AnimationParticle `json:"particles,omitempty"`
	// Puppet is the animation played on the sticker's puppet
	// (docs/pack-format.md, "Puppets"): keyframes the app poses its parts
	// with. Beside a sheet it is the same animation, played instead of the
	// sheet's frames; without one it is the animation. Written by
	// stickerrig.
	Puppet *AnimationPuppet `json:"puppet,omitempty"`
}

// AnimationParticle is one burst an animation fires: when Frame (0-based)
// first shows, the particle effect Effect (dust-puff, spray, sparks) from
// the point X, Y of the sticker image — fractions with a top-left origin,
// like StickerBox; a little outside it is fine (a flame's tip) — at its
// Intensity (0–1, default 0.6) and Color (#RRGGBB, default the effect's).
type AnimationParticle struct {
	Frame     int      `json:"frame"`
	Effect    string   `json:"effect"`
	X         float64  `json:"x"`
	Y         float64  `json:"y"`
	Intensity *float64 `json:"intensity,omitempty"`
	Color     string   `json:"color,omitempty"`
}

// ParticleEffects are the effects an animation's frames may fire.
var ParticleEffects = []string{"dust-puff", "spray", "sparks"}

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
	if a.PuppetOnly() {
		// The keys are the frames: their holds are checked with the puppet.
		if a.Frame.Width != 0 || a.Frame.Height != 0 || a.Columns != 0 || a.Count != 0 || len(a.Hold) > 0 || a.Rest != (UnitBox{}) {
			fail("frame, columns, count, rest and hold belong to a sheet; a puppet's keys are its frames")
		}
	} else {
		a.validateSheet(dir, fail)
	}
	count := a.Frames()
	switch a.EffectiveKind() {
	case KindAction:
		if a.Loop != nil || a.Facing != "" || a.Stride != 0 || a.Hops || a.Flies || a.Hovers || a.Stays || a.Waterline != 0 || a.Away != "" {
			fail("loop, facing, stride, hops, flies, hovers, stays, waterline and away belong to a move, not an action")
		}
		if a.Faces != "" && a.Faces != "left" && a.Faces != "right" {
			fail("faces must be left or right, got %q", a.Faces)
		}
		if p := a.Pause; p != nil {
			if p.Frame < 1 || p.Frame > count-2 {
				fail("pause.frame %d must be a middle frame (1–%d)", p.Frame, count-2)
			}
			if strings.TrimSpace(p.Shows) == "" {
				fail("pause.shows must say what the paused frame shows")
			}
		}
	case KindMove:
		if a.Pause != nil || a.Perched || a.Idle || len(a.Place) > 0 {
			fail("pause, perched, idle and place belong to an action, not a move")
		}
		if a.Faces != "" {
			fail("faces belongs to an action, not a move")
		}
		if l := a.Loop; l != nil {
			if l.From < 0 || l.To < l.From || l.To >= count {
				fail("loop %d–%d must be frames within 0–%d", l.From, l.To, count-1)
			} else if a.PuppetOnly() && l.From < 1 {
				fail("loop %d–%d must start after key 0, the rest pose", l.From, l.To)
			}
			if a.Facing != "left" && a.Facing != "right" {
				fail("a looping move needs facing left or right, got %q", a.Facing)
			}
			if a.Stride <= 0 || a.Stride > 5 {
				fail("stride %g must be above 0 and at most 5 sticker widths", a.Stride)
			}
			if a.Hops && a.Flies {
				fail("a move hops or flies, not both")
			}
			if a.Hovers && !a.Flies {
				fail("hovers needs flies: only a flight holds still in the air")
			}
			if a.Stays && len(a.On) == 0 {
				fail("stays needs on: the places where the move keeps going")
			}
			if a.Waterline != 0 && len(a.On) == 0 {
				fail("waterline needs on: the water the character floats in")
			}
			if a.Waterline < 0 || a.Waterline >= 1 {
				fail("waterline %g must be a fraction of the drawing's height, at least 0 and below 1", a.Waterline)
			}
			if a.Away != "" && a.Away == a.ID {
				fail("away %q must be another move, not this one", a.Away)
			}
		} else if a.Facing != "" || a.Stride != 0 || a.Hops || a.Flies || a.Hovers || len(a.On) > 0 || a.Stays || a.Waterline != 0 || a.Away != "" {
			fail("facing, stride, hops, flies, hovers, on, stays, waterline and away need a loop")
		}
	default:
		fail("kind %q must be action or move", a.Kind)
	}
	boxes := map[string]UnitBox{"stickerBox": a.StickerBox}
	if !a.PuppetOnly() {
		boxes["rest"] = a.Rest
	}
	for name, b := range boxes {
		if b.Width <= 0 || b.Height <= 0 || b.X < 0 || b.Y < 0 || b.X+b.Width > 1.0001 || b.Y+b.Height > 1.0001 {
			fail("%s must be a non-empty box inside the unit square, got %+v", name, b)
		}
	}
	if a.Puppet != nil {
		errs = append(errs, a.validatePuppet(dir)...)
	}
	for i, p := range a.Particles {
		field := fmt.Sprintf("particles[%d]", i)
		if p.Frame < 0 || p.Frame >= count {
			fail("%s: frame %d is not one of the %d frames (0-based)", field, p.Frame, count)
		}
		if !slices.Contains(ParticleEffects, p.Effect) {
			fail("%s: effect %q must be one of %s", field, p.Effect, strings.Join(ParticleEffects, ", "))
		}
		if p.X < -0.5 || p.X > 1.5 || p.Y < -0.5 || p.Y > 1.5 {
			fail("%s: x and y must be within -0.5–1.5 of the sticker image, got %g, %g", field, p.X, p.Y)
		}
		if p.Intensity != nil && (*p.Intensity < 0 || *p.Intensity > 1) {
			fail("%s: intensity %g must be 0–1", field, *p.Intensity)
		}
		if p.Color != "" && !hexColor.MatchString(p.Color) {
			fail("%s: color %q must be #RRGGBB", field, p.Color)
		}
	}
	return errs
}

// validateSheet checks a sheet sidecar's sheet, frames and holds.
func (a *StickerAnimation) validateSheet(dir string, fail func(string, ...any)) {
	switch ext := path.Ext(a.Sheet); {
	case a.Sheet == "":
		fail("sheet must not be empty (or give a puppet instead)")
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
}

// PuppetOnly says the animation is its puppet's keys, with no sheet.
func (a *StickerAnimation) PuppetOnly() bool { return a.Sheet == "" && a.Puppet != nil }

// Holds is how long each frame shows: the sheet's holds, or a puppet's
// keys' (each key's hold is the time from it to the next).
func (a *StickerAnimation) Holds() []float64 {
	if !a.PuppetOnly() {
		return a.Hold
	}
	holds := make([]float64, len(a.Puppet.Keys))
	for i, k := range a.Puppet.Keys {
		holds[i] = k.Hold
	}
	return holds
}

// Frames is how many frames the animation has (a puppet's: its keys).
func (a *StickerAnimation) Frames() int {
	if a.PuppetOnly() {
		return len(a.Puppet.Keys)
	}
	return a.Count
}

// Duration is how long the animation plays, in seconds: the sum of its
// holds.
func (a *StickerAnimation) Duration() float64 {
	total := 0.0
	for _, h := range a.Holds() {
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
	for i, h := range a.Holds() {
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
