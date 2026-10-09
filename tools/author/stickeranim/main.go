// Command stickeranim produces frame animations ("live" stickers) for a
// pack's stickers with the OpenAI Images API and installs them into the
// pack (docs/pack-format.md, "Live animations"): each sticker's action,
// which stories cue (whole, or held on its pause frame and resumed), and
// its move — the walk, hop, flight or sprout its entrance plays.
//
// Usage:
//
//	stickeranim render  -pack ../packs/forest [-only frog|backflip-fly] [-quality high]
//	                    [-dry-run] [-force]
//	stickeranim install -pack ../packs/forest [-bump]
//
// anim.json (tools/author/art/<packID>/anim.json) describes each animation
// as one or more sprite sheets — a grid of frames the edits model draws in
// a single call, with the sticker's raw art as the reference so the
// character stays the same, and the previous sheet as a second reference
// so a later sheet continues it. The cells are then registered on the
// part that stays still (the "base": a lily pad, the feet), given the
// pack's sticker border and finish, and packed into one sheet PNG plus a
// JSON the app reads (docs in the README). Outputs land in <art>/out/anims/
// and are cached by fingerprint: a prompt change regenerates a sheet, a
// timing or finishing change only re-assembles the kept raws.
//
// The API key is OPENAI_API_KEY from tools/.env. Dev-time only.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"math"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"stickerstories/tools/internal/dotenv"
	"stickerstories/tools/internal/manifest"
	"stickerstories/tools/internal/openai"
	"stickerstories/tools/internal/stickerimg"
)

const (
	toolVersion = "1"
	// assembleVersion changes whenever the registration or finishing of
	// kept raw sheets changes, so they are re-assembled without new calls.
	assembleVersion = "18"
	editModel       = "gpt-image-2.5-sunburst"
	defaultQual     = "high"
	defaultHold     = 1.0 / 12
)

// artConfig is the part of stickerart's art.json this tool needs: the
// pack's style and each sticker's description go into every prompt, and
// the sticker settings give the frames the same border and finish.
type artConfig struct {
	Style       string             `json:"style"`
	StickerSize int                `json:"stickerSize"`
	Border      float64            `json:"border"`
	Margin      float64            `json:"margin"`
	Finish      *stickerimg.Finish `json:"finish,omitempty"`
	// SizeInArt: stickers are drawn at their size class's share of their
	// image (stickerart; manifest.DrawnFill) — the scaffold puts them there.
	SizeInArt bool `json:"sizeInArt,omitempty"`
	Stickers  []struct {
		ID     string `json:"id"`
		Prompt string `json:"prompt"`
		Size   string `json:"size,omitempty"`
		// Prop is what stickerart removed from the sticker (a lily pad): the
		// frames are drawn without it, from the art without it.
		Prop *struct {
			Remove string `json:"remove"`
		} `json:"prop,omitempty"`
	} `json:"stickers"`
}

// fill is the share of its image a sticker is drawn at (0: the margin).
func (c artConfig) fill(stickerID string) float64 {
	if !c.SizeInArt {
		return 0
	}
	for _, s := range c.Stickers {
		if s.ID == stickerID {
			if f, ok := manifest.DrawnFill[s.Size]; ok {
				return f
			}
		}
	}
	return manifest.DrawnFill["medium"]
}

func (c artConfig) finish() stickerimg.Finish {
	if c.Finish != nil {
		return *c.Finish
	}
	return stickerimg.DefaultFinish
}

// animConfig is anim.json.
type animConfig struct {
	// Columns of the assembled sheet (4) and a cap on its size in px
	// (4096; the frames are downscaled uniformly to fit).
	Columns  int `json:"columns"`
	MaxSheet int `json:"maxSheet"`
	// StickerPx is the resolution the frames are drawn at, as the size of
	// the sticker they would make (the rest frame's art fills a sticker
	// this big): 512 is plenty for a sticker on screen, and a sheet's
	// texture memory goes with its square. 0 = the pack's sticker size.
	StickerPx int `json:"stickerPx,omitempty"`
	// Scaffold draws every sheet over a scaffold: a sheet whose cells each
	// hold the sticker exactly as its image has it — at its size, in its
	// place — which the model re-poses cell by cell, so every frame keeps
	// the sticker's size and place; the frames are then assembled as drawn,
	// in their cells (stickerimg.CellAnimation), and each is checked
	// (<key>.qa.json). Every new pack sets it (docs/pack-art.md).
	Scaffold   bool       `json:"scaffold,omitempty"`
	Animations []animSpec `json:"animations"`
	Notes      any        `json:"notes,omitempty"`
}

