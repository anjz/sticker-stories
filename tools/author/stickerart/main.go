// Command stickerart produces a pack's sticker and scene art with the OpenAI
// Images API and installs it into the pack.
//
// Usage:
//
//	stickerart init    -pack ../packs/forest              # seed art.json from the manifest
//	stickerart render  -pack ../packs/forest [-only fox,tree|stylesheet|scene] [-quality high]
//	                   [-dry-run] [-force] [-parallel 4]
//	stickerart install -pack ../packs/forest [-bump]
//
// art.json (tools/author/art/<packID>/art.json) holds the pack's style, one
// prompt per sticker and prompts for the scene planes. Rendering makes one
// style sheet first, then every sticker as an edit that uses the style
// sheet as reference with a transparent background, then the background,
// its 2:1 wide extension (outpainted around the untouched centre), and the
// foreground plane. Outputs land in <art>/out/ as lossless PNG and are
// cached by fingerprint; install encodes them into the pack's WebP
// (docs/pack-format.md, "Image formats").
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
	"image/color"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"stickerstories/tools/internal/dotenv"
	"stickerstories/tools/internal/manifest"
	"stickerstories/tools/internal/openai"
	"stickerstories/tools/internal/stickerimg"
)

const (
	toolVersion  = "1"
	genModel     = "gpt-image-2.5-flare"
	editModel    = "gpt-image-2.5-sunburst"
	baseW, baseH = 2048, 1536
	wideW        = 3072
	sheetSize    = "1536x1024"
	stickerGenPx = 1024
	// The finished sticker's size: a sticker is drawn at 16 % of the world
	// height and pinches to 2×, so even a 13" iPad shows at most ~660 px.
	defaultStickerPx = 768
	defaultQual      = "high"
	// Both scene planes get this (docs/pack-format.md, "Art safe area"): the
	// app crops the top and bottom on wide screens and lays the sticker tray
	// and the play controls over those bands.
	sceneSafeArea = "Composition: the screen crops the top and bottom of this picture and covers them with controls, so keep the horizon, the ground line and everything that matters — focal points, main features, anything a child would point at — inside the central 70% of the height. Still fill the top and bottom bands naturally (sky, canopy, leaves, grass); just keep them quiet and secondary, with nothing the picture needs there. Balance, not emptiness."
	// Outdoors packs get this too (docs/pack-format.md, "Art safe area"):
	// the app draws the weather and the light as canvas effects over the
	// scene — sunshine, rain, fog, a rainbow, night with a moon and stars —
	// so the art itself must stay neutral or the moon would show twice.
	sceneNeutralSky = "Weather and light: plain daytime with soft, even light and a clear or lightly clouded sky. Do NOT paint a sun, a moon, stars, sun rays, a rainbow, rain, mist or fog anywhere in the picture — the app adds those over the scene as effects."
	// Space and underwater packs get their own version: the art keeps the
	// sky or the water calm and the canvas effects add everything that moves
	// or glows in it.
	sceneNeutralSpace = "Sky: a calm, dark starry sky with small, distant, unlit stars. Do NOT paint shooting stars, comets, a glowing nebula, a bright glowing planet rim along the horizon, a sun flare or speed streaks anywhere in the picture — the app adds those over the scene as effects."
	sceneNeutralWater = "Water and light: clear water with soft, even light. Do NOT paint sun rays from the surface, rippling light patterns, bubbles, glowing specks, drifting particles or clouds of sand anywhere in the picture — the app adds those over the scene as effects."
)

// sceneNeutral is the directive that keeps a pack's scene art free of what
// its setting's canvas effects draw ("" for settings without any).
func sceneNeutral(setting string) string {
	switch setting {
	case "outdoors":
		return sceneNeutralSky
	case "space":
		return sceneNeutralSpace
	case "underwater":
		return sceneNeutralWater
	}
	return ""
}

// artConfig is art.json.
type artConfig struct {
	Style       string  `json:"style"`
	StyleSheet  string  `json:"styleSheet"`
	StickerSize int     `json:"stickerSize"`
	Border      float64 `json:"border"`
	Margin      float64 `json:"margin"`
	// Finish is the printed-sticker material (stickerimg.Finish); absent
	// means stickerimg.DefaultFinish, a glossy die-cut vinyl sticker.
	Finish   *stickerimg.Finish `json:"finish,omitempty"`
	Stickers []stickerSpec      `json:"stickers"`
	// Expressions are the face variants every sticker with a face gets
	// (the sticker itself is the "normal" one).
	Expressions []expressionSpec  `json:"expressions,omitempty"`
	Scene       sceneSpec         `json:"scene"`
	Notes       map[string]string `json:"notes,omitempty"`
}

