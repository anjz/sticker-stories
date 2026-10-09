// Package manifest defines the sticker-pack manifest schema (v2) and its
// validation rules. It is the Go half of the contract documented in
// docs/pack-format.md; the Swift decoder in StickerStoriesKit is the other
// half. Any schema change must update docs/pack-format.md, this package, and
// the Swift decoder in the same commit.
package manifest

import (
	"encoding/json"
	"fmt"
	"maps"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"

	"stickerstories/tools/internal/effects"
)

// SupportedSchemaVersion is the only schema version this validator accepts.
const SupportedSchemaVersion = 2

// Settings lists the values a pack's "setting" may take: where its scene
// takes place, which decides the canvas effects its stories may use
// (docs/effects.md). Absent ⇒ "none".
var Settings = []string{"outdoors", "indoors", "space", "underwater", "none"}

// Manifest is the root of a pack's manifest.json.
type Manifest struct {
	SchemaVersion int               `json:"schemaVersion"`
	ID            string            `json:"id"`
	Version       int               `json:"version"`
	Languages     []string          `json:"languages"`
	DisplayName   map[string]string `json:"displayName"`
	// Optional one-line description per language for the store; when
	// present it must cover every declared language, like displayName.
	Description map[string]string `json:"description,omitempty"`
	Theme       string            `json:"theme"`
	Setting     string            `json:"setting,omitempty"` // one of Settings; "" ⇒ "none"
	// World is the physics of the pack's world for particle effects:
	// gravity relative to Earth and the ground's colour (optional; the
	// app fills gaps from Setting).
	World *World `json:"world,omitempty"`
	Background  string            `json:"background"`
	Foreground  string            `json:"foreground"`
	// Optional wider renditions for wide windows (iPhone): same pixel height
	// as the base art, base art centred inside; declared together or not at all.
	BackgroundWide string `json:"backgroundWide,omitempty"`
	ForegroundWide string `json:"foregroundWide,omitempty"`
	// Optional cover art for the pack's tile in the menu and the store
	// (made with uiart); without one the app composes the tile itself.
	Cover string `json:"cover,omitempty"`
	// Features are named places in the art — the pond, the trees'
	// branches — where stickers can land when a story brings them in
	// (Stage.On). Optional.
	Features map[string]Feature `json:"features,omitempty"`
	// NarrationPacks names, per language, the Apple-hosted asset pack that
	// carries that language's narration audio (docs/asset-delivery.md):
	// "<pack>-narration-<language>-<hash of the audio>", written by
	// storyaudio install. Optional; a language without one is read from
	// the pack itself.
	NarrationPacks map[string]string `json:"narrationPacks,omitempty"`
	Stickers       []Sticker         `json:"stickers"`
	Stories        []Story           `json:"stories"`
}

// Sticker is one draggable sticker in the pack.
type Sticker struct {
	ID    string            `json:"id"`
	Name  map[string]string `json:"name"`
	Image string            `json:"image"`
	// Animations are pack-relative paths to live-animation sidecars
	// (StickerAnimation); absent means a still sticker.
	Animations []string `json:"animations,omitempty"`
	// Expressions are face variants of the sticker by expression id
	// ("happy", "sleeping"…): pack-relative images of exactly the
	// sticker's size and outline, so the app can swap one in place.
	// Absent means the sticker has only its normal face.
	Expressions map[string]string `json:"expressions,omitempty"`
	// Stage says where the sticker belongs in the scene and how it comes
	// in when a story names it and the child has not placed it; absent
	// means the app's default (DefaultStage).
	Stage *Stage `json:"stage,omitempty"`
	// Size is how big the character is next to the others — "huge" (a
	// rocket), "big" (a deer, a bear), "medium" (a fox), "small" (a bird)
	// or "tiny" (a ladybug): a story moving it beside another scales it to
	// their ratio (docs/effects.md, "Movement"). Absent: it keeps its size.
	Size string `json:"size,omitempty"`
	// Content (optional) is where the drawing sits in the sticker's image,
	// in fractions of it, origin bottom-left: a sticker drawn at its size
	// class's share of its box, with room around it (docs/pack-format.md,
	// "Drawn size"). Absent: the drawing fills the image.
	Content *StageArea `json:"content,omitempty"`
}

// Sizes are the size classes a sticker may have, biggest first.
var Sizes = []string{"huge", "big", "medium", "small", "tiny"}

// DrawnFill is the share of its square image a sticker of each size class
// is drawn at (the longest side of the drawing, border included) in a pack
// drawn at its size (docs/pack-format.md, "Drawn size"); the app's
// StickerSize.drawnFill holds the same numbers.
var DrawnFill = map[string]float64{"huge": 0.94, "big": 0.84, "medium": 0.72, "small": 0.60, "tiny": 0.50}