type animSpec struct {
	ID      string `json:"id"`
	Sticker string `json:"sticker"`
	// Description is the one-line summary of the whole animation; Base is
	// what stays still while the character moves ("the lily pad").
	Description string `json:"description"`
	// Story is what the animation shows, in plain words for story authors
	// (the sidecar's description, which stories cue it by); absent means
	// Description. Set it when Description carries drawing instructions.
	Story  string      `json:"story,omitempty"`
	Base   string      `json:"base"`
	Sheets []sheetSpec `json:"sheets"`
	// Hold is how long each frame shows, in seconds, one entry per frame
	// across all sheets; absent means 1/12 s each.
	Hold []float64 `json:"hold,omitempty"`
	// RestFrames are the 1-based frames that show the sticker's own pose;
	// they take the sticker's real art, so the animation starts and ends
	// on exactly the sticker (needs the raw from stickerart).
	RestFrames []int `json:"restFrames,omitempty"`
	// RestFromSticker (default true) puts the sticker's own art in the
	// rest frames. False keeps the generator's drawing there: the rest
	// frames still match the sheets' sizes, and the app's crossfade
	// dissolves the still sticker into the drawing, so a character the
	// generator redrew with slightly other proportions changes smoothly
	// instead of cutting to the drawing one frame later.
	RestFromSticker *bool `json:"restFromSticker,omitempty"`
	// Particles are bursts the frames fire as they first show — a
	// landing's dust, a touchdown, a splash — since the frames never draw
	// particles themselves: {"frame": 7, "effect": "dust-puff", "at":
	// "base"}, frames 1-based, at "base" (the bottom middle of the
	// sticker's drawing: its feet), "centre", or [x, y] on the sticker
	// image (fractions, top-left origin); optional intensity and color.
	Particles []particleSpec `json:"particles,omitempty"`
	// Room (scaffold only, default 1) is how much bigger than the
	// sticker's box each cell is: the sticker sits in the middle at its
	// size and the animation may reach past its box — a rocket's flame
	// below a ship that fills its box. 1 keeps everything within the box.
	Room float64 `json:"room,omitempty"`
	// Normalize (default false) rescales frames so the base keeps its
	// width: only for a base object that is the widest thing at the
	// bottom in every pose (a lily pad, a perch); feet, a curling body or
	// spread wings make the measure jump and the frame pop in size.
	Normalize bool `json:"normalize,omitempty"`
	// Kind is "action" (the default: a moment stories cue) or "move" (how
	// the character gets about; its entrance plays it).
	Kind string `json:"kind,omitempty"`
	// Pause (actions) is the 1-based frame the action can stop on and what
	// it shows there, for story authors ({snail:live hold}).
	Pause *struct {
		Frame int    `json:"frame"`
		Shows string `json:"shows"`
	} `json:"pause,omitempty"`
	// Loop (moves) is the 1-based run of frames repeated while the
	// character travels; Facing the way they travel (left/right), Stride
	// how far one loop carries it in sticker widths, Hops that the loop
	// is a hop drawn in place (the app adds the arc).
	Loop *struct {
		From int `json:"from"`
		To   int `json:"to"`
	} `json:"loop,omitempty"`
	Facing string  `json:"facing,omitempty"`
	Stride float64 `json:"stride,omitempty"`
	Hops   bool    `json:"hops,omitempty"`
	// Flies (moves) says the loop is a flight; On lists the features a
	// story that brings the sticker in this way lands it on (a second
	// move: the duckling's swim, the pond). Neither changes the frames:
	// install writes them into the sidecar.
	Flies bool     `json:"flies,omitempty"`
	On    []string `json:"on,omitempty"`
	// Perched (actions) says the character sits on something in it: a
	// story lands a flyer before it plays it. Written at install too.
	Perched bool `json:"perched,omitempty"`
	// Place (actions) are the features it happens at (the woodpecker's
	// tap: the trunks). Written at install too.
	Place []string `json:"place,omitempty"`
	// Register is how frames are laid on each other: "feet" (the default:
	// each frame matched on the one before, its bottom kept on one ground
	// line — a character sitting or walking), "body" (matched both ways —
	// a flight, or the snail whose body goes into its shell) or "base"
	// (on the base row, without matching: the old way, for a lily pad).
	Register string `json:"register,omitempty"`
}

func (a animSpec) kind() string {
	if a.Kind == "" {
		return manifest.KindAction
	}
	return a.Kind
}

func (a animSpec) register() string {
	if a.Register != "" {
		return a.Register
	}
	return stickerimg.RegisterFeet
}

func (a animSpec) normalize() bool { return a.Normalize }

func (a animSpec) restFromSticker() bool { return a.RestFromSticker == nil || *a.RestFromSticker }

type sheetSpec struct {
	Columns int      `json:"columns"`
	Rows    int      `json:"rows"`
	Size    string   `json:"size"` // e.g. 3072x1536
	Frames  []string `json:"frames"`
	// Hint is extra guidance for this sheet only (a size or framing
	// correction after a bad result); it changes only this sheet's
	// fingerprint.
	Hint string `json:"hint,omitempty"`
}

// particleSpec is one burst in anim.json (animSpec.Particles).
type particleSpec struct {
	Frame     int             `json:"frame"`
	Effect    string          `json:"effect"`
	At        json.RawMessage `json:"at"`
	Intensity *float64        `json:"intensity,omitempty"`
	Color     string          `json:"color,omitempty"`
}

// sidecarParticles resolves the bursts onto the sticker image: "base" is
// the bottom middle of its drawing, "centre" its middle, [x, y] as given.
func sidecarParticles(specs []particleSpec, sticker *image.RGBA) ([]manifest.AnimationParticle, error) {
	box := stickerimg.Bounds(sticker, 8)
	w, h := float64(sticker.Bounds().Dx()), float64(sticker.Bounds().Dy())
	var out []manifest.AnimationParticle
	for _, p := range specs {
		var x, y float64
		var named string
		var xy []float64
		switch {
		case json.Unmarshal(p.At, &named) == nil && named == "base":
			x, y = float64(box.Min.X+box.Max.X)/2/w, float64(box.Max.Y)/h
		case json.Unmarshal(p.At, &named) == nil && named == "centre":
			x, y = float64(box.Min.X+box.Max.X)/2/w, float64(box.Min.Y+box.Max.Y)/2/h
		case json.Unmarshal(p.At, &xy) == nil && len(xy) == 2:
			x, y = xy[0], xy[1]
		default:
			return nil, fmt.Errorf("particle at frame %d: at must be \"base\", \"centre\" or [x, y], got %s", p.Frame, p.At)
		}
		out = append(out, manifest.AnimationParticle{Frame: p.Frame - 1, Effect: p.Effect,
			X: math.Round(x*1e4) / 1e4, Y: math.Round(y*1e4) / 1e4, Intensity: p.Intensity, Color: p.Color})
	}
	return out, nil
}

// room is how much bigger than the sticker's box a scaffold cell is.
func (a animSpec) room() float64 {
	if a.Room < 1 {
		return 1
	}
	return a.Room
}

func (a animSpec) frameCount() int {
	n := 0
	for _, s := range a.Sheets {
		n += len(s.Frames)
	}
	return n
}

func (a animSpec) key() string { return a.Sticker + "." + a.ID }

// storyDescription is the sidecar's description: what the animation
// shows, for story authors.
func (a animSpec) storyDescription() string {
	if s := strings.TrimSpace(a.Story); s != "" {
		return s
	}
	return strings.TrimSpace(a.Description)
}