func (c artConfig) finish() stickerimg.Finish {
	if c.Finish != nil {
		return *c.Finish
	}
	return stickerimg.DefaultFinish
}

type stickerSpec struct {
	ID     string            `json:"id"`
	Name   map[string]string `json:"name"`
	Prompt string            `json:"prompt"`
	// Face is where the face is on the raw art; a sticker without one has
	// no expression variants.
	Face *stickerimg.FaceBox `json:"face,omitempty"`
	// FaceNote says what the face is drawn on when that is not obvious
	// ("the round brown speckled seed centre"), so an expression keeps it.
	FaceNote string `json:"faceNote,omitempty"`
}

// expressionSpec is one face variant: an id stories cue ({bear:face happy})
// and how the face should look.
type expressionSpec struct {
	ID     string `json:"id"`
	Prompt string `json:"prompt"`
}

type sceneSpec struct {
	Background string `json:"background"`
	Foreground string `json:"foreground"`
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	dotenv.LoadFirst(".env", filepath.Join("..", ".env"))
	var err error
	switch os.Args[1] {
	case "init":
		err = runInit(os.Args[2:])
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
	fmt.Fprintln(os.Stderr, "usage: stickerart init|render|install -pack <pack-dir> [flags]  (see -h on each)")
	os.Exit(2)
}

type ctxt struct {
	pack    *manifest.Manifest
	packDir string
	artDir  string
	cfg     *artConfig
}

func load(packDir, artDir string, needConfig bool) (*ctxt, error) {
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
	c := &ctxt{pack: m, packDir: packDir, artDir: artDir}
	if needConfig {
		data, err := os.ReadFile(filepath.Join(artDir, "art.json"))
		if err != nil {
			return nil, fmt.Errorf("reading art.json (run `stickerart init` first): %w", err)
		}
		c.cfg = &artConfig{}
		if err := json.Unmarshal(data, c.cfg); err != nil {
			return nil, fmt.Errorf("art.json: %w", err)
		}
		if c.cfg.StickerSize == 0 {
			c.cfg.StickerSize = defaultStickerPx
		}
		if c.cfg.Border == 0 {
			c.cfg.Border = 0.025
		}
		if c.cfg.Margin == 0 {
			c.cfg.Margin = 0.03
		}
	}
	return c, nil
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

// ---------- init ----------

func runInit(args []string) error {
	fs := flag.NewFlagSet("init", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	artDir := fs.String("art", "", "art directory (default author/art/<packID>)")
	fs.Parse(args)
	c, err := load(*packDir, *artDir, false)
	if err != nil {
		return err
	}
	path := filepath.Join(c.artDir, "art.json")
	if _, err := os.Stat(path); err == nil {
		return fmt.Errorf("%s already exists", path)
	}
	cfg := artConfig{
		Style:       "Describe the pack's look here: medium, line, palette, level of detail, how faces look. Every prompt inherits it.",
		StyleSheet:  "Describe a style sheet image: three or four of the characters side by side plus a small scenery swatch, on a plain white background.",
		StickerSize: defaultStickerPx, Border: 0.025, Margin: 0.03,
		Scene: sceneSpec{Background: "The scene behind the stickers, no characters. Outdoors: plain daylight, no sun or moon — the app's canvas effects draw the weather and the night.", Foreground: "Only the elements that sit in front of the stickers (e.g. the nearest trees and grass), everything else transparent."},
		Notes: map[string]string{"stickers": "One prompt per sticker: what it is, pose, expression, facing direction. Keep every character facing the same way."},
	}
	for _, s := range c.pack.Stickers {
		cfg.Stickers = append(cfg.Stickers, stickerSpec{ID: s.ID, Name: s.Name, Prompt: "A " + strings.ToLower(s.Name[c.pack.Languages[0]]) + ", full body, facing slightly left, friendly expression."})
	}
	if err := os.MkdirAll(c.artDir, 0o755); err != nil {
		return err
	}
	data, _ := json.MarshalIndent(cfg, "", "  ")
	if err := os.WriteFile(path, append(data, '\n'), 0o644); err != nil {
		return err
	}
	fmt.Printf("wrote %s with %d stickers from the manifest; fill in the prompts\n", path, len(cfg.Stickers))
	return nil
}

// ---------- render ----------

type renderOpts struct {
	quality  string
	only     map[string]bool
	force    bool
	dry      bool
	parallel int
}

type renderer struct {
	c     *ctxt
	oa    *openai.Client
	o     renderOpts
	ctx   context.Context
	mu    sync.Mutex
	fps   map[string]string // output path → fingerprint (out/render.json)
	spent openai.Usage      // this run's tokens
	calls int
	// dry-run tally
	planned []string
	tokens  int
}

func (r *renderer) out(parts ...string) string {
	p := filepath.Join(append([]string{r.c.artDir, "out"}, parts...)...)
	os.MkdirAll(filepath.Dir(p), 0o755)
	return p
}

func hashOf(parts ...string) string {
	h := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return hex.EncodeToString(h[:])[:16]
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

func runRender(args []string) error {
	fs := flag.NewFlagSet("render", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	artDir := fs.String("art", "", "art directory (default author/art/<packID>)")
	only := fs.String("only", "", "comma-separated sticker ids, and/or the words stylesheet, scene")
	quality := fs.String("quality", defaultQual, "low | medium | high | xhigh | max")
	parallel := fs.Int("parallel", 4, "stickers rendered concurrently")
	force := fs.Bool("force", false, "re-render even if nothing changed")
	dry := fs.Bool("dry-run", false, "list what would be generated; no API calls")
	fs.Parse(args)
	c, err := load(*packDir, *artDir, true)
	if err != nil {
		return err
	}
	o := renderOpts{quality: *quality, force: *force, dry: *dry, parallel: *parallel}
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
	return r.run()
}

func (r *renderer) want(key string) bool { return r.o.only == nil || r.o.only[key] }

func (r *renderer) upToDate(path, fp string) bool {
	return !r.o.force && exists(path) && r.fps[path] == fp
}

func (r *renderer) done(path, fp string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.fps[path] = fp
	data, _ := json.MarshalIndent(r.fps, "", "  ")
	os.WriteFile(r.out("render.json"), append(data, '\n'), 0o644)
}

// charge records a call's usage and returns a short cost label.
func (r *renderer) charge(u openai.Usage) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.spent.Add(u)
	r.calls++
	return fmt.Sprintf("$%.3f", u.Cost(openai.DefaultPrices))
}

func (r *renderer) say(format string, args ...any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	fmt.Printf(format+"\n", args...)
}

func (r *renderer) run() error {
	cfg := r.c.cfg
	// 1. Style sheet — everything else references it.
	sheetFP := hashOf(toolVersion, "sheet", cfg.Style, cfg.StyleSheet, r.o.quality, genModel)
	sheetPath := r.out("stylesheet.png")
	if r.want("stylesheet") || r.o.only == nil {
		if r.upToDate(sheetPath, sheetFP) {
			r.say("· stylesheet up to date")
		} else if r.o.dry {
			r.planned = append(r.planned, "stylesheet ("+sheetSize+")")
		} else {
			r.say("▶ stylesheet")
			img, err := r.oa.Generate(r.ctx, openai.ImageRequest{Model: genModel, Prompt: cfg.Style + "\n\n" + cfg.StyleSheet, Size: sheetSize, Quality: r.o.quality, Background: "opaque"})
			if err != nil {
				return fmt.Errorf("stylesheet: %w", err)
			}
			if err := os.WriteFile(sheetPath, img.PNG, 0o644); err != nil {
				return err
			}
			r.done(sheetPath, sheetFP)
			r.say("✓ stylesheet (%s) — open %s and check the look before rendering the cast", r.charge(img.Usage), sheetPath)
		}
	}
	sheet, _ := os.ReadFile(sheetPath)
	if sheet == nil && !r.o.dry {
		return errors.New("no style sheet yet; render it first (it is the reference for everything else)")
	}
	if sheet != nil {
		// A reference only has to convey style; sending it at half size
		// halves its input tokens on every call that uses it.
		if small, err := downscale(sheet, 768); err == nil {
			sheet = small
		}
	}

	// 2. Stickers, in parallel.
	var (
		wg       sync.WaitGroup
		queue    = make(chan stickerSpec)
		failures []string
	)
	workers := r.o.parallel
	if workers < 1 || r.o.dry {
		workers = 1
	}
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for s := range queue {
				if err := r.sticker(s, sheet, sheetFP); err != nil {
					r.mu.Lock()
					failures = append(failures, s.ID+": "+err.Error())
					r.mu.Unlock()
					r.say("✗ %s: %v", s.ID, err)
				}
			}
		}()
	}
	for _, s := range cfg.Stickers {
		if r.want(s.ID) {
			queue <- s
		}
	}
	close(queue)
	wg.Wait()

	// 2b. Expression variants: the face repainted, everything else the
	// sticker's own pixels (after the stickers, whose raws they edit).
	type faceJob struct {
		s stickerSpec
		e expressionSpec
	}
	faces := make(chan faceJob)
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range faces {
				if err := r.face(j.s, j.e); err != nil {
					r.mu.Lock()
					failures = append(failures, j.s.ID+"."+j.e.ID+": "+err.Error())
					r.mu.Unlock()
					r.say("✗ %s.%s: %v", j.s.ID, j.e.ID, err)
				}
			}
		}()
	}
	for _, s := range cfg.Stickers {
		if s.Face == nil || !(r.want(s.ID) || r.want("faces")) {
			continue
		}
		for _, e := range cfg.Expressions {
			if r.o.only == nil || r.want(s.ID) || r.want("faces") || r.want(s.ID+"."+e.ID) {
				faces <- faceJob{s, e}
			}
		}
	}
	close(faces)
	wg.Wait()

	// 3. Scene planes.
	if r.want("scene") || r.o.only == nil {
		if err := r.scene(sheet, sheetFP); err != nil {
			failures = append(failures, "scene: "+err.Error())
		}
	}
	if r.o.dry {
		fmt.Printf("\nDry run: %d images to generate at quality %s:\n  %s\n", len(r.planned), r.o.quality, strings.Join(r.planned, "\n  "))
		return nil
	}
	if len(failures) > 0 {
		r.summary()
		return fmt.Errorf("%d failure(s) (rerun to retry just those):\n  %s", len(failures), strings.Join(failures, "\n  "))
	}
	r.summary()
	fmt.Printf("Review %s, then: stickerart install -pack %s\n", filepath.Join(r.c.artDir, "out"), r.c.packDir)
	return nil
}

