package main

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"

	"stickerstories/tools/internal/manifest"
)

// rigSpec is how one sticker's puppet is made and moves:
// tools/author/art/<packID>/rigs/<sticker>.json.
type rigSpec struct {
	Sticker string `json:"sticker"`
	// Called is how the animations' descriptions name the character ("the
	// bear cub"); "the <sticker>" when empty. Templates' "{the}" becomes it.
	Called string `json:"called,omitempty"`
	// Skeleton says in a few words what the rig is built for — its body
	// type, joints and how it stands in the sticker — for whoever adds
	// animations later. Not read by the tool.
	Skeleton string `json:"skeleton,omitempty"`
	// Sheets are drawn in order, each from the sticker's raw art and the
	// sheets it lists as references (the face pieces see the parts).
	Sheets []sheetSpec `json:"sheets"`
	// Parts name pieces of the drawn sheets: the piece at (or nearest to)
	// At, a point of the sheet (stickerrig parts lists them).
	Parts map[string]partSpec `json:"parts,omitempty"`
	// Bones, Slots and Faces are the rig's (manifest.PuppetRig), with
	// every coordinate in the sticker image's pixels at stickerSize.
	Bones []manifest.PuppetBone        `json:"bones,omitempty"`
	Slots []slotSpec                   `json:"slots,omitempty"`
	Faces map[string]map[string]string `json:"faces,omitempty"`
	Idle  *manifest.PuppetIdle         `json:"idle,omitempty"`
	// Animations are the sticker's animations, in the manifest's order
	// (its first move is its usual way): install writes each one's
	// sidecar, played by the puppet alone.
	Animations []animSpec `json:"animations,omitempty"`
}

type sheetSpec struct {
	ID         string   `json:"id"`
	Size       string   `json:"size"`
	Prompt     string   `json:"prompt"`
	References []string `json:"references,omitempty"`
}

// slotSpec is a slot as the rig file gives it: each attachment by its
// centre at rest and its scale from the piece (install works out the box).
type slotSpec struct {
	ID          string                `json:"id"`
	Bone        string                `json:"bone"`
	Default     string                `json:"default"`
	Attachments map[string]attachSpec `json:"attachments"`
}

type attachSpec struct {
	Part  string  `json:"part"`
	X     float64 `json:"x"`
	Y     float64 `json:"y"`
	Scale float64 `json:"scale"`
	// ScaleY, when set, stretches the height on top of Scale: a piece
	// drawn taller or flatter than it is on the sticker.
	ScaleY float64 `json:"scaleY,omitempty"`
	Rotate float64 `json:"rotate,omitempty"`
	Flip   bool    `json:"flip,omitempty"`
	Shade  float64 `json:"shade,omitempty"`
}

type partSpec struct {
	Sheet string `json:"sheet"`
	At    [2]int `json:"at"`
	// FadeTop fades the top of the piece in, over this fraction of its
	// height: a limb laid over the body then has no outline where it
	// joins it, its fur running into the body's.
	FadeTop float64 `json:"fadeTop,omitempty"`
}

// animSpec is one animation: the sidecar's fields (docs/pack-format.md,
// "Live animations"; pause, loop and particles count keys) and its keys.
// Template takes whatever the spec leaves out from a shared animation in
// templates/<type>.json ("bird.hop"): its keys, kind, timing and
// description — keys naming bones or slots the rig lacks drop those.
type animSpec struct {
	ID          string                       `json:"id"`
	Template    string                       `json:"template,omitempty"`
	Kind        string                       `json:"kind,omitempty"`
	Description string                       `json:"description,omitempty"`
	Pause       *manifest.AnimationPause     `json:"pause,omitempty"`
	Perched     bool                         `json:"perched,omitempty"`
	Idle        bool                         `json:"idle,omitempty"`
	Place       []string                     `json:"place,omitempty"`
	Loop        *manifest.FrameRange         `json:"loop,omitempty"`
	Facing      string                       `json:"facing,omitempty"`
	Stride      float64                      `json:"stride,omitempty"`
	Hops        bool                         `json:"hops,omitempty"`
	Flies       bool                         `json:"flies,omitempty"`
	Hovers      bool                         `json:"hovers,omitempty"`
	Wings       []string                     `json:"wings,omitempty"`
	On          []string                     `json:"on,omitempty"`
	Away        string                       `json:"away,omitempty"`
	Faces       string                       `json:"faces,omitempty"`
	Stays       bool                         `json:"stays,omitempty"`
	Waterline   float64                      `json:"waterline,omitempty"`
	Particles   []manifest.AnimationParticle `json:"particles,omitempty"`
	Keys        []manifest.PuppetKey         `json:"keys,omitempty"`
}