// unit rounds a pixel box to fractions of its image (5 decimals is well
// under a pixel at any size that matters).
func unit(r image.Rectangle, in image.Point) manifest.UnitBox {
	round := func(v float64) float64 { return math.Round(v*1e5) / 1e5 }
	return manifest.UnitBox{
		X: round(float64(r.Min.X) / float64(in.X)), Y: round(float64(r.Min.Y) / float64(in.Y)),
		Width: round(float64(r.Dx()) / float64(in.X)), Height: round(float64(r.Dy()) / float64(in.Y)),
	}
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	dotenv.LoadFirst(".env", filepath.Join("..", ".env"))
	var err error
	switch os.Args[1] {
	case "render":
		err = runRender(os.Args[2:])
	case "install":
		err = runInstall(os.Args[2:])
	case "review":
		err = runReview(os.Args[2:])
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "✗ %v\n", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: stickeranim render|review|install -pack <pack-dir> [flags]  (see -h on each)")
	os.Exit(2)
}

type ctxt struct {
	pack    *manifest.Manifest
	packDir string
	artDir  string
	art     *artConfig
	cfg     *animConfig
}

func load(packDir, artDir string) (*ctxt, error) {
	if packDir == "" {
		return nil, errors.New("-pack is required")
	}
	m, err := manifest.Load(packDir)
	if err != nil {
		return nil, err
	}
	if artDir == "" {
		artDir = filepath.Join("author", "art", m.ID)
	}
	c := &ctxt{pack: m, packDir: packDir, artDir: artDir, art: &artConfig{}, cfg: &animConfig{}}
	if err := readJSON(filepath.Join(artDir, "art.json"), c.art); err != nil {
		return nil, fmt.Errorf("art.json (stickerart's; the prompts need the pack style): %w", err)
	}
	if c.art.StickerSize == 0 {
		c.art.StickerSize = 1024
	}
	if c.art.Border == 0 {
		c.art.Border = 0.025
	}
	if c.art.Margin == 0 {
		c.art.Margin = 0.03
	}
	if err := readJSON(filepath.Join(artDir, "anim.json"), c.cfg); err != nil {
		return nil, fmt.Errorf("anim.json: %w", err)
	}
	if c.cfg.Columns == 0 {
		c.cfg.Columns = 4
	}
	if c.cfg.MaxSheet == 0 {
		c.cfg.MaxSheet = 4096
	}
	for _, a := range c.cfg.Animations {
		if a.ID == "" || a.Sticker == "" || len(a.Sheets) == 0 {
			return nil, fmt.Errorf("anim.json: every animation needs id, sticker and sheets")
		}
		if c.stickerImage(a.Sticker) == "" {
			return nil, fmt.Errorf("anim.json: %s: sticker %q is not in the manifest", a.key(), a.Sticker)
		}
		for i, s := range a.Sheets {
			if s.Columns*s.Rows != len(s.Frames) || s.Size == "" {
				return nil, fmt.Errorf("anim.json: %s sheet %d: columns×rows must equal the number of frames, and size is required", a.key(), i+1)
			}
		}
		if len(a.Hold) != 0 && len(a.Hold) != a.frameCount() {
			return nil, fmt.Errorf("anim.json: %s: hold has %d entries for %d frames", a.key(), len(a.Hold), a.frameCount())
		}
		for _, f := range a.RestFrames {
			if f < 1 || f > a.frameCount() {
				return nil, fmt.Errorf("anim.json: %s: restFrames entry %d is out of 1–%d", a.key(), f, a.frameCount())
			}
		}
		switch a.kind() {
		case manifest.KindAction:
			if a.Loop != nil || a.Facing != "" || a.Stride != 0 || a.Hops || a.Flies || len(a.On) > 0 {
				return nil, fmt.Errorf("anim.json: %s: loop, facing, stride, hops, flies and on are for moves", a.key())
			}
			if a.Pause != nil && (a.Pause.Frame < 2 || a.Pause.Frame > a.frameCount()-1 || strings.TrimSpace(a.Pause.Shows) == "") {
				return nil, fmt.Errorf("anim.json: %s: pause needs a middle frame (2–%d) and what it shows", a.key(), a.frameCount()-1)
			}
		case manifest.KindMove:
			if a.Pause != nil {
				return nil, fmt.Errorf("anim.json: %s: pause is for actions", a.key())
			}
			if l := a.Loop; l != nil && (l.From < 2 || l.To < l.From || l.To > a.frameCount()) {
				return nil, fmt.Errorf("anim.json: %s: loop must be frames within 2–%d (frame 1 is the rest pose)", a.key(), a.frameCount())
			}
		default:
			return nil, fmt.Errorf("anim.json: %s: kind %q must be action or move", a.key(), a.Kind)
		}
		switch a.register() {
		case stickerimg.RegisterBase, stickerimg.RegisterBody, stickerimg.RegisterFeet:
		default:
			return nil, fmt.Errorf("anim.json: %s: register %q must be base, feet or body", a.key(), a.Register)
		}
	}
	return c, nil
}

func readJSON(path string, v any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, v)
}

// stickerImage is the installed sticker's path in the pack, "" if unknown.
func (c *ctxt) stickerImage(id string) string {
	for _, s := range c.pack.Stickers {
		if s.ID == id {
			return filepath.Join(c.packDir, s.Image)
		}
	}
	return ""
}

func (c *ctxt) stickerPrompt(id string) string {
	for _, s := range c.art.Stickers {
		if s.ID == id {
			if s.Prop != nil {
				return fmt.Sprintf("%s (The sticker no longer has %s: the reference shows the character on its own, and so do the frames — nothing under it.)", s.Prompt, s.Prop.Remove)
			}
			return s.Prompt
		}
	}
	return ""
}

func client() (*openai.Client, error) {
	key := os.Getenv("OPENAI_API_KEY")
	if key == "" {
		return nil, errors.New("OPENAI_API_KEY is not set (put it in tools/.env)")
	}
	c := openai.New(key)
	if os.Getenv("STICKERART_DEBUG") != "" {
		c.Log = func(s string) { fmt.Fprintln(os.Stderr, "  ·", s) }
	}
	return c, nil
}

// ---------- render ----------

type renderOpts struct {
	quality, fidelity string
	only              map[string]bool
	force, dry        bool
	parallel          int
}

type renderer struct {
	c       *ctxt
	oa      *openai.Client
	o       renderOpts
	ctx     context.Context
	mu      sync.Mutex
	fps     map[string]string // output path → fingerprint (out/anims/render.json)
	spent   openai.Usage
	calls   int
	planned []string
}

func (r *renderer) say(format string, args ...any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	fmt.Printf(format+"\n", args...)
}

// charge records a call's usage and returns a short cost label.
func (r *renderer) charge(u openai.Usage) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.spent.Add(u)
	r.calls++
	return fmt.Sprintf("$%.3f", u.Cost(openai.DefaultPrices))
}

func (r *renderer) out(parts ...string) string {
	p := filepath.Join(append([]string{r.c.artDir, "out", "anims"}, parts...)...)
	os.MkdirAll(filepath.Dir(p), 0o755)
	return p
}