// finishVersion changes whenever stickerimg's finishing (border, finish,
// clean-up) changes, so kept raws are re-finished without a new generation.
const finishVersion = "2"

// sticker generates a sticker's art (the costly call, kept as <id>.raw.png)
// and finishes it into the pack's sticker (<id>.png). The two have their
// own fingerprints: a prompt change regenerates, a border or finish change
// only re-finishes the kept raw.
func (r *renderer) sticker(s stickerSpec, sheet []byte, sheetFP string) error {
	cfg := r.c.cfg
	genFP := hashOf(toolVersion, "sticker", sheetFP, cfg.Style, s.Prompt, r.o.quality, editModel)
	finishFP := hashOf(genFP, finishVersion, fmt.Sprint(cfg.StickerSize, cfg.Border, cfg.Margin), fmt.Sprint(cfg.finish()))
	raw := r.out("stickers", s.ID+".raw.png")
	final := r.out("stickers", s.ID+".png")
	if r.upToDate(final, finishFP) {
		r.say("· %s up to date", s.ID)
		return nil
	}
	// Raws rendered before generation and finishing were fingerprinted
	// separately carry the old combined fingerprint on the final; adopt
	// them when it matches today's prompts rather than paying again.
	legacyFP := hashOf(toolVersion, "sticker", sheetFP, cfg.Style, s.Prompt, r.o.quality, editModel, fmt.Sprint(cfg.StickerSize, cfg.Border, cfg.Margin))
	if exists(raw) && r.fps[raw] == "" && r.fps[final] == legacyFP && !r.o.force {
		r.done(raw, genFP)
	}
	if r.upToDate(raw, genFP) {
		if r.o.dry {
			r.mu.Lock()
			r.planned = append(r.planned, fmt.Sprintf("sticker %s (re-finish the kept raw, no API call)", s.ID))
			r.mu.Unlock()
			return nil
		}
		if err := r.finish(s.ID, raw, final, finishFP); err != nil {
			return err
		}
		r.say("✓ %s re-finished from the kept raw", s.ID)
		return nil
	}
	if r.o.dry {
		r.mu.Lock()
		r.planned = append(r.planned, fmt.Sprintf("sticker %s (%dx%d, transparent)", s.ID, stickerGenPx, stickerGenPx))
		r.mu.Unlock()
		return nil
	}
	r.say("▶ %s", s.ID)
	started := time.Now()
	prompt := fmt.Sprintf("%s\n\nUsing the attached style sheet as the exact reference for style, palette and line, draw one sticker: %s Single subject, centred, filling most of the frame, whole subject visible with nothing cut off, no shadow on the ground, no text, no background — fully transparent background.", cfg.Style, s.Prompt)
	img, err := r.oa.Edit(r.ctx, openai.ImageRequest{Model: editModel, Prompt: prompt, Size: fmt.Sprintf("%dx%d", stickerGenPx, stickerGenPx), Quality: r.o.quality, Background: "transparent", References: [][]byte{sheet}})
	if err != nil {
		return err
	}
	if err := os.WriteFile(raw, img.PNG, 0o644); err != nil {
		return err
	}
	r.done(raw, genFP)
	if err := r.finish(s.ID, raw, final, finishFP); err != nil {
		return err
	}
	r.say("✓ %s (%s, %.0fs)", s.ID, r.charge(img.Usage), time.Since(started).Seconds())
	return nil
}

