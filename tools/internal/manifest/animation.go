package manifest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path"
	"path/filepath"
)

// StickerAnimation is a live-animation sidecar (docs/pack-format.md, "Live
// animations"): a sprite sheet of frames the app plays over the placed
// sticker, with the timing and the mapping of its rest frame onto the
// sticker. stickeranim writes it; the packager validates it strictly;
// the app reads it leniently.
type StickerAnimation struct {
	ID      string `json:"id"`
	Sticker string `json:"sticker"`
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
	for name, b := range map[string]UnitBox{"rest": a.Rest, "stickerBox": a.StickerBox} {
		if b.Width <= 0 || b.Height <= 0 || b.X < 0 || b.Y < 0 || b.X+b.Width > 1.0001 || b.Y+b.Height > 1.0001 {
			fail("%s must be a non-empty box inside the unit square, got %+v", name, b)
		}
	}
	return errs
}