func hashOf(parts ...string) string {
	h := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return hex.EncodeToString(h[:])[:16]
}

func hashFile(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return "missing"
	}
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])[:16]
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

func runRender(args []string) error {
	fs := flag.NewFlagSet("render", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	artDir := fs.String("art", "", "art directory (default author/art/<packID>)")
	only := fs.String("only", "", "comma-separated animation ids, sticker ids or sticker.animation keys")
	quality := fs.String("quality", defaultQual, "low | medium | high | xhigh | max")
	fidelity := fs.String("fidelity", "", "input_fidelity for the reference (high | low) on models that take it; gpt-image-2.5 does not")
	force := fs.Bool("force", false, "re-render even if nothing changed")
	dry := fs.Bool("dry-run", false, "list what would be generated; no API calls")
	parallel := fs.Int("parallel", 3, "animations rendered concurrently (each one's sheets stay sequential)")
	fs.Parse(args)
	c, err := load(*packDir, *artDir)
	if err != nil {
		return err
	}
	o := renderOpts{quality: *quality, fidelity: *fidelity, force: *force, dry: *dry, parallel: *parallel}
	if *only != "" {
		o.only = map[string]bool{}
		for _, id := range strings.Split(*only, ",") {
			o.only[strings.TrimSpace(id)] = true
		}
	}
	var oa *openai.Client
	if !o.dry {
		if oa, err = client(); err != nil {
			return err
		}
	}
	r := &renderer{c: c, oa: oa, o: o, ctx: context.Background(), fps: map[string]string{}}
	if data, err := os.ReadFile(r.out("render.json")); err == nil {
		json.Unmarshal(data, &r.fps)
	}
	var (
		failures []string
		wg       sync.WaitGroup
		queue    = make(chan animSpec)
	)
	workers := o.parallel
	if workers < 1 || o.dry {
		workers = 1
	}
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for a := range queue {
				if err := r.animation(a); err != nil {
					r.mu.Lock()
					failures = append(failures, a.key()+": "+err.Error())
					r.mu.Unlock()
					r.say("✗ %s: %v", a.key(), err)
				}
			}
		}()
	}
	for _, a := range c.cfg.Animations {
		if o.only != nil && !o.only[a.ID] && !o.only[a.Sticker] && !o.only[a.key()] {
			continue
		}
		queue <- a
	}
	close(queue)
	wg.Wait()
	if o.dry {
		fmt.Printf("\nDry run: %d step(s) at quality %s:\n  %s\n", len(r.planned), o.quality, strings.Join(r.planned, "\n  "))
		return nil
	}
	if r.calls > 0 {
		fmt.Printf("\nThis run: %d API calls, %d image-in + %d text-in + %d output tokens ≈ $%.2f (list prices)\n",
			r.calls, r.spent.InputDetails.ImageTokens, r.spent.InputDetails.TextTokens, r.spent.OutputTokens, r.spent.Cost(openai.DefaultPrices))
	}
	if len(failures) > 0 {
		return fmt.Errorf("%d failure(s) (rerun to retry just those):\n  %s", len(failures), strings.Join(failures, "\n  "))
	}
	fmt.Printf("Review %s, then: stickeranim install -pack %s\n", r.out(), c.packDir)
	return nil
}

func (r *renderer) upToDate(path, fp string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return !r.o.force && exists(path) && r.fps[path] == fp
}

func (r *renderer) done(path, fp string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.fps[path] = fp
	data, _ := json.MarshalIndent(r.fps, "", "  ")
	os.WriteFile(r.out("render.json"), append(data, '\n'), 0o644)
}

// rawPath is where stickerart keeps the sticker's raw art (no border):
// without its prop when stickerart removed one.
func (r *renderer) rawPath(stickerID string) string {
	noprop := filepath.Join(r.c.artDir, "out", "stickers", stickerID+".noprop.png")
	if exists(noprop) {
		return noprop
	}
	return filepath.Join(r.c.artDir, "out", "stickers", stickerID+".raw.png")
}

// reference returns the sticker's raw art downscaled for the prompt, or
// the finished sticker when there is no raw.
func (r *renderer) reference(stickerID string) ([]byte, string, error) {
	raw := r.rawPath(stickerID)
	path := raw
	if !exists(raw) {
		path = r.c.stickerImage(stickerID)
		r.say("  (no raw for %s; using the finished sticker as the reference — its border may leak into the frames)", stickerID)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, "", err
	}
	if small, err := downscale(data, 768); err == nil {
		data = small
	}
	return data, hashFile(path), nil
}