// templateFile is templates/<type>.json: animations any rig with that
// body type's bones can play.
type templateFile struct {
	// About, Bones and Slots document the body type and its names (bone
	// or slot id → what it is), which rigs of that type use.
	About      string            `json:"about,omitempty"`
	Bones      map[string]string `json:"bones"`
	Slots      map[string]string `json:"slots,omitempty"`
	Animations []animSpec        `json:"animations"`
}

// templatesDir is where the shared animations are, beside this tool.
func templatesDir() string { return filepath.Join("author", "stickerrig", "templates") }

func loadTemplates() (map[string]animSpec, error) {
	out := map[string]animSpec{}
	files, _ := filepath.Glob(filepath.Join(templatesDir(), "*.json"))
	for _, f := range files {
		var t templateFile
		if err := readJSONStrict(f, &t); err != nil {
			return nil, fmt.Errorf("%s: %w", f, err)
		}
		typ := strings.TrimSuffix(filepath.Base(f), ".json")
		for _, a := range t.Animations {
			out[typ+"."+a.ID] = a
		}
	}
	return out, nil
}

// resolve fills what the spec leaves out from its template, names the
// character in the description, and drops the template's poses of bones
// and slots the rig does not have (returned as notes).
func (r *rigSpec) resolve(a animSpec, templates map[string]animSpec) (animSpec, []string, error) {
	var notes []string
	if a.Template != "" {
		t, ok := templates[a.Template]
		if !ok {
			return a, nil, fmt.Errorf("animation %s: no template %q (templates/<type>.json)", a.ID, a.Template)
		}
		if a.Kind == "" {
			a.Kind = t.Kind
		}
		if a.Description == "" {
			a.Description = t.Description
		}
		if a.Pause == nil && t.Pause != nil {
			p := *t.Pause
			a.Pause = &p
		}
		if a.Loop == nil {
			a.Loop = t.Loop
		}
		if a.Facing == "" {
			a.Facing = t.Facing
		}
		if a.Stride == 0 {
			a.Stride = t.Stride
		}
		a.Hops = a.Hops || t.Hops
		a.Flies = a.Flies || t.Flies
		a.Hovers = a.Hovers || t.Hovers
		if a.Wings == nil {
			a.Wings = t.Wings
		}
		a.Perched = a.Perched || t.Perched
		a.Idle = a.Idle || t.Idle
		if a.On == nil {
			a.On = t.On
		}
		if a.Away == "" {
			a.Away = t.Away
		}
		if a.Faces == "" {
			a.Faces = t.Faces
		}
		if a.Place == nil {
			a.Place = t.Place
		}
		if a.Particles == nil {
			a.Particles = t.Particles
		}
		if a.Keys == nil {
			a.Keys, notes = r.fit(t.Keys)
		}
	}
	called := r.Called
	if called == "" {
		called = "the " + r.Sticker
	}
	a.Description = strings.ReplaceAll(a.Description, "{the}", called)
	if a.Pause != nil {
		p := *a.Pause
		p.Shows = strings.ReplaceAll(p.Shows, "{the}", called)
		a.Pause = &p
	}
	if strings.TrimSpace(a.Description) == "" {
		return a, nil, fmt.Errorf("animation %s: needs a description (or a template with one)", a.ID)
	}
	if len(a.Keys) < 2 {
		return a, nil, fmt.Errorf("animation %s: needs at least two keys (or a template)", a.ID)
	}
	return a, notes, nil
}

