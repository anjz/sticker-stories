package manifest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
)

// PuppetRig is a sticker's puppet (docs/pack-format.md, "Puppets"): its
// drawing cut into parts that hang on a skeleton, so the app can pose it
// and an animation is keyframes rather than drawn frames. Coordinates are
// the sticker image's pixels at Size (top-left origin, y down) with the
// puppet at rest, where it lies over the sticker's own drawing.
// stickerrig writes it; the packager validates it; the app reads it.
type PuppetRig struct {
	Sticker string `json:"sticker"`
	// Atlas is the pack-relative image every part is cut from.
	Atlas string `json:"atlas"`
	// Size is the side of the square the coordinates are in: the
	// sticker image's, so the app scales by the placed sticker's size.
	Size float64 `json:"size"`
	// Parts are the pieces of art by name: where each is in the atlas,
	// and where its border is (the part's silhouette grown by the
	// sticker's die-cut border, white), Pad px larger on every side.
	Parts map[string]PuppetPart `json:"parts"`
	// Bones are the skeleton, each after its parent: the joint it turns
	// about, at rest.
	Bones []PuppetBone `json:"bones"`
	// Slots are what is drawn, back to front: on which bone, which of
	// its attachments by default.
	Slots []PuppetSlot `json:"slots"`
	// Faces maps the sticker's expressions (normal, happy, sleeping…)
	// to the attachments that show them: {"sleeping": {"eyeL": "closed"}}.
	// A key that sets a slot wins over the face.
	Faces map[string]map[string]string `json:"faces,omitempty"`
	// Idle is how the puppet keeps alive while a story has it on show
	// between animations: the bone that breathes (a slow swell) and the
	// attachments a blink shows now and then. Optional.
	Idle *PuppetIdle `json:"idle,omitempty"`
}

// PuppetIdle is a puppet's breathing bone and blink.
type PuppetIdle struct {
	Breathe string            `json:"breathe,omitempty"`
	Blink   map[string]string `json:"blink,omitempty"`
}

// PuppetPart is one piece of art in the atlas, in atlas px.
type PuppetPart struct {
	Rect   [4]int `json:"rect"`
	Border [4]int `json:"border"`
	Pad    int    `json:"pad"`
}

// PuppetBone is one joint of the skeleton: where it is at rest. Parent is
// empty for the root.
type PuppetBone struct {
	ID     string  `json:"id"`
	Parent string  `json:"parent,omitempty"`
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
}

// PuppetSlot is one thing drawn on a bone, and the art it can show.
type PuppetSlot struct {
	ID          string                      `json:"id"`
	Bone        string                      `json:"bone"`
	Default     string                      `json:"default"`
	Attachments map[string]PuppetAttachment `json:"attachments"`
}

// PuppetAttachment is a part as a slot shows it: the box it fills at rest
// (X, Y its top-left before Rotate, which turns it about its centre, in
// degrees clockwise), mirrored left to right with Flip, and darkened by
// Shade (0–1) — the far wing, behind the body.
type PuppetAttachment struct {
	Part   string  `json:"part"`
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	W      float64 `json:"w"`
	H      float64 `json:"h"`
	Rotate float64 `json:"rotate,omitempty"`
	Flip   bool    `json:"flip,omitempty"`
	Shade  float64 `json:"shade,omitempty"`
}

// AnimationPuppet is an animation as the sticker's puppet plays it
// (StickerAnimation.Puppet): keyframes, with the same meaning of hold,
// pause and loop as a sheet's frames — each key's Hold is the time from
// that pose to the next — so stories cue it the same way. Beside a sheet
// it carries its own pause, loop and stride; without one the sidecar's
// count its keys.
type AnimationPuppet struct {
	Rig  string      `json:"rig"`
	Keys []PuppetKey `json:"keys"`
	// Pause is the key an action can stop on (0-based, a middle one),
	// beside a sheet.
	Pause *int `json:"pause,omitempty"`
	// Loop and Stride are a looping move's, as for its sheet, beside one.
	Loop   *FrameRange `json:"loop,omitempty"`
	Stride float64     `json:"stride,omitempty"`
	// Wings are the bones a flight keeps going (with every bone hanging
	// on them, and their slots) whatever else the character does in the
	// air: a butterfly's wings beat on while it talks. A move that flies.
	Wings []string `json:"wings,omitempty"`
}