// animation renders every sheet that is out of date, then assembles the
// animation if any input changed.
func (r *renderer) animation(a animSpec) error {
	art := r.c.art
	ref, refFP, err := r.reference(a.Sticker)
	if err != nil {
		return err
	}
	var (
		raws     []string
		genFPs   []string
		prev     []byte
		prevLast *image.RGBA // the previous sheet's last cell (scaffold)
		first    = 1
		total    = a.frameCount()
		changed  = false
		rest     *image.RGBA
	)
	if r.c.cfg.Scaffold {
		if rest, err = r.restCell(a.Sticker); err != nil {
			return err
		}
	}
	for i, sh := range a.Sheets {
		// Every sheet after the first carries on from the previous one, so
		// the prompt (and the fingerprint) is the same with or without the
		// reference loaded (dry runs load none).
		prompt := sheetPrompt(art.Style, r.c.stickerPrompt(a.Sticker), a, sh, first, total, i > 0)
		sheetRefFP := refFP
		if r.c.cfg.Scaffold {
			prompt = scaffoldPrompt(art.Style, r.c.stickerPrompt(a.Sticker), a, sh, first, total, i > 0)
			sheetRefFP = hashOf(refFP, "scaffold", fmt.Sprint(art.fill(a.Sticker)), fmt.Sprint(a.room()))
		}
		// The previous sheet is a reference for this one, but it is not in
		// the fingerprint: redoing sheet 1 must not throw away a good sheet 2
		// (-force redoes everything).
		genFP := hashOf(toolVersion, "sheet", sheetRefFP, prompt, sh.Size, r.o.quality, r.o.fidelity, editModel)
		raw := r.out(fmt.Sprintf("%s.sheet%d.raw.png", a.key(), i+1))
		switch {
		case r.upToDate(raw, genFP):
			r.say("· %s sheet %d up to date", a.key(), i+1)
		case r.o.dry:
			r.planned = append(r.planned, fmt.Sprintf("%s sheet %d (%s, %d frames, transparent)", a.key(), i+1, sh.Size, len(sh.Frames)))
			fmt.Printf("--- %s sheet %d prompt ---\n%s\n\n", a.key(), i+1, prompt)
		default:
			r.say("▶ %s sheet %d (frames %d–%d)", a.key(), i+1, first, first+len(sh.Frames)-1)
			started := time.Now()
			refs := [][]byte{ref}
			if prev != nil {
				refs = append(refs, prev)
			}
			if r.c.cfg.Scaffold {
				scaffold, err := r.scaffold(roomy(rest, a.room()), prevLast, sh)
				if err != nil {
					return err
				}
				refs = [][]byte{scaffold}
				if prev != nil {
					refs = append(refs, prev)
				}
			}
			img, err := r.oa.Edit(r.ctx, openai.ImageRequest{Model: editModel, Prompt: prompt, Size: sh.Size, Quality: r.o.quality, Background: "transparent", Fidelity: r.o.fidelity, References: refs})
			if err != nil {
				return fmt.Errorf("sheet %d: %w", i+1, err)
			}
			if err := os.WriteFile(raw, img.PNG, 0o644); err != nil {
				return err
			}
			r.done(raw, genFP)
			r.say("✓ %s sheet %d (%s, %.0fs)", a.key(), i+1, r.charge(img.Usage), time.Since(started).Seconds())
			changed = true
		}
		raws = append(raws, raw)
		genFPs = append(genFPs, genFP)
		first += len(sh.Frames)
		if !r.o.dry {
			if prev, err = os.ReadFile(raw); err != nil {
				return err
			}
			if r.c.cfg.Scaffold {
				img, err := stickerimg.Decode(prev)
				if err != nil {
					return err
				}
				cells := stickerimg.SplitExact(img, sh.Columns, sh.Rows)
				prevLast = cells[len(sh.Frames)-1]
			}
			if small, err := downscale(prev, 1024); err == nil {
				prev = small
			}
		}
	}

	stickerPath := r.c.stickerImage(a.Sticker)
	hold := a.Hold
	if len(hold) == 0 {
		hold = make([]float64, total)
		for i := range hold {
			hold[i] = defaultHold
		}
	}
	asmFP := hashOf(append([]string{assembleVersion, fmt.Sprint(r.c.cfg.Scaffold, art.fill(a.Sticker), a.room(), scaffoldAssembly), hashFile(stickerPath), hashFile(r.rawPath(a.Sticker)), fmt.Sprint(r.c.cfg.Columns, r.c.cfg.MaxSheet, r.c.cfg.StickerPx, art.StickerSize, art.Border, art.Margin, art.finish(), hold, a.RestFrames, a.normalize(), a.restFromSticker(), a.register(), a.Loop, a.kind(), a.Pause, a.Facing, a.Stride, a.Hops, a.Story)}, genFPs...)...)
	if len(a.Particles) > 0 {
		// Only when there are some, so animations without keep their
		// fingerprints; a change re-writes the sidecar, free.
		data, _ := json.Marshal(a.Particles)
		asmFP = hashOf(asmFP, "particles", string(data))
	}
	sheetPath, jsonPath := r.out(a.key()+".png"), r.out(a.key()+".json")
	if !changed && r.upToDate(sheetPath, asmFP) && r.upToDate(jsonPath, asmFP) {
		r.say("· %s assembled sheet up to date", a.key())
		return nil
	}
	if r.o.dry {
		r.planned = append(r.planned, fmt.Sprintf("%s assemble %d frames (no API call)", a.key(), total))
		return nil
	}
	if err := r.assemble(a, raws, stickerPath, hold, sheetPath, jsonPath); err != nil {
		return err
	}
	r.done(sheetPath, asmFP)
	r.done(jsonPath, asmFP)
	return nil
}

// sheetPrompt asks for one sheet: the character, the grid, the frames it
// holds and the rules that make the cells usable.
func sheetPrompt(style, sticker string, a animSpec, sh sheetSpec, first, total int, continued bool) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n\n", style)
	fmt.Fprintf(&b, "The first attached image is a sticker character: %s Draw a sprite sheet of this exact character — the same design, colours, proportions, features and line, with %s exactly as in the reference — as a grid of %d columns by %d rows: %d frames of equal size, read left to right and then top to bottom, showing consecutive moments of one animation: %s",
		strings.TrimSpace(sticker), a.Base, sh.Columns, sh.Rows, len(sh.Frames), strings.TrimSpace(a.Description))
	if continued {
		b.WriteString(" The second attached image is the previous sheet of this same animation; these frames carry straight on from its last frame, in the same design, scale and placement.")
	}
	fmt.Fprintf(&b, "\n\nFrames %d–%d of %d:\n", first, first+len(sh.Frames)-1, total)
	for i, f := range sh.Frames {
		fmt.Fprintf(&b, "%d. %s\n", first+i, strings.TrimSpace(f))
	}
	if a.kind() == manifest.KindMove && a.Loop != nil {
		fmt.Fprintf(&b, "\nFrames %d–%d are one seamless cycle: frame %d follows on from frame %d exactly, so they can repeat for ever. The character moves in place, as if on a treadmill: it does not travel across its cell.", a.Loop.From, a.Loop.To, a.Loop.From, a.Loop.To)
	}
	if a.kind() == manifest.KindMove {
		b.WriteString(" Draw the character small in its cell — about half the cell's width at rest — so that even its most stretched pose (legs out, wings spread) stays well inside the cell.")
	}
	if continued {
		b.WriteString(" The first frame of this sheet shows exactly the same pose, at exactly the same size, as the last frame of the previous sheet.")
	}
	fmt.Fprintf(&b, "\nRules: draw every frame at exactly the same scale, with %s the same size and in the same place in every cell — centred horizontally and resting on the bottom part of the cell — so that only the character moves relative to it. Consecutive frames are close together — each one a small step on from the one before — so the animation plays smoothly. Keep each frame well inside its own cell with clear empty space around it: nothing touches or crosses a cell boundary, and the frames are spaced evenly. No grid lines, no cell borders, no boxes, no numbers, no labels, no text, no ground, no shadow, no background — a fully transparent background everywhere except the drawing itself.", a.Base)
	if h := strings.TrimSpace(sh.Hint); h != "" {
		fmt.Fprintf(&b, " %s", h)
	}
	return b.String()
}

