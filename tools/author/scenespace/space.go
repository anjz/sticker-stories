package main

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"

	"stickerstories/tools/internal/manifest"
)

// Space is space.json (tools/author/art/<pack>/space.json): the pack's
// space (manifest.Space, docs/pack-format.md "Space") and what the tools
// keep beside it — what the viewer shows walking about and where the
// sizing page last had each sticker. stickerart install copies the space
// alone into the manifest.
type Space struct {
	manifest.Space
	// Preview is what the viewer shows walking about.
	Preview []PreviewSticker `json:"preview,omitempty"`
	// Lineup is where the sizing page last had each sticker (its feet), so
	// the comparison carries on.
	Lineup []LineupSticker `json:"lineup,omitempty"`
}

type LineupSticker struct {
	Sticker string     `json:"sticker"`
	At      [2]float64 `json:"at"`
	Flip    bool       `json:"flip,omitempty"`
}

type PreviewSticker struct {
	Sticker string           `json:"sticker"`
	At      *[2]float64      `json:"at,omitempty"`
	Path    manifest.Polygon `json:"path,omitempty"`
	Perch   string           `json:"perch,omitempty"`
	Fly     manifest.Polygon `json:"fly,omitempty"`
	Depth   float64          `json:"depth,omitempty"`
}

func LoadSpace(path string) (*Space, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var s Space
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &s, nil
}

// Save writes the space as JSON with each [u, v] point on one line.
func (s *Space) Save(path string) error {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	data = compactPoints.ReplaceAll(data, []byte("[$1, $2]"))
	return os.WriteFile(path, append(data, '\n'), 0o644)
}

var compactPoints = regexp.MustCompile(`\[\s+(-?[\d.e+-]+),\s+(-?[\d.e+-]+)\s+\]`)

// Validate checks the space as the packager will (its planes are not
// known before install: nil) and the tools' own keys.
func (s *Space) Validate(stickers, features map[string]bool) []error {
	errs := s.Space.Validate(nil, stickers, features)
	fail := func(format string, a ...any) { errs = append(errs, fmt.Errorf(format, a...)) }
	for i, l := range s.Lineup {
		if stickers != nil && !stickers[l.Sticker] {
			fail("lineup[%d] %q: not a sticker of the pack", i, l.Sticker)
		}
	}
	for i, p := range s.Preview {
		field := fmt.Sprintf("preview[%d] %q", i, p.Sticker)
		if stickers != nil && !stickers[p.Sticker] {
			fail("%s: not a sticker of the pack", field)
		}
		if p.Perch != "" && s.Places[p.Perch].Lines == nil {
			fail("%s: perch %q is not a place with lines", field, p.Perch)
		}
		if p.Fly != nil && p.Depth <= 0 {
			fail("%s: a flyer needs a depth", field)
		}
	}
	return errs
}
