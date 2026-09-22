// Command stickeranim produces frame animations ("live" stickers) for a
// pack's stickers with the OpenAI Images API and installs them into the
// pack (docs/pack-format.md, "Live animations"). The app's developer
// gallery plays them; stories do not trigger them yet.
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
	assembleVersion = "9"
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
	Stickers    []struct {
		ID     string `json:"id"`
		Prompt string `json:"prompt"`
	} `json:"stickers"`
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
	Columns    int        `json:"columns"`
	MaxSheet   int        `json:"maxSheet"`
	Animations []animSpec `json:"animations"`
	Notes      any        `json:"notes,omitempty"`
}

type animSpec struct {
	ID      string `json:"id"`
	Sticker string `json:"sticker"`
	// Description is the one-line summary of the whole animation; Base is
	// what stays still while the character moves ("the lily pad").
	Description string      `json:"description"`
	Base        string      `json:"base"`
	Sheets      []sheetSpec `json:"sheets"`
	// Hold is how long each frame shows, in seconds, one entry per frame
	// across all sheets; absent means 1/12 s each.
	Hold []float64 `json:"hold,omitempty"`
	// RestFrames are the 1-based frames that show the sticker's own pose;
	// they take the sticker's real art, so the animation starts and ends
	// on exactly the sticker (needs the raw from stickerart).
	RestFrames []int `json:"restFrames,omitempty"`
	// Normalize (default false) rescales frames so the base keeps its
	// width: only for a base object that is the widest thing at the
	// bottom in every pose (a lily pad, a perch); feet, a curling body or
	// spread wings make the measure jump and the frame pop in size.
	Normalize bool `json:"normalize,omitempty"`
}

func (a animSpec) normalize() bool { return a.Normalize }

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

func (a animSpec) frameCount() int {
	n := 0
	for _, s := range a.Sheets {
		n += len(s.Frames)
	}
	return n
}

func (a animSpec) key() string { return a.Sticker + "." + a.ID }

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
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "✗ %v\n", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: stickeranim render|install -pack <pack-dir> [flags]  (see -h on each)")
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
	only := fs.String("only", "", "comma-separated animation ids or sticker ids")
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
		if o.only != nil && !o.only[a.ID] && !o.only[a.Sticker] {
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

// rawPath is where stickerart keeps the sticker's raw art (no border).
func (r *renderer) rawPath(stickerID string) string {
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
		raws    []string
		genFPs  []string
		prev    []byte
		first   = 1
		total   = a.frameCount()
		changed = false
	)
	for i, sh := range a.Sheets {
		// Every sheet after the first carries on from the previous one, so
		// the prompt (and the fingerprint) is the same with or without the
		// reference loaded (dry runs load none).
		prompt := sheetPrompt(art.Style, r.c.stickerPrompt(a.Sticker), a, sh, first, total, i > 0)
		// The previous sheet is a reference for this one, but it is not in
		// the fingerprint: redoing sheet 1 must not throw away a good sheet 2
		// (-force redoes everything).
		genFP := hashOf(toolVersion, "sheet", refFP, prompt, sh.Size, r.o.quality, r.o.fidelity, editModel)
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
	asmFP := hashOf(append([]string{assembleVersion, hashFile(stickerPath), hashFile(r.rawPath(a.Sticker)), fmt.Sprint(r.c.cfg.Columns, r.c.cfg.MaxSheet, art.StickerSize, art.Border, art.Margin, art.finish(), hold, a.RestFrames, a.normalize())}, genFPs...)...)
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
	fmt.Fprintf(&b, "\nRules: draw every frame at exactly the same scale, with %s the same size and in the same place in every cell — centred horizontally and resting on the bottom part of the cell — so that only the character moves relative to it. Keep each frame well inside its own cell with clear empty space around it: nothing touches or crosses a cell boundary, and the frames are spaced evenly. No grid lines, no cell borders, no boxes, no numbers, no labels, no text, no ground shadow, no background — a fully transparent background everywhere except the drawing itself.", a.Base)
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
		cells = append(cells, stickerimg.SplitGrid(img, a.Sheets[i].Columns, a.Sheets[i].Rows)...)
	}
	finish := art.finish()
	opts := stickerimg.AnimOptions{
		StickerSize: art.StickerSize, Border: art.Border, Margin: art.Margin, Threshold: 8, Finish: &finish,
		Columns: r.c.cfg.Columns, MaxSheet: r.c.cfg.MaxSheet, Normalize: a.normalize(),
	}

	if len(a.RestFrames) > 0 {
		if data, err := os.ReadFile(r.rawPath(a.Sticker)); err == nil {
			if opts.Rest, err = stickerimg.Decode(data); err != nil {
				return fmt.Errorf("%s raw: %w", a.Sticker, err)
			}
			for _, f := range a.RestFrames {
				opts.RestFrames = append(opts.RestFrames, f-1)
			}
		} else {
			r.say("  (no raw for %s; rest frames keep the generated art)", a.Sticker)
		}
	}
	sheet, err := stickerimg.Animation(cells, opts)
	if err != nil {
		return fmt.Errorf("%s: %w", a.key(), err)
	}
	stickerData, err := os.ReadFile(stickerPath)
	if err != nil {
		return err
	}
	sticker, err := stickerimg.Decode(stickerData)
	if err != nil {
		return err
	}
	out := manifest.StickerAnimation{ID: a.ID, Sticker: a.Sticker, Sheet: "anims/" + a.key() + ".webp", Columns: sheet.Columns, Count: sheet.Count, Hold: hold}
	out.Frame.Width, out.Frame.Height = sheet.Frame.X, sheet.Frame.Y
	out.Rest = unit(sheet.Rest, sheet.Frame)
	out.StickerBox = unit(stickerimg.Bounds(sticker, 0), sticker.Bounds().Size())

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
	scales := make([]string, len(sheet.Scales))
	for i, s := range sheet.Scales {
		scales[i] = fmt.Sprintf("%.2f", s)
	}
	r.say("✓ %s: %d frames of %dx%d in a %dx%d sheet (frame scales %s)", a.key(), sheet.Count, sheet.Frame.X, sheet.Frame.Y, sheet.Image.Bounds().Dx(), sheet.Image.Bounds().Dy(), strings.Join(scales, " "))
	return nil
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
	fs.Parse(args)
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
	installed := 0
	for _, a := range c.cfg.Animations {
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
		if err := copyFile(src+".json", dst+".json"); err != nil {
			return err
		}
		rel := "anims/" + a.key() + ".json"
		st := &c.pack.Stickers[byID[a.Sticker]]
		if !slices.Contains(st.Animations, rel) {
			st.Animations = append(st.Animations, rel)
		}
		installed++
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

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o644)
}