// assemble registers the raw sheets' cells into one bordered sheet and
// writes it with its JSON and an onion-skin overlay of every frame (for
// checking the registration by eye).
func (r *renderer) assemble(a animSpec, raws []string, stickerPath string, hold []float64, sheetPath, jsonPath string) error {
	art := r.c.art
	var cells []*image.RGBA
	for i, raw := range raws {
		data, err := os.ReadFile(raw)
		if err != nil {
			return err
		}
		img, err := stickerimg.Decode(data)
		if err != nil {
			return fmt.Errorf("sheet %d: %w", i+1, err)
		}
		if r.c.cfg.Scaffold {
			// Drawn over a scaffold: every drawing stays in its cell, on the
			// nominal grid, and there are only as many as the sheet has
			// frames. The generator keeps one size within a sheet but not the
			// scaffold's own, so the frames are then registered as usual —
			// each sheet sized on its first cell, a pose it shares with the
			// sticker or the sheet before.
			cut := stickerimg.SplitExact(img, a.Sheets[i].Columns, a.Sheets[i].Rows)
			cells = append(cells, cut[:len(a.Sheets[i].Frames)]...)
			continue
		}
		cells = append(cells, stickerimg.SplitGrid(img, a.Sheets[i].Columns, a.Sheets[i].Rows)...)
	}
	finish := art.finish()
	opts := stickerimg.AnimOptions{
		StickerSize: art.StickerSize, Border: art.Border, Margin: art.Margin, Threshold: 8, Finish: &finish,
		Columns: r.c.cfg.Columns, MaxSheet: r.c.cfg.MaxSheet, Normalize: a.normalize(),
		Register: a.register(), SheetsContinue: len(a.Sheets) > 1,
		Grow: a.kind() == manifest.KindMove && a.Loop == nil,
	}
	opts.Resolution = r.c.cfg.StickerPx
	if a.Loop != nil {
		opts.Loop = [2]int{a.Loop.From - 1, a.Loop.To - 1}
	}
	for _, s := range a.Sheets {
		opts.SheetSizes = append(opts.SheetSizes, len(s.Frames))
	}

	for _, f := range a.RestFrames {
		opts.RestFrames = append(opts.RestFrames, f-1)
	}
	if len(a.RestFrames) > 0 && a.restFromSticker() {
		if data, err := os.ReadFile(r.rawPath(a.Sticker)); err == nil {
			if opts.Rest, err = stickerimg.Decode(data); err != nil {
				return fmt.Errorf("%s raw: %w", a.Sticker, err)
			}
		} else {
			r.say("  (no raw for %s; rest frames keep the generated art)", a.Sticker)
		}
	}
	sheet, err := stickerimg.Animation(cells, opts)
	if err != nil {
		return fmt.Errorf("%s: %w", a.key(), err)
	}
	if err := r.writeAnimation(a, sheet, stickerPath, hold, sheetPath, jsonPath); err != nil {
		return err
	}
	if r.c.cfg.Scaffold {
		return r.check(a, sheet)
	}
	scales := make([]string, len(sheet.Scales))
	for i, s := range sheet.Scales {
		scales[i] = fmt.Sprintf("%.2f", s)
	}
	for _, n := range sheet.Notes {
		r.say("  %s: %s", a.key(), n)
	}
	r.say("✓ %s: %d frames of %dx%d in a %dx%d sheet (frame scales %s)", a.key(), sheet.Count, sheet.Frame.X, sheet.Frame.Y, sheet.Image.Bounds().Dx(), sheet.Image.Bounds().Dy(), strings.Join(scales, " "))
	return nil
}

// writeAnimation writes an assembled sheet, its sidecar (the frames'
// rest box against the sticker's) and its onion skin.
func (r *renderer) writeAnimation(a animSpec, sheet *stickerimg.AnimSheet, stickerPath string, hold []float64, sheetPath, jsonPath string) error {
	stickerData, err := os.ReadFile(stickerPath)
	if err != nil {
		return err
	}
	sticker, err := stickerimg.Decode(stickerData)
	if err != nil {
		return err
	}
	out := manifest.StickerAnimation{ID: a.ID, Sticker: a.Sticker, Description: a.storyDescription(), Sheet: "anims/" + a.key() + ".webp", Columns: sheet.Columns, Count: sheet.Count, Hold: hold}
	if a.kind() == manifest.KindMove {
		out.Kind = manifest.KindMove
		if a.Loop != nil {
			out.Loop = &manifest.FrameRange{From: a.Loop.From - 1, To: a.Loop.To - 1}
			out.Facing, out.Stride, out.Hops, out.Flies, out.On = a.Facing, a.Stride, a.Hops, a.Flies, a.On
		}
	}
	if a.kind() == manifest.KindAction {
		out.Perched, out.Place = a.Perched, a.Place
	}
	if a.Pause != nil {
		out.Pause = &manifest.AnimationPause{Frame: a.Pause.Frame - 1, Shows: strings.TrimSpace(a.Pause.Shows)}
	}
	out.Frame.Width, out.Frame.Height = sheet.Frame.X, sheet.Frame.Y
	out.Rest = unit(sheet.Rest, sheet.Frame)
	out.StickerBox = unit(stickerimg.Bounds(sticker, 0), sticker.Bounds().Size())
	if out.Particles, err = sidecarParticles(a.Particles, sticker); err != nil {
		return fmt.Errorf("%s: %w", a.key(), err)
	}

	png, err := stickerimg.Encode(sheet.Image)
	if err != nil {
		return err
	}
	if err := os.WriteFile(sheetPath, png, 0o644); err != nil {
		return err
	}
	data, _ := json.MarshalIndent(out, "", "  ")
	if err := os.WriteFile(jsonPath, append(data, '\n'), 0o644); err != nil {
		return err
	}
	if onion, err := stickerimg.Encode(onionSkin(sheet)); err == nil {
		os.WriteFile(r.out(a.key()+".onion.png"), onion, 0o644)
	}
	return nil
}

// scaffoldAssembly changes whenever the assembly of scaffolded sheets
// changes: they are re-assembled from the kept sheets, free.
const scaffoldAssembly = "3"