// PuppetKey is one pose: each bone's turn (R, degrees clockwise), shift
// (X, Y px, y down) and stretch (SX, SY; 1 when absent) from rest — bones
// not named stay at rest — and the attachments slots show (a slot not
// named shows the face's, or its default). Ease is how the pose moves on
// to the next: inOut (the default), in, out, linear, or step (it holds,
// then jumps).
type PuppetKey struct {
	Hold  float64             `json:"hold"`
	Ease  string              `json:"ease,omitempty"`
	Bones map[string]BonePose `json:"bones,omitempty"`
	Slots map[string]string   `json:"slots,omitempty"`
}

// BonePose is a bone's change from rest.
type BonePose struct {
	R  float64  `json:"r,omitempty"`
	X  float64  `json:"x,omitempty"`
	Y  float64  `json:"y,omitempty"`
	SX *float64 `json:"sx,omitempty"`
	SY *float64 `json:"sy,omitempty"`
}

// PuppetHidden is the attachment that shows nothing: a slot's default, a
// face's or a key's (the far wing, folded away until the owl flies).
const PuppetHidden = "none"

// PuppetEases are the ways a key moves on to the next.
var PuppetEases = []string{"", "inOut", "in", "out", "linear", "step"}

// LoadPuppetRig reads a rig strictly: unknown keys are errors.
func LoadPuppetRig(file string) (*PuppetRig, error) {
	data, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var r PuppetRig
	if err := dec.Decode(&r); err != nil {
		return nil, err
	}
	return &r, nil
}

// Validate checks the rig on its own: the atlas is in the pack, every
// bone's parent comes before it, every slot hangs on a bone and shows
// parts the rig has, and faces name slots and their attachments.
func (r *PuppetRig) Validate(dir, stickerID string) []error {
	var errs []error
	fail := func(format string, args ...any) { errs = append(errs, fmt.Errorf(format, args...)) }
	if r.Sticker != stickerID {
		fail("sticker %q does not match %q", r.Sticker, stickerID)
	}
	switch ext := path.Ext(r.Atlas); {
	case filepath.IsAbs(r.Atlas) || pathEscapes(r.Atlas):
		fail("atlas: path %q must be pack-relative and must not escape the pack", r.Atlas)
	case ext != ".png" && ext != ".webp":
		fail("atlas: %q must be a .png or .webp file", r.Atlas)
	default:
		if _, err := os.Stat(filepath.Join(dir, filepath.FromSlash(r.Atlas))); err != nil {
			fail("atlas: file %q not found in pack", r.Atlas)
		}
	}
	if r.Size <= 0 {
		fail("size must be positive")
	}
	for name, p := range r.Parts {
		if p.Rect[2] <= 0 || p.Rect[3] <= 0 || p.Border[2] <= 0 || p.Border[3] <= 0 {
			fail("part %q: rect and border must be non-empty", name)
		}
	}
	bones := map[string]bool{}
	for i, b := range r.Bones {
		switch {
		case b.ID == "" || bones[b.ID]:
			fail("bones[%d]: id %q must be set and unique", i, b.ID)
		case i == 0 && b.Parent != "":
			fail("bones[0] %q is the root: no parent", b.ID)
		case i > 0 && !bones[b.Parent]:
			fail("bone %q: parent %q must be a bone before it", b.ID, b.Parent)
		}
		bones[b.ID] = true
	}
	slots := map[string]PuppetSlot{}
	for _, s := range r.Slots {
		if s.ID == "" || slots[s.ID].ID != "" {
			fail("slot id %q must be set and unique", s.ID)
		}
		slots[s.ID] = s
		if !bones[s.Bone] {
			fail("slot %q: bone %q is not in the rig", s.ID, s.Bone)
		}
		if _, ok := s.Attachments[s.Default]; !ok && s.Default != PuppetHidden {
			fail("slot %q: default %q is not one of its attachments (or %q)", s.ID, s.Default, PuppetHidden)
		}
		for name, a := range s.Attachments {
			if _, ok := r.Parts[a.Part]; !ok {
				fail("slot %q attachment %q: part %q is not in the rig", s.ID, name, a.Part)
			}
			if a.W <= 0 || a.H <= 0 || a.Shade < 0 || a.Shade > 1 {
				fail("slot %q attachment %q: needs a positive size and shade 0–1", s.ID, name)
			}
		}
	}
	if r.Idle != nil {
		if r.Idle.Breathe != "" && !bones[r.Idle.Breathe] {
			fail("idle: breathe bone %q is not in the rig", r.Idle.Breathe)
		}
		for slot, att := range r.Idle.Blink {
			if _, ok := slots[slot].Attachments[att]; !ok {
				fail("idle: blink: slot %q has no attachment %q", slot, att)
			}
		}
	}
	for face, set := range r.Faces {
		for slot, att := range set {
			if _, ok := slots[slot].Attachments[att]; !ok && att != PuppetHidden {
				fail("face %q: slot %q has no attachment %q", face, slot, att)
			}
		}
	}
	return errs
}