// finish turns a kept raw generation into the pack's sticker: trimmed,
// cleaned, bordered and given the printed finish (stickerimg).
func (r *renderer) finish(id, raw, final, finishFP string) error {
	cfg := r.c.cfg
	data, err := os.ReadFile(raw)
	if err != nil {
		return err
	}
	src, err := stickerimg.Decode(data)
	if err != nil {
		return fmt.Errorf("%s: %w", id, err)
	}
	finish := cfg.finish()
	out, err := stickerimg.Sticker(src, stickerimg.StickerOptions{Size: cfg.StickerSize, Border: cfg.Border, Margin: cfg.Margin, Threshold: 8, Finish: &finish})
	if err != nil {
		return fmt.Errorf("%s: %w", id, err)
	}
	png, err := stickerimg.Encode(out)
	if err != nil {
		return err
	}
	if err := os.WriteFile(final, png, 0o644); err != nil {
		return err
	}
	r.done(final, finishFP)
	return nil
}

// faceVersion changes whenever the face mask or composite changes.
const faceVersion = "1"

// face makes one expression variant of a sticker: the kept raw is sent with
// a mask over the face and the expression's prompt (kept as
// <id>.<expr>.gen.png), only the face of the result is laid over the raw —
// same outline, same everything else — as <id>.<expr>.raw.png, and that is
// finished exactly like the sticker into <id>.<expr>.png. The variant can
// then replace the sticker's texture in place.
func (r *renderer) face(s stickerSpec, e expressionSpec) error {
	cfg := r.c.cfg
	key := s.ID + "." + e.ID
	raw := r.out("stickers", s.ID+".raw.png")
	if !exists(raw) {
		return errors.New("no raw art yet; render the sticker first")
	}
	genFP := hashOf(toolVersion, "face", faceVersion, r.fps[raw], cfg.Style, e.Prompt, fmt.Sprint(*s.Face), s.FaceNote, r.o.quality, editModel)
	finishFP := hashOf(genFP, finishVersion, fmt.Sprint(cfg.StickerSize, cfg.Border, cfg.Margin), fmt.Sprint(cfg.finish()))
	gen := r.out("stickers", key+".gen.png")
	comp := r.out("stickers", key+".raw.png")
	final := r.out("stickers", key+".png")
	if r.upToDate(final, finishFP) {
		r.say("· %s up to date", key)
		return nil
	}
	rawData, err := os.ReadFile(raw)
	if err != nil {
		return err
	}
	base, err := stickerimg.Decode(rawData)
	if err != nil {
		return err
	}
	if !r.upToDate(gen, genFP) {
		if r.o.dry {
			r.mu.Lock()
			r.planned = append(r.planned, fmt.Sprintf("expression %s (%dx%d, face masked)", key, stickerGenPx, stickerGenPx))
			r.mu.Unlock()
			return nil
		}
		r.say("▶ %s", key)
		started := time.Now()
		b := base.Bounds()
		maskPNG, err := stickerimg.Encode(stickerimg.FaceMask(b.Dx(), b.Dy(), *s.Face))
		if err != nil {
			return err
		}
		note := ""
		if s.FaceNote != "" {
			note = " " + s.FaceNote
		}
		prompt := fmt.Sprintf("%s\n\nThis is a finished sticker character: %s%s Repaint ONLY its face, inside the masked area, to show this expression: %s The surface the face is drawn on keeps exactly its colour and texture as in the image. Keep the character recognisably the same: the same head shape, fur or skin, colours, outline weight and art style, the eyes in the same places and the same size family, the cheeks, the nose or beak. If it has a beak, keep the beak's shape (it may open a little) and show the feeling through the eyes and brows. Nothing outside the face changes. Friendly and gentle, never scary. Fully transparent background.", cfg.Style, s.Prompt, note, e.Prompt)
		img, err := r.oa.Edit(r.ctx, openai.ImageRequest{Model: editModel, Prompt: prompt, Size: fmt.Sprintf("%dx%d", b.Dx(), b.Dy()), Quality: r.o.quality, Background: "transparent", References: [][]byte{rawData}, Mask: maskPNG})
		if err != nil {
			return err
		}
		if err := os.WriteFile(gen, img.PNG, 0o644); err != nil {
			return err
		}
		r.done(gen, genFP)
		r.say("✓ %s (%s, %.0fs)", key, r.charge(img.Usage), time.Since(started).Seconds())
	} else if r.o.dry {
		return nil
	}
	genData, err := os.ReadFile(gen)
	if err != nil {
		return err
	}
	edited, err := stickerimg.Decode(genData)
	if err != nil {
		return err
	}
	png, err := stickerimg.Encode(stickerimg.Face(base, edited, *s.Face))
	if err != nil {
		return err
	}
	if err := os.WriteFile(comp, png, 0o644); err != nil {
		return err
	}
	return r.finish(key, comp, final, finishFP)
}