// restCell is the sticker's raw art exactly where its image has it (its
// size class's fill, centred, no border): every scaffold cell, and the rest
// frames of a scaffolded animation.
func (r *renderer) restCell(stickerID string) (*image.RGBA, error) {
	art := r.c.art
	data, err := os.ReadFile(r.rawPath(stickerID))
	if err != nil {
		return nil, fmt.Errorf("%s: the scaffold needs stickerart's raw art: %w", stickerID, err)
	}
	src, err := stickerimg.Decode(data)
	if err != nil {
		return nil, err
	}
	return stickerimg.PlaceArt(src, stickerimg.StickerOptions{Size: art.StickerSize, Border: art.Border, Margin: art.Margin, Fill: art.fill(stickerID), Threshold: 8})
}

// roomy is the rest cell for a scaffold with room: the sticker at its size
// in the middle of a cell room times its box (shrunk back to the box's
// pixels: the generator's cells stay the sticker's size).
func roomy(rest *image.RGBA, room float64) *image.RGBA {
	if room <= 1 {
		return rest
	}
	n := rest.Bounds().Dx()
	return stickerimg.Resize(pad(rest, int(math.Round(float64(n)*room))), n, n)
}

// pad centres img in a transparent size×size square.
func pad(img *image.RGBA, size int) *image.RGBA {
	out := image.NewRGBA(image.Rect(0, 0, size, size))
	b := img.Bounds()
	off := image.Pt((size-b.Dx())/2, (size-b.Dy())/2)
	draw.Draw(out, b.Sub(b.Min).Add(off), img, b.Min, draw.Over)
	return out
}

// scaffold is the image a sheet is drawn over: every cell the sticker at
// its size and place — the first one, after the first sheet, the pose the
// previous sheet ended on — sent at 2048 px (it conveys sizes and places,
// the sticker's detail is in it too).
func (r *renderer) scaffold(rest, startPose *image.RGBA, sh sheetSpec) ([]byte, error) {
	var w, h int
	if _, err := fmt.Sscanf(sh.Size, "%dx%d", &w, &h); err != nil {
		return nil, fmt.Errorf("sheet size %q: %w", sh.Size, err)
	}
	cell := w / sh.Columns
	if h/sh.Rows != cell {
		return nil, fmt.Errorf("sheet size %s does not give square cells for %dx%d", sh.Size, sh.Columns, sh.Rows)
	}
	cells := make([]*image.RGBA, len(sh.Frames))
	for i := range cells {
		cells[i] = rest
	}
	if startPose != nil {
		cells[0] = startPose
	}
	data, err := stickerimg.Encode(stickerimg.Scaffold(cells, sh.Columns, sh.Rows, cell))
	if err != nil {
		return nil, err
	}
	if small, err := downscale(data, 2048); err == nil {
		data = small
	}
	return data, nil
}

// check measures every frame of an assembled animation against its rest
// pose (stickerimg.MeasureFrames), writes the result next to the sheet
// (<key>.qa.json, which the review page shows) and sums it up in the log.
func (r *renderer) check(a animSpec, sheet *stickerimg.AnimSheet) error {
	grow := a.kind() == manifest.KindMove && a.Loop == nil
	// Nothing in the sky or adrift has a ground to keep its bottom on.
	qa := stickerimg.MeasureFrames(sheet, 8, grow, a.Flies || a.Hops || a.register() == stickerimg.RegisterBody)
	data, _ := json.MarshalIndent(qa, "", "  ")
	if err := os.WriteFile(r.out(a.key()+".qa.json"), append(data, '\n'), 0o644); err != nil {
		return err
	}
	bad := 0
	for _, q := range qa {
		if len(q.Problems) > 0 {
			bad++
			r.say("  ⚠ %s frame %d: %s", a.key(), q.Frame, strings.Join(q.Problems, "; "))
		}
	}
	r.say("✓ %s: %d frames of %dx%d, %d flagged (stickeranim review shows them)", a.key(), sheet.Count, sheet.Frame.X, sheet.Frame.Y, bad)
	return nil
}

// scaffoldPrompt asks for one sheet drawn over a scaffold: the cells
// already hold the sticker at its size and place; the model re-poses each.
func scaffoldPrompt(style, sticker string, a animSpec, sh sheetSpec, first, total int, continued bool) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n\n", style)
	who := strings.TrimSuffix(strings.TrimSpace(sticker), ".")
	if who != "" {
		who = strings.ToLower(who[:1]) + who[1:]
	}
	fmt.Fprintf(&b, "The first attached image is a sheet of %d cells in a grid of %d columns by %d rows. Every cell shows the same sticker character (%s) at exactly the size and in exactly the place it must keep in that cell", len(sh.Frames), sh.Columns, sh.Rows, who)
	if continued {
		b.WriteString(" — except the first cell, which shows the pose the animation has reached")
	}
	fmt.Fprintf(&b, ". Redraw the sheet so that each cell shows the pose listed for it, making consecutive moments of one animation: %s", strings.TrimSpace(a.Description))
	if continued {
		b.WriteString(" The second attached image is the previous sheet of this same animation; these frames carry straight on from its last frame.")
	}
	fmt.Fprintf(&b, "\n\nCells %d–%d of %d (left to right, then top to bottom):\n", first, first+len(sh.Frames)-1, total)
	for i, f := range sh.Frames {
		fmt.Fprintf(&b, "%d. %s\n", first+i, strings.TrimSpace(f))
	}
	if a.kind() == manifest.KindMove && a.Loop != nil {
		fmt.Fprintf(&b, "\nCells %d–%d are one seamless cycle: cell %d follows on from cell %d exactly, so they can repeat for ever. The character moves in place, as if on a treadmill: it does not travel across its cell.", a.Loop.From, a.Loop.To, a.Loop.From, a.Loop.To)
	}
	fmt.Fprintf(&b, "\nRules: in every cell the character keeps exactly the size, proportions and design it has in the scaffold — the same height, the same head, the same width of body — and %s stays exactly where it is in the cell; change only what the pose moves. Motions are small and gentle: arms, legs, doors and parts move close to the body, nothing reaches far out to the sides, nothing is thrown far. Never draw particles of any kind — no dust, sand, soil or pebbles kicked up, no water drops or splashes, no sparks, smoke, steam or debris: the app adds those itself. Anything else the pose needs (a tool, a flame from an engine) stays small and close, inside the empty space of the cell around the character. Keep every cell exactly where it is in the grid, each drawing well inside its own cell: nothing touches or crosses into another cell. Consecutive cells are close together — each one a small step on from the one before — so the animation plays smoothly. No grid lines, no cell borders, no numbers, no labels, no text, no ground, no shadow, no background — fully transparent everywhere except the drawings.", a.Base)
	if h := strings.TrimSpace(sh.Hint); h != "" {
		fmt.Fprintf(&b, " %s", h)
	}
	return b.String()
}

