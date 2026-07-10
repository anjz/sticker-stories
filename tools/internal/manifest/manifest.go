// Package manifest defines the sticker-pack manifest schema (v1) and its
// validation rules. It is the Go half of the contract documented in
// docs/pack-format.md; the Swift decoder in StickerStoriesKit is the other
// half. Any schema change must update docs/pack-format.md, this package, and
// the Swift decoder in the same commit.
package manifest

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// SupportedSchemaVersion is the only schema version this validator accepts.
const SupportedSchemaVersion = 1

// Manifest is the root of a pack's manifest.json.
type Manifest struct {
	SchemaVersion int       `json:"schemaVersion"`
	ID            string    `json:"id"`
	Version       int       `json:"version"`
	DisplayName   string    `json:"displayName"`
	Theme         string    `json:"theme"`
	Background    string    `json:"background"`
	Foreground    string    `json:"foreground"`
	Stickers      []Sticker `json:"stickers"`
	Stories       []Story   `json:"stories"`
}

// Sticker is one draggable sticker in the pack.
type Sticker struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Image string `json:"image"`
}

// Story is one pregenerated story with its narration audio.
type Story struct {
	ID               string   `json:"id"`
	Title            string   `json:"title"`
	Text             string   `json:"text"`
	Audio            string   `json:"audio"`
	RequiredStickers []string `json:"requiredStickers"`
	OptionalStickers []string `json:"optionalStickers"`
	Weight           *float64 `json:"weight"` // nil ⇒ 1.0
	Tags             []string `json:"tags"`
}

// EffectiveWeight returns the story's selection weight, defaulting to 1.0.
func (s Story) EffectiveWeight() float64 {
	if s.Weight == nil {
		return 1.0
	}
	return *s.Weight
}

// IsFallback reports whether the story is playable with any canvas contents.
func (s Story) IsFallback() bool { return len(s.RequiredStickers) == 0 }

var idPattern = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// Load reads and decodes <dir>/manifest.json. It does not validate; call
// Manifest.Validate afterwards.
func Load(dir string) (*Manifest, error) {
	data, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		return nil, fmt.Errorf("reading manifest: %w", err)
	}
	var m Manifest
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("parsing manifest.json: %w", err)
	}
	return &m, nil
}

// Validate applies every rule from docs/pack-format.md. dir is the pack root
// used for file-existence checks. It returns all problems found, not just the
// first, so pack authors can fix a batch at once.
func (m *Manifest) Validate(dir string) []error {
	var errs []error
	fail := func(format string, args ...any) {
		errs = append(errs, fmt.Errorf(format, args...))
	}

	// Rule 1: schema version.
	if m.SchemaVersion != SupportedSchemaVersion {
		fail("schemaVersion %d is not supported (want %d)", m.SchemaVersion, SupportedSchemaVersion)
	}

	// Rule 6 (scalars).
	if !idPattern.MatchString(m.ID) {
		fail("pack id %q must match %s", m.ID, idPattern)
	}
	if m.Version < 1 {
		fail("version must be >= 1, got %d", m.Version)
	}
	if strings.TrimSpace(m.DisplayName) == "" {
		fail("displayName must not be empty")
	}

	// Rule 3: referenced files exist inside the pack.
	checkFile := func(field, rel string) {
		if rel == "" {
			fail("%s must not be empty", field)
			return
		}
		if filepath.IsAbs(rel) || pathEscapes(rel) {
			fail("%s: path %q must be pack-relative and must not escape the pack", field, rel)
			return
		}
		info, err := os.Stat(filepath.Join(dir, filepath.FromSlash(rel)))
		if err != nil {
			fail("%s: file %q not found in pack", field, rel)
		} else if info.IsDir() {
			fail("%s: %q is a directory, not a file", field, rel)
		}
	}
	checkFile("background", m.Background)
	checkFile("foreground", m.Foreground)

	// Rule 2: sticker IDs well-formed and unique.
	stickerIDs := make(map[string]bool, len(m.Stickers))
	for i, st := range m.Stickers {
		if !idPattern.MatchString(st.ID) {
			fail("stickers[%d]: id %q must match %s", i, st.ID, idPattern)
		}
		if stickerIDs[st.ID] {
			fail("stickers[%d]: duplicate sticker id %q", i, st.ID)
		}
		stickerIDs[st.ID] = true
		if strings.TrimSpace(st.Name) == "" {
			fail("sticker %q: name must not be empty", st.ID)
		}
		checkFile(fmt.Sprintf("sticker %q image", st.ID), st.Image)
	}

	// Rules 2, 4, 5, 6 over stories.
	storyIDs := make(map[string]bool, len(m.Stories))
	fallbacks := 0
	for i, st := range m.Stories {
		name := fmt.Sprintf("stories[%d] (%q)", i, st.ID)
		if strings.TrimSpace(st.ID) == "" {
			fail("stories[%d]: id must not be empty", i)
		}
		if storyIDs[st.ID] {
			fail("%s: duplicate story id", name)
		}
		storyIDs[st.ID] = true
		if strings.TrimSpace(st.Title) == "" {
			fail("%s: title must not be empty", name)
		}
		if strings.TrimSpace(st.Text) == "" {
			fail("%s: text must not be empty (stories must carry their text)", name)
		}
		checkFile(name+" audio", st.Audio)
		if st.EffectiveWeight() <= 0 {
			fail("%s: weight must be > 0, got %v", name, st.EffectiveWeight())
		}
		required := make(map[string]bool, len(st.RequiredStickers))
		for _, id := range st.RequiredStickers {
			if !stickerIDs[id] {
				fail("%s: requiredStickers references undeclared sticker %q", name, id)
			}
			required[id] = true
		}
		for _, id := range st.OptionalStickers {
			if !stickerIDs[id] {
				fail("%s: optionalStickers references undeclared sticker %q", name, id)
			}
			if required[id] {
				fail("%s: sticker %q appears in both requiredStickers and optionalStickers", name, id)
			}
		}
		if st.IsFallback() {
			fallbacks++
		}
	}
	if len(m.Stories) > 0 && fallbacks == 0 {
		fail("pack has no fallback story (at least one story must have empty requiredStickers)")
	}
	if len(m.Stories) == 0 {
		fail("pack must contain at least one story")
	}
	if len(m.Stickers) == 0 {
		fail("pack must contain at least one sticker")
	}

	return errs
}

// pathEscapes reports whether a slash-separated relative path climbs out of
// the pack directory.
func pathEscapes(rel string) bool {
	for _, part := range strings.Split(filepath.ToSlash(rel), "/") {
		if part == ".." {
			return true
		}
	}
	return false
}