// Entrances lists the ways a sticker can come into the scene
// (docs/pack-format.md, "Stage"): hop in from the nearer side (things that
// walk), float in from the nearer side (things that fly), or fade in and
// grow where it stands (things that do not move).
var Entrances = []string{"hop", "fly", "grow"}

// Stage is where a sticker belongs in the scene and how it enters it:
// the features it lands on, in order of preference, and/or an area of its
// own (at least one of the two).
type Stage struct {
	// Entrance is one of Entrances.
	Entrance string `json:"entrance"`
	// On lists feature ids (Manifest.Features) in order of preference: the
	// sticker lands on the first one with a free spot on screen.
	On []string `json:"on,omitempty"`
	// Area is where the sticker's centre may land when none of On is on
	// screen (or when On is empty), in fractions of the base art (origin
	// bottom-left, like saved sticker positions).
	Area *StageArea `json:"area,omitempty"`
}

// Feature is a named place in the pack's art: one or more areas (the
// left and the right tree's branches) where a sticker's centre may land,
// and a line saying what is there, for story authors.
type Feature struct {
	Description string      `json:"description"`
	Areas       []StageArea `json:"areas"`
	// Words are how each language's stories name the place ("branch",
	// "branches"; "rama"): story validation warns when a sentence puts a
	// character there with no move taking it there. Optional; the app
	// ignores it.
	Words map[string][]string `json:"words,omitempty"`
	// Air marks open air (the sky): nothing sits there, so a flyer there
	// is flying, and a story lands it somewhere else before it rests (an
	// action marked perched). Story validation reads it; the app does not.
	Air bool `json:"air,omitempty"`
	// Edge (optional) is where a character that does not go into the
	// place stands beside it — the grass at the pond's edge: one whose
	// stage does not land on the place and whose way of going there does
	// not either. A mouse going to the pond stops here; the frog hops in.
	Edge []StageArea `json:"edge,omitempty"`
	// WideAreas (optional) are the place's areas when the wide art is
	// drawn, for a place on a foreground element the wide rendition paints
	// at its own edges (a habitat's hatch): in fractions of the base art
	// like Areas, so x may run into the wide side bands (WideMargin beyond
	// 0 and 1). Without them the wide art uses Areas.
	WideAreas []StageArea `json:"wideAreas,omitempty"`
}

// WideMargin is how far beyond the base art (in base-art widths) a wide
// area may reach: the side band of art up to 2× the base width.
const WideMargin = 0.5

// StageArea is a rectangle in fractions of the base art: X and Y are each
// [min, max] with 0 <= min < max <= 1.
type StageArea struct {
	X []float64 `json:"x"`
	Y []float64 `json:"y"`
	// Facing (feature areas only) is the way a character there faces,
	// "left" or "right": the area holds its front (a beak on the bark of a
	// trunk), not its centre.
	Facing string `json:"facing,omitempty"`
}

// Story is one pregenerated story; its text and narration exist once per
// declared pack language.
type Story struct {
	ID               string                       `json:"id"`
	RequiredStickers []string                     `json:"requiredStickers"`
	OptionalStickers []string                     `json:"optionalStickers"`
	Weight           *float64                     `json:"weight"` // nil ⇒ 1.0
	Tags             []string                     `json:"tags"`
	Localizations    map[string]StoryLocalization `json:"localizations"`
}

// StoryLocalization is one language's rendition of a story. Effects is the
// optional path to that narration's sticker-effect trigger sidecar
// (docs/effects.md).
type StoryLocalization struct {
	Title   string `json:"title"`
	Text    string `json:"text"`
	Audio   string `json:"audio"`
	Effects string `json:"effects,omitempty"`
}

// World is a pack's physics for particle effects (docs/pack-format.md,
// "World").
type World struct {
	// Gravity relative to Earth's (1; the Moon 0.17), 0–2.
	Gravity *float64 `json:"gravity,omitempty"`
	// Ground is the ground's colour, #RRGGBB: what dust is made of.
	Ground string `json:"ground,omitempty"`
}