// validatePuppet checks an animation's puppet against its rig.
func (a *StickerAnimation) validatePuppet(dir string) []error {
	p := a.Puppet
	var errs []error
	fail := func(format string, args ...any) { errs = append(errs, fmt.Errorf("puppet: "+format, args...)) }
	if filepath.IsAbs(p.Rig) || pathEscapes(p.Rig) || path.Ext(p.Rig) != ".json" {
		fail("rig %q must be a pack-relative .json file", p.Rig)
		return errs
	}
	rig, err := LoadPuppetRig(filepath.Join(dir, filepath.FromSlash(p.Rig)))
	if err != nil {
		fail("rig %s: %v", p.Rig, err)
		return errs
	}
	for _, e := range rig.Validate(dir, a.Sticker) {
		fail("rig %s: %v", p.Rig, e)
	}
	n := len(p.Keys)
	if n < 2 {
		fail("needs at least two keys")
	}
	bones, slots := map[string]bool{}, map[string]PuppetSlot{}
	for _, b := range rig.Bones {
		bones[b.ID] = true
	}
	for _, s := range rig.Slots {
		slots[s.ID] = s
	}
	for i, k := range p.Keys {
		if k.Hold < MinHold || k.Hold > MaxHold {
			fail("keys[%d]: hold %g is outside %g–%g s", i, k.Hold, MinHold, MaxHold)
		}
		if !slices.Contains(PuppetEases, k.Ease) {
			fail("keys[%d]: ease %q must be one of %s", i, k.Ease, strings.Join(PuppetEases[1:], ", "))
		}
		for id, b := range k.Bones {
			if !bones[id] {
				fail("keys[%d]: bone %q is not in the rig", i, id)
			}
			for _, s := range []*float64{b.SX, b.SY} {
				// A negative stretch mirrors the bone (a turn round);
				// passing 0 between keys is the paper edge-on.
				if s != nil && (*s == 0 || math.Abs(*s) > 4) {
					fail("keys[%d]: bone %q stretch %g must not be 0 and at most 4 either way", i, id, *s)
				}
			}
			if math.Abs(b.R) > 720 {
				fail("keys[%d]: bone %q turns %g°, more than two turns", i, id, b.R)
			}
		}
		for slot, att := range k.Slots {
			if _, ok := slots[slot].Attachments[att]; !ok && att != PuppetHidden {
				fail("keys[%d]: slot %q has no attachment %q", i, slot, att)
			}
		}
	}
	for _, id := range p.Wings {
		if !bones[id] {
			fail("wings: bone %q is not in the rig", id)
		}
	}
	if len(p.Wings) > 0 && (a.EffectiveKind() != KindMove || !a.Flies) {
		fail("wings belong to a move that flies")
	}
	if a.PuppetOnly() {
		// The sidecar's own pause, loop and stride count the keys.
		if p.Pause != nil || p.Loop != nil || p.Stride != 0 {
			fail("pause, loop and stride are the sidecar's own when there is no sheet")
		}
		return errs
	}
	switch a.EffectiveKind() {
	case KindAction:
		if p.Loop != nil || p.Stride != 0 {
			fail("loop and stride belong to a move")
		}
		if (p.Pause == nil) != (a.Pause == nil) {
			fail("pause must be given exactly when the sheet has one")
		} else if p.Pause != nil && (*p.Pause < 1 || *p.Pause > n-2) {
			fail("pause %d must be a middle key (1–%d)", *p.Pause, n-2)
		}
	case KindMove:
		if p.Pause != nil {
			fail("pause belongs to an action")
		}
		if (p.Loop == nil) != (a.Loop == nil) {
			fail("loop must be given exactly when the sheet has one")
		} else if l := p.Loop; l != nil {
			if l.From < 1 || l.To < l.From || l.To >= n {
				fail("loop %d–%d must be keys within 1–%d (key 0 is the rest pose)", l.From, l.To, n-1)
			}
			if p.Stride <= 0 || p.Stride > 5 {
				fail("stride %g must be above 0 and at most 5 sticker widths", p.Stride)
			}
		}
	}
	return errs
}