// scene renders each plane as a complete 4:3 picture first (that is what
// iPads show), then outpaints it to the 2:1 wide rendition with the centre
// masked off, so the base is the composed image and the wide one only adds
// to its sides.
func (r *renderer) scene(sheet []byte, sheetFP string) error {
	cfg := r.c.cfg
	size := fmt.Sprintf("%dx%d", baseW, baseH)
	wide := fmt.Sprintf("%dx%d", wideW, baseH)
	framing := "Compose it as a complete picture: framing elements such as the nearest trees at the left and right edges of THIS image, an open middle for the stickers. " + sceneSafeArea
	extend := "Extend the attached scene seamlessly into the transparent side bands, continuing the same style, lighting, horizon and ground line, adding more of the same scenery beyond the current edges. Do not change the existing centre."
	if neutral := sceneNeutral(r.c.pack.EffectiveSetting()); neutral != "" {
		framing += " " + neutral
		extend += " " + neutral
	}

	bgFP := hashOf(toolVersion, "background", sheetFP, cfg.Style, cfg.Scene.Background, r.o.quality, "4")
	bgBase, bgWide := r.out("art", "background.png"), r.out("art", "background-wide.png")
	if r.upToDate(bgWide, bgFP) && r.upToDate(bgBase, bgFP) {
		r.say("· background up to date")
	} else if r.o.dry {
		r.planned = append(r.planned, "background ("+size+")", "background-wide ("+wide+", outpaint around the masked centre)")
	} else {
		r.say("▶ background")
		prompt := fmt.Sprintf("%s\n\nUsing the attached style sheet as the exact style reference, paint the scene background: %s No characters, no animals, no text. %s", cfg.Style, cfg.Scene.Background, framing)
		img, err := r.oa.Edit(r.ctx, openai.ImageRequest{Model: editModel, Prompt: prompt, Size: size, Quality: r.o.quality, Background: "opaque", References: [][]byte{sheet}})
		if err != nil {
			return fmt.Errorf("background: %w", err)
		}
		cost := r.charge(img.Usage)
		if err := r.extend(img.PNG, bgBase, bgWide, extend, "opaque", wide, false); err != nil {
			return fmt.Errorf("background-wide: %w", err)
		}
		r.done(bgBase, bgFP)
		r.done(bgWide, bgFP)
		r.say("✓ background (%s) + wide", cost)
	}

	fgFP := hashOf(toolVersion, "foreground", bgFP, cfg.Scene.Foreground, r.o.quality, "4")
	fgBase, fgWide := r.out("art", "foreground.png"), r.out("art", "foreground-wide.png")
	if r.upToDate(fgWide, fgFP) && r.upToDate(fgBase, fgFP) {
		r.say("· foreground up to date")
		return nil
	}
	if r.o.dry {
		r.planned = append(r.planned, "foreground ("+size+", transparent)", "foreground-wide ("+wide+", outpaint around the masked centre)")
		return nil
	}
	bg, err := os.ReadFile(bgBase)
	if err != nil {
		return errors.New("foreground needs the background first")
	}
	if small, err := downscale(bg, 1024); err == nil {
		bg = small
	}
	r.say("▶ foreground")
	prompt := fmt.Sprintf("%s\n\nThe first attached image is the finished background of a scene at the same framing as the output. Paint only the foreground plane that sits in front of it, matching its style, lighting and perspective exactly: %s Everything that is not a foreground element must be fully transparent. No characters, no animals, no text. %s The nearest trunks and plants may run through the top and bottom bands, but keep their interesting parts (foliage, flowers, anything eye-catching) in the central 70%%.", cfg.Style, cfg.Scene.Foreground, sceneSafeArea)
	img, err := r.oa.Edit(r.ctx, openai.ImageRequest{Model: editModel, Prompt: prompt, Size: size, Quality: r.o.quality, Background: "transparent", References: [][]byte{bg, sheet}})
	if err != nil {
		return fmt.Errorf("foreground: %w", err)
	}
	cost := r.charge(img.Usage)
	if err := r.extend(img.PNG, fgBase, fgWide, extend+" Keep everything outside the foreground elements fully transparent.", "transparent", wide, true); err != nil {
		return fmt.Errorf("foreground-wide: %w", err)
	}
	r.done(fgBase, fgFP)
	r.done(fgWide, fgFP)
	r.say("✓ foreground (%s) + wide", cost)
	return nil
}