// EffectiveSetting returns the pack's setting, defaulting to "none".
func (m *Manifest) EffectiveSetting() string {
	if m.Setting == "" {
		return "none"
	}
	return m.Setting
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

var (
	idPattern   = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)
	langPattern = regexp.MustCompile(`^[a-z]{2,3}(-[A-Z]{2})?$`)
	hexColor    = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)
)

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

	// Rule 8 (scalars).
	if !idPattern.MatchString(m.ID) {
		fail("pack id %q must match %s", m.ID, idPattern)
	}
	if m.Version < 1 {
		fail("version must be >= 1, got %d", m.Version)
	}
	if m.Setting != "" && !slices.Contains(Settings, m.Setting) {
		fail("setting %q must be one of %s", m.Setting, strings.Join(Settings, ", "))
	}
	// Rule 17: the world's gravity is 0–2 and its ground a colour.
	if w := m.World; w != nil {
		if w.Gravity != nil && (*w.Gravity < 0 || *w.Gravity > 2) {
			fail("world: gravity %g must be 0–2 (relative to Earth)", *w.Gravity)
		}
		if w.Ground != "" && !hexColor.MatchString(w.Ground) {
			fail("world: ground %q must be a #RRGGBB colour", w.Ground)
		}
	}

	// Rule 3: declared languages.
	if len(m.Languages) == 0 {
		fail("languages must not be empty")
	}
	declared := make(map[string]bool, len(m.Languages))
	for i, lang := range m.Languages {
		if !langPattern.MatchString(lang) {
			fail("languages[%d]: %q is not a well-formed tag (want xx or xx-YY)", i, lang)
		}
		if declared[lang] {
			fail("languages[%d]: duplicate language %q", i, lang)
		}
		declared[lang] = true
	}

	// Rule 4: exact language coverage for a localized string map.
	checkCoverage := func(field string, values map[string]string) {
		for _, lang := range m.Languages {
			value, ok := values[lang]
			if !ok {
				fail("%s: missing %q localization", field, lang)
			} else if strings.TrimSpace(value) == "" {
				fail("%s: %q localization must not be empty", field, lang)
			}
		}
		for lang := range values {
			if !declared[lang] {
				fail("%s: localization %q is not in declared languages", field, lang)
			}
		}
	}
	checkCoverage("displayName", m.DisplayName)
	if m.Description != nil {
		checkCoverage("description", m.Description)
	}

	// Rule 5: referenced files exist inside the pack.
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
	// Rule 11: image files are PNG or WebP (what the app decodes natively);
	// checked once the path itself is acceptable (rule 5).
	checkImage := func(field, rel string) {
		checkFile(field, rel)
		if rel == "" || filepath.IsAbs(rel) || pathEscapes(rel) {
			return
		}
		if ext := strings.ToLower(path.Ext(rel)); ext != ".png" && ext != ".webp" {
			fail("%s: %q must be a .png or .webp file", field, rel)
		}
	}
	checkImage("background", m.Background)
	checkImage("foreground", m.Foreground)
	// Rule 10: wide art comes as a pair.
	if m.BackgroundWide != "" {
		checkImage("backgroundWide", m.BackgroundWide)
	}
	if m.ForegroundWide != "" {
		checkImage("foregroundWide", m.ForegroundWide)
	}
	if (m.BackgroundWide == "") != (m.ForegroundWide == "") {
		fail("backgroundWide and foregroundWide must be declared together")
	}
	if m.Cover != "" {
		checkImage("cover", m.Cover)
	}

	// Rule 15: features have a well-formed id, a description and areas
	// inside the art.
	featureIDs := make([]string, 0, len(m.Features))
	for id := range m.Features {
		featureIDs = append(featureIDs, id)
	}
	sort.Strings(featureIDs)
	featureSet := make(map[string]bool, len(featureIDs))
	for _, id := range featureIDs {
		featureSet[id] = true
	}
	for _, id := range featureIDs {
		f := m.Features[id]
		field := fmt.Sprintf("feature %q", id)
		if !idPattern.MatchString(id) {
			fail("%s: id must match %s", field, idPattern)
		}
		if strings.TrimSpace(f.Description) == "" {
			fail("%s: description must not be empty", field)
		}
		for _, st := range m.Stickers {
			if st.ID == id {
				// A move's target ({frog:go to pond}) is a sticker or a
				// feature: the two must never share a name.
				fail("%s: id is also a sticker's id", field)
			}
		}
		if len(f.Areas) == 0 {
			fail("%s: needs at least one area", field)
		}
		for lang, words := range f.Words {
			if !slices.Contains(m.Languages, lang) {
				fail("%s: words: %q is not one of the pack's languages", field, lang)
			}
			for _, w := range words {
				if strings.TrimSpace(w) == "" || strings.ContainsAny(w, " \t") {
					fail("%s: words: %q must be one word", field, w)
				}
			}
		}
		for i, a := range f.Areas {
			checkArea(fmt.Sprintf("%s: areas[%d]", field, i), a, fail)
			if a.Facing != "" && a.Facing != "left" && a.Facing != "right" {
				fail("%s: areas[%d]: facing must be left or right, got %q", field, i, a.Facing)
			}
		}
		if len(f.WideAreas) > 0 && m.BackgroundWide == "" {
			fail("%s: wideAreas are for the wide art, which the pack does not have", field)
		}
		for i, a := range f.WideAreas {
			checkAreaWithin(fmt.Sprintf("%s: wideAreas[%d]", field, i), a, -WideMargin, 1+WideMargin, fail)
			if a.Facing != "" && a.Facing != "left" && a.Facing != "right" {
				fail("%s: wideAreas[%d]: facing must be left or right, got %q", field, i, a.Facing)
			}
		}
		for i, a := range f.Edge {
			checkArea(fmt.Sprintf("%s: edge[%d]", field, i), a, fail)
			if a.Facing != "" {
				fail("%s: edge[%d]: facing belongs to a feature's areas, not its edge", field, i)
			}
		}
	}

	// Rule 2: sticker IDs well-formed and unique.
	stickerIDs := make(map[string]bool, len(m.Stickers))
	animations := effects.Animations{}
	moves, animIDs := map[string]bool{}, map[string]bool{}
	expressions := effects.Expressions{}
	for i, st := range m.Stickers {
		if !idPattern.MatchString(st.ID) {
			fail("stickers[%d]: id %q must match %s", i, st.ID, idPattern)
		}
		if stickerIDs[st.ID] {
			fail("stickers[%d]: duplicate sticker id %q", i, st.ID)
		}
		stickerIDs[st.ID] = true
		if st.ID == effects.AllStickers {
			fail("stickers[%d]: id %q is reserved (effect triggers use it for every sticker)", i, st.ID)
		}
		if st.Size != "" && !slices.Contains(Sizes, st.Size) {
			fail("stickers[%d]: size %q must be one of %s", i, st.Size, strings.Join(Sizes, ", "))
		}
		if st.Content != nil {
			checkArea(fmt.Sprintf("stickers[%d]: content", i), *st.Content, fail)
			if st.Content.Facing != "" {
				fail("stickers[%d]: content has no facing", i)
			}
		}
		checkCoverage(fmt.Sprintf("sticker %q name", st.ID), st.Name)
		checkImage(fmt.Sprintf("sticker %q image", st.ID), st.Image)
		// Rule 12: live-animation sidecars exist and are valid.
		for j, rel := range st.Animations {
			field := fmt.Sprintf("sticker %q animations[%d]", st.ID, j)
			checkFile(field, rel)
			if rel == "" || filepath.IsAbs(rel) || pathEscapes(rel) {
				continue
			}
			if path.Ext(rel) != ".json" {
				fail("%s: %q must be a .json file", field, rel)
				continue
			}
			anim, err := LoadStickerAnimation(filepath.Join(dir, filepath.FromSlash(rel)))
			if err != nil {
				if !os.IsNotExist(err) {
					fail("%s: %v", field, err)
				}
				continue
			}
			for _, e := range anim.Validate(dir, st.ID) {
				fail("%s: %v", field, e)
			}
			if animIDs[st.ID+"."+anim.ID] {
				fail("%s: duplicate animation id %q", field, anim.ID)
			}
			animIDs[st.ID+"."+anim.ID] = true
			if anim.EffectiveKind() == KindMove {
				// The first move is the sticker's usual way; another is a way
				// a story can name ({ladybug:go on flower by fly}), so it
				// travels: it loops.
				if moves[st.ID] && anim.Loop == nil {
					fail("%s: a sticker's second move must loop (only its first may be a sprout)", field)
				}
				moves[st.ID] = true
				for _, f := range anim.On {
					if _, ok := m.Features[f]; !ok {
						fail("%s: on: %q is not a feature of the pack", field, f)
					}
				}
			}
			for _, f := range anim.Place {
				if _, ok := m.Features[f]; !ok {
					fail("%s: place: %q is not a feature of the pack", field, f)
				}
			}
			animations[st.ID] = append(animations[st.ID], effects.Animation{ID: anim.ID, Pausable: anim.Pause != nil, Move: anim.EffectiveKind() == KindMove})
		}
		// Rule 13: expression variants are images of the sticker; "normal"
		// is the sticker's own image and cannot be one.
		names := make([]string, 0, len(st.Expressions))
		for name := range st.Expressions {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			field := fmt.Sprintf("sticker %q expressions.%s", st.ID, name)
			if name == effects.Normal || !idPattern.MatchString(name) {
				fail("%s: expression id must match %s and not be %q", field, idPattern, effects.Normal)
			}
			checkImage(field, st.Expressions[name])
			expressions[st.ID] = append(expressions[st.ID], name)
		}
		// Rule 14: the stage names a known entrance and lands on declared
		// features and/or an area inside the art.
		if st.Stage != nil {
			field := fmt.Sprintf("sticker %q stage", st.ID)
			if !slices.Contains(Entrances, st.Stage.Entrance) {
				fail("%s: entrance %q must be one of %s", field, st.Stage.Entrance, strings.Join(Entrances, ", "))
			}
			if len(st.Stage.On) == 0 && st.Stage.Area == nil {
				fail("%s: needs features to land on (on) or an area", field)
			}
			seen := map[string]bool{}
			for _, id := range st.Stage.On {
				if _, ok := m.Features[id]; !ok {
					fail("%s: on names %q, which is not in features", field, id)
				}
				if seen[id] {
					fail("%s: on lists %q twice", field, id)
				}
				seen[id] = true
			}
			if st.Stage.Area != nil {
				checkArea(field+": area", *st.Stage.Area, fail)
				if st.Stage.Area.Facing != "" {
					fail("%s: area: facing belongs to a feature's areas, not a stage's", field)
				}
			}
		}
	}

	// Rules 2, 4, 6, 7, 8 over stories.
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
		if st.EffectiveWeight() <= 0 {
			fail("%s: weight must be > 0, got %v", name, st.EffectiveWeight())
		}

		// Rule 4: one localization block per declared language, no extras.
		for _, lang := range m.Languages {
			loc, ok := st.Localizations[lang]
			if !ok {
				fail("%s: missing %q localization", name, lang)
				continue
			}
			locName := fmt.Sprintf("%s %s", name, lang)
			if strings.TrimSpace(loc.Title) == "" {
				fail("%s: title must not be empty", locName)
			}
			if strings.TrimSpace(loc.Text) == "" {
				fail("%s: text must not be empty (stories must carry their text)", locName)
			}
			checkFile(locName+" audio", loc.Audio)
			if loc.Effects != "" {
				before := len(errs)
				checkFile(locName+" effects", loc.Effects)
				if len(errs) == before {
					for _, err := range effects.ValidateFile(filepath.Join(dir, filepath.FromSlash(loc.Effects)), stickerIDs, animations, expressions, featureSet, m.EffectiveSetting()) {
						fail("%s effects: %v", locName, err)
					}
				}
			}
		}
		for lang := range st.Localizations {
			if !declared[lang] {
				fail("%s: localization %q is not in declared languages", name, lang)
			}
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

	// Rule 16: each narration pack is named for a declared language, is a
	// well-formed ID of its own, and matches the audio it will carry (a
	// recording that changed needs a new asset pack).
	packIDs := map[string]string{}
	for _, lang := range slices.Sorted(maps.Keys(m.NarrationPacks)) {
		id := m.NarrationPacks[lang]
		field := fmt.Sprintf("narrationPacks[%q]", lang)
		if !declared[lang] {
			fail("%s: %q is not a declared language", field, lang)
			continue
		}
		if !narrationPackPattern.MatchString(id) {
			fail("%s: %q must be lowercase a-z0-9 with single hyphens", field, id)
			continue
		}
		if other, ok := packIDs[id]; ok {
			fail("%s: %q is also %s's narration pack", field, id, other)
		}
		packIDs[id] = lang
		if want, err := m.NarrationPackID(dir, lang); err == nil && want != id {
			fail("%s: %q is stale — the %s narration now makes %q (storyaudio install writes it)", field, id, lang, want)
		}
	}

	return errs
}

// checkArea checks that an area is [min, max] on both axes with
// 0 <= min < max <= 1.
func checkArea(field string, a StageArea, fail func(string, ...any)) {
	checkAreaWithin(field, a, 0, 1, fail)
}

// checkAreaWithin checks an area whose x may run from lo to hi (the wide
// art's side bands); y is always within the art's height.
func checkAreaWithin(field string, a StageArea, lo, hi float64, fail func(string, ...any)) {
	for _, axis := range []struct {
		name   string
		span   []float64
		lo, hi float64
	}{{"x", a.X, lo, hi}, {"y", a.Y, 0, 1}} {
		if len(axis.span) != 2 || axis.span[0] < axis.lo || axis.span[1] > axis.hi || axis.span[0] >= axis.span[1] {
			fail("%s.%s must be [min, max] with %g <= min < max <= %g, got %v", field, axis.name, axis.lo, axis.hi, axis.span)
		}
	}
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