// fit keeps a template's poses of the bones and slots this rig has.
func (r *rigSpec) fit(keys []manifest.PuppetKey) ([]manifest.PuppetKey, []string) {
	bones := map[string]bool{}
	for _, b := range r.Bones {
		bones[b.ID] = true
	}
	slots := map[string]slotSpec{}
	for _, s := range r.Slots {
		slots[s.ID] = s
	}
	dropped := map[string]bool{}
	var out []manifest.PuppetKey
	for _, k := range keys {
		nk := manifest.PuppetKey{Hold: k.Hold, Ease: k.Ease}
		for id, pose := range k.Bones {
			if !bones[id] {
				dropped["bone "+id] = true
				continue
			}
			if nk.Bones == nil {
				nk.Bones = map[string]manifest.BonePose{}
			}
			nk.Bones[id] = pose
		}
		for id, att := range k.Slots {
			s, ok := slots[id]
			if _, has := s.Attachments[att]; !ok || (!has && att != manifest.PuppetHidden) {
				// A template names every kind of eye and mouth; a rig has
				// some. Not worth a note.
				continue
			}
			if nk.Slots == nil {
				nk.Slots = map[string]string{}
			}
			nk.Slots[id] = att
		}
		out = append(out, nk)
	}
	var notes []string
	for d := range dropped {
		notes = append(notes, d)
	}
	sort.Strings(notes)
	return out, notes
}

func (r *rigSpec) check(c *ctxt) error {
	if c.sticker(r.Sticker) == nil {
		return fmt.Errorf("sticker %q is not in the manifest", r.Sticker)
	}
	var sheets []string
	for _, sh := range r.Sheets {
		if sh.ID == "" || sh.Size == "" || sh.Prompt == "" {
			return fmt.Errorf("every sheet needs an id, a size and a prompt")
		}
		for _, ref := range sh.References {
			if !slices.Contains(sheets, ref) {
				return fmt.Errorf("sheet %s: reference %q must be a sheet drawn before it", sh.ID, ref)
			}
		}
		sheets = append(sheets, sh.ID)
	}
	for name, p := range r.Parts {
		if !slices.Contains(sheets, p.Sheet) {
			return fmt.Errorf("part %s: sheet %q is not one of the rig's", name, p.Sheet)
		}
	}
	ids := map[string]bool{}
	for _, a := range r.Animations {
		if a.ID == "" || ids[a.ID] {
			return fmt.Errorf("animation ids must be set and unique (%q)", a.ID)
		}
		ids[a.ID] = true
	}
	// A sheet and the preview of an animation (or the rest) share a file
	// name, out/rigs/<sticker>.<id>.png: preview would overwrite the sheet.
	for _, sh := range sheets {
		if ids[sh] || sh == "rest" {
			return fmt.Errorf("sheet %s: an animation's preview has that name; name the sheet otherwise", sh)
		}
	}
	return nil
}

// loadRigs reads every rigs/<sticker>.json of the art directory.
func loadRigs(dir string) ([]rigSpec, error) {
	if _, err := os.Stat(dir); err != nil {
		return nil, fmt.Errorf("no rigs: %w", err)
	}
	files, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return nil, err
	}
	var out []rigSpec
	for _, f := range files {
		var r rigSpec
		if err := readJSONStrict(f, &r); err != nil {
			return nil, fmt.Errorf("%s: %w", f, err)
		}
		if want := strings.TrimSuffix(filepath.Base(f), ".json"); r.Sticker != want {
			return nil, fmt.Errorf("%s: sticker %q must match the file name", f, r.Sticker)
		}
		out = append(out, r)
	}
	return out, nil
}