// extend outpaints a base plane to the wide width with the centre masked
// off (the API paints the transparent parts of the mask), then writes the
// wide file and the base re-cut from its centre so the two match exactly.
func (r *renderer) extend(basePNG []byte, basePath, widePath, prompt, background, wideSize string, keepAlpha bool) error {
	base, err := stickerimg.Decode(basePNG)
	if err != nil {
		return err
	}
	canvas, mask, err := stickerimg.WideCanvas(base, wideW)
	if err != nil {
		return err
	}
	canvasPNG, _ := stickerimg.Encode(canvas)
	maskPNG, _ := stickerimg.Encode(mask)
	img, err := r.oa.Edit(r.ctx, openai.ImageRequest{Model: editModel, Prompt: prompt, Size: wideSize, Quality: r.o.quality, Background: background, References: [][]byte{canvasPNG}, Mask: maskPNG})
	if err != nil {
		return err
	}
	r.say("  … wide (%s)", r.charge(img.Usage))
	return r.splitWide(img.PNG, basePath, widePath, keepAlpha)
}

// splitWide writes the wide rendition and the base cut from its centre.
func (r *renderer) splitWide(widePNG []byte, basePath, widePath string, keepAlpha bool) error {
	img, err := stickerimg.Decode(widePNG)
	if err != nil {
		return err
	}
	if img.Bounds().Dx() != wideW || img.Bounds().Dy() != baseH {
		return fmt.Errorf("wide rendition came back %v, want %dx%d", img.Bounds().Size(), wideW, baseH)
	}
	var wideOut, baseOut []byte
	if keepAlpha {
		wideOut, _ = stickerimg.Encode(img)
		baseOut, _ = stickerimg.Encode(stickerimg.Centre(img, baseW))
	} else {
		flat := stickerimg.Flatten(img, color.White)
		wideOut, _ = stickerimg.Encode(flat)
		baseOut, _ = stickerimg.Encode(stickerimg.Centre(flat, baseW))
	}
	if err := os.WriteFile(widePath, wideOut, 0o644); err != nil {
		return err
	}
	return os.WriteFile(basePath, baseOut, 0o644)
}