// onionSkin overlays every frame at equal opacity on a white ground.
func onionSkin(s *stickerimg.AnimSheet) *image.RGBA {
	out := image.NewRGBA(image.Rect(0, 0, s.Frame.X, s.Frame.Y))
	draw.Draw(out, out.Bounds(), image.White, image.Point{}, draw.Src)
	alpha := uint8(255 / s.Count)
	if alpha < 40 {
		alpha = 40
	}
	mask := image.NewUniform(color.Alpha{A: alpha})
	for i := 0; i < s.Count; i++ {
		col, row := i%s.Columns, i/s.Columns
		src := image.Pt(col*s.Frame.X, row*s.Frame.Y)
		draw.DrawMask(out, out.Bounds(), s.Image, src, mask, image.Point{}, draw.Over)
	}
	return out
}

// downscale returns the image (PNG or WebP) as a PNG resized so its
// longer edge is at most maxEdge px — what the API is sent as a reference.
func downscale(data []byte, maxEdge int) ([]byte, error) {
	img, err := stickerimg.Decode(data)
	if err != nil {
		return nil, err
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w <= maxEdge && h <= maxEdge {
		return stickerimg.Encode(img)
	}
	if w >= h {
		h = h * maxEdge / w
		w = maxEdge
	} else {
		w = w * maxEdge / h
		h = maxEdge
	}
	return stickerimg.Encode(stickerimg.Resize(img, w, h))
}

// ---------- install ----------

// runInstall encodes each assembled sheet into the pack as WebP, copies
// its sidecar next to it and declares it in the sticker's manifest entry
// (docs/pack-format.md, "Live animations"), validating before writing.
func runInstall(args []string) error {
	fs := flag.NewFlagSet("install", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	artDir := fs.String("art", "", "art directory (default author/art/<packID>)")
	bump := fs.Bool("bump", false, "increment the pack's content version")
	only := fs.String("only", "", "comma-separated animation ids, sticker ids or sticker.animation keys to copy in (the rest keep what the pack has)")
	fs.Parse(args)
	wanted := map[string]bool{}
	for _, id := range strings.Split(*only, ",") {
		if id = strings.TrimSpace(id); id != "" {
			wanted[id] = true
		}
	}
	c, err := load(*packDir, *artDir)
	if err != nil {
		return err
	}
	byID := map[string]int{}
	for i, s := range c.pack.Stickers {
		byID[s.ID] = i
	}
	outDir := filepath.Join(c.artDir, "out", "anims")
	cache := map[string]string{}
	if data, err := os.ReadFile(filepath.Join(outDir, "render.json")); err == nil {
		json.Unmarshal(data, &cache)
	}
	// The manifest declares exactly what anim.json lists, in its order: an
	// animation taken out of anim.json leaves the pack (sheet and sidecar)
	// — stories that still cue it fail validation until they are updated.
	listed := map[string]bool{}
	for _, a := range c.cfg.Animations {
		listed["anims/"+a.key()+".json"] = true
	}
	for i := range c.pack.Stickers {
		st := &c.pack.Stickers[i]
		kept := st.Animations[:0]
		for _, rel := range st.Animations {
			if listed[rel] {
				kept = append(kept, rel)
				continue
			}
			fmt.Printf("remove %s (no longer in anim.json)\n", rel)
			base := strings.TrimSuffix(filepath.Join(c.packDir, filepath.FromSlash(rel)), ".json")
			os.Remove(base + ".json")
			os.Remove(base + ".webp")
			os.Remove(base + ".png")
		}
		st.Animations = kept
	}
	installed := 0
	for _, a := range c.cfg.Animations {
		if len(wanted) > 0 && !wanted[a.ID] && !wanted[a.Sticker] && !wanted[a.key()] {
			continue
		}
		src := filepath.Join(outDir, a.key())
		if !exists(src+".png") || !exists(src+".json") {
			fmt.Printf("skip %s: not rendered\n", a.key())
			continue
		}
		dst := filepath.Join(c.packDir, "anims", a.key())
		// The sheet ships as WebP (docs/pack-format.md); a PNG sheet from
		// before is dropped.
		if _, err := stickerimg.InstallWebP(src+".png", dst+".webp", cache); err != nil {
			return err
		}
		os.Remove(dst + ".png")
		// The sidecar as assembled, with what anim.json says now about the
		// parts that do not change the frames.
		side, err := manifest.LoadStickerAnimation(src + ".json")
		if err != nil {
			return fmt.Errorf("%s: %w", a.key(), err)
		}
		if a.kind() == manifest.KindMove && a.Loop != nil {
			side.Flies, side.On = a.Flies, a.On
		}
		if a.kind() == manifest.KindAction {
			side.Perched, side.Place = a.Perched, a.Place
		}
		data, _ := json.MarshalIndent(side, "", "  ")
		if err := os.WriteFile(dst+".json", append(data, '\n'), 0o644); err != nil {
			return err
		}
		rel := "anims/" + a.key() + ".json"
		st := &c.pack.Stickers[byID[a.Sticker]]
		if !slices.Contains(st.Animations, rel) {
			st.Animations = append(st.Animations, rel)
		}
		installed++
	}
	// In anim.json's order: a sticker's first move is its usual way.
	order := map[string]int{}
	for i, a := range c.cfg.Animations {
		order["anims/"+a.key()+".json"] = i
	}
	for i := range c.pack.Stickers {
		slices.SortStableFunc(c.pack.Stickers[i].Animations, func(a, b string) int { return order[a] - order[b] })
	}
	if data, err := json.MarshalIndent(cache, "", "  "); err == nil {
		os.WriteFile(filepath.Join(outDir, "render.json"), append(data, '\n'), 0o644)
	}
	if *bump {
		c.pack.Version++
	}
	if errs := c.pack.Validate(c.packDir); len(errs) > 0 {
		for _, e := range errs {
			fmt.Printf("  ✗ %v\n", e)
		}
		return errors.New("manifest would not validate; manifest.json left unchanged (files were copied)")
	}
	data, err := json.MarshalIndent(c.pack, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(c.packDir, "manifest.json"), append(data, '\n'), 0o644); err != nil {
		return err
	}
	fmt.Printf("✓ installed %d animation(s) into %s/anims and declared them in the manifest (version %d); manifest validates\n", installed, c.packDir, c.pack.Version)
	return nil
}