func (r *renderer) summary() {
	if r.calls == 0 {
		fmt.Println("\nNo API calls made.")
		return
	}
	fmt.Printf("\nThis run: %d API calls, %d image-in + %d text-in + %d output tokens ≈ $%.2f (list prices, standard tier)\n",
		r.calls, r.spent.InputDetails.ImageTokens, r.spent.InputDetails.TextTokens, r.spent.OutputTokens, r.spent.Cost(openai.DefaultPrices))
}

// ---------- install ----------

// runInstall encodes the reviewed PNGs in out/ into the pack as WebP
// (cached in out/render.json by source hash, so an unchanged image is not
// re-encoded), points the manifest at them and drops the files they
// replace.
func runInstall(args []string) error {
	fs := flag.NewFlagSet("install", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	artDir := fs.String("art", "", "art directory (default author/art/<packID>)")
	bump := fs.Bool("bump", false, "increment the pack's content version")
	fs.Parse(args)
	c, err := load(*packDir, *artDir, true)
	if err != nil {
		return err
	}
	outDir := filepath.Join(c.artDir, "out")
	cache := map[string]string{}
	if data, err := os.ReadFile(filepath.Join(outDir, "render.json")); err == nil {
		json.Unmarshal(data, &cache)
	}
	encoded, installed := 0, 0
	var replaced []string
	byID := map[string]int{}
	for i, s := range c.pack.Stickers {
		byID[s.ID] = i
	}
	for _, s := range c.cfg.Stickers {
		src := filepath.Join(outDir, "stickers", s.ID+".png")
		if !exists(src) {
			fmt.Printf("skip %s: not rendered\n", s.ID)
			continue
		}
		rel := "stickers/" + s.ID + ".webp"
		did, err := stickerimg.InstallWebP(src, filepath.Join(c.packDir, rel), cache)
		if err != nil {
			return err
		}
		if did {
			encoded++
		}
		// Expression variants, installed next to the sticker.
		var expressions map[string]string
		if s.Face != nil {
			for _, e := range c.cfg.Expressions {
				esrc := filepath.Join(outDir, "stickers", s.ID+"."+e.ID+".png")
				if !exists(esrc) {
					continue
				}
				erel := "stickers/" + s.ID + "." + e.ID + ".webp"
				did, err := stickerimg.InstallWebP(esrc, filepath.Join(c.packDir, erel), cache)
				if err != nil {
					return err
				}
				if did {
					encoded++
				}
				if expressions == nil {
					expressions = map[string]string{}
				}
				expressions[e.ID] = erel
			}
		}
		if i, ok := byID[s.ID]; ok {
			if old := c.pack.Stickers[i].Image; old != rel {
				replaced = append(replaced, old)
			}
			c.pack.Stickers[i].Image = rel
			c.pack.Stickers[i].Expressions = expressions
			if len(s.Name) > 0 {
				c.pack.Stickers[i].Name = s.Name
			}
		} else {
			c.pack.Stickers = append(c.pack.Stickers, manifest.Sticker{ID: s.ID, Name: s.Name, Image: rel, Expressions: expressions})
		}
		installed++
	}
	planes := map[string]*string{"background": &c.pack.Background, "foreground": &c.pack.Foreground, "background-wide": &c.pack.BackgroundWide, "foreground-wide": &c.pack.ForegroundWide}
	names := []string{"background", "foreground", "background-wide", "foreground-wide"}
	scene := 0
	for _, n := range names {
		src := filepath.Join(outDir, "art", n+".png")
		if !exists(src) {
			continue
		}
		rel := "art/" + n + ".webp"
		did, err := stickerimg.InstallWebP(src, filepath.Join(c.packDir, rel), cache)
		if err != nil {
			return err
		}
		if did {
			encoded++
		}
		if old := *planes[n]; old != "" && old != rel {
			replaced = append(replaced, old)
		}
		*planes[n] = rel
		scene++
	}
	if data, err := json.MarshalIndent(cache, "", "  "); err == nil {
		os.WriteFile(filepath.Join(outDir, "render.json"), append(data, '\n'), 0o644)
	}
	sort.SliceStable(c.pack.Stickers, func(i, j int) bool { return c.pack.Stickers[i].ID < c.pack.Stickers[j].ID })
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
	// Files the manifest no longer references (the PNGs a pack shipped
	// before it went WebP) would still be bundled; drop them.
	for _, rel := range replaced {
		if err := os.Remove(filepath.Join(c.packDir, rel)); err == nil {
			fmt.Printf("  removed %s (replaced)\n", rel)
		}
	}
	fmt.Printf("✓ installed %d stickers and %d scene planes into %s (version %d; %d encoded to WebP, the rest unchanged); manifest validates\n", installed, scene, c.packDir, c.pack.Version, encoded)
	return nil
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
