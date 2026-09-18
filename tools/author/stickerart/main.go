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
// foreground plane. Outputs land in <art>/out/ and are cached by fingerprint.
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
	toolVersion   = "1"
	genModel      = "gpt-image-2.5-flare"
	editModel     = "gpt-image-2.5-sunburst"
	baseW, baseH  = 2048, 1536
	wideW         = 3072
	sheetSize     = "1536x1024"
	stickerGenPx  = 1024
	defaultQual   = "high"
	sceneSafeArea = "Keep the horizon, the ground line and every important element inside the central 70% of the height; the top and bottom bands are only sky and plain ground that can be cropped."
)

// artConfig is art.json.
type artConfig struct {
	Style       string            `json:"style"`
	StyleSheet  string            `json:"styleSheet"`
	StickerSize int               `json:"stickerSize"`
	Border      float64           `json:"border"`
	Margin      float64           `json:"margin"`
	Stickers    []stickerSpec     `json:"stickers"`
	Scene       sceneSpec         `json:"scene"`
	Notes       map[string]string `json:"notes,omitempty"`
}

type stickerSpec struct {
	ID     string            `json:"id"`
	Name   map[string]string `json:"name"`
	Prompt string            `json:"prompt"`
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
			c.cfg.StickerSize = 1024
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
		StickerSize: 1024, Border: 0.025, Margin: 0.03,
		Scene: sceneSpec{Background: "The scene behind the stickers, no characters.", Foreground: "Only the elements that sit in front of the stickers (e.g. the nearest trees and grass), everything else transparent."},
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

func (r *renderer) sticker(s stickerSpec, sheet []byte, sheetFP string) error {
	cfg := r.c.cfg
	fp := hashOf(toolVersion, "sticker", sheetFP, cfg.Style, s.Prompt, r.o.quality, editModel, fmt.Sprint(cfg.StickerSize, cfg.Border, cfg.Margin))
	raw := r.out("stickers", s.ID+".raw.png")
	final := r.out("stickers", s.ID+".png")
	if r.upToDate(final, fp) {
		r.say("· %s up to date", s.ID)
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
	src, err := stickerimg.Decode(img.PNG)
	if err != nil {
		return err
	}
	out, err := stickerimg.Sticker(src, stickerimg.StickerOptions{Size: cfg.StickerSize, Border: cfg.Border, Margin: cfg.Margin, Threshold: 8})
	if err != nil {
		return err
	}
	data, err := stickerimg.Encode(out)
	if err != nil {
		return err
	}
	if err := os.WriteFile(final, data, 0o644); err != nil {
		return err
	}
	r.done(final, fp)
	r.say("✓ %s (%s, %.0fs)", s.ID, r.charge(img.Usage), time.Since(started).Seconds())
	return nil
}

// scene renders the two planes directly at the wide 2:1 size and cuts the
// 4:3 base from the centre of each, so base and wide match pixel for pixel
// and each plane costs one call.
func (r *renderer) scene(sheet []byte, sheetFP string) error {
	cfg := r.c.cfg
	wide := fmt.Sprintf("%dx%d", wideW, baseH)
	composition := fmt.Sprintf("The image is a wide %d:%d panorama; the central 4:3 area is the main view and must be a complete, balanced composition on its own, with the side thirds continuing the scene naturally. %s", wideW, baseH, sceneSafeArea)

	bgFP := hashOf(toolVersion, "background", sheetFP, cfg.Style, cfg.Scene.Background, r.o.quality, "2")
	bgBase, bgWide := r.out("art", "background.png"), r.out("art", "background-wide.png")
	if r.upToDate(bgWide, bgFP) && r.upToDate(bgBase, bgFP) {
		r.say("· background up to date")
	} else if r.o.dry {
		r.planned = append(r.planned, "background-wide ("+wide+"; base cut from its centre)")
	} else {
		r.say("▶ background")
		prompt := fmt.Sprintf("%s\n\nUsing the attached style sheet as the exact style reference, paint the scene background: %s No characters, no animals, no text. %s", cfg.Style, cfg.Scene.Background, composition)
		img, err := r.oa.Edit(r.ctx, openai.ImageRequest{Model: editModel, Prompt: prompt, Size: wide, Quality: r.o.quality, Background: "opaque", References: [][]byte{sheet}})
		if err != nil {
			return fmt.Errorf("background: %w", err)
		}
		if err := r.splitWide(img.PNG, bgBase, bgWide, false); err != nil {
			return fmt.Errorf("background: %w", err)
		}
		r.done(bgBase, bgFP)
		r.done(bgWide, bgFP)
		r.say("✓ background + wide (%s)", r.charge(img.Usage))
	}

	fgFP := hashOf(toolVersion, "foreground", bgFP, cfg.Scene.Foreground, r.o.quality, "2")
	fgBase, fgWide := r.out("art", "foreground.png"), r.out("art", "foreground-wide.png")
	if r.upToDate(fgWide, fgFP) && r.upToDate(fgBase, fgFP) {
		r.say("· foreground up to date")
		return nil
	}
	if r.o.dry {
		r.planned = append(r.planned, "foreground-wide ("+wide+", transparent; base cut from its centre)")
		return nil
	}
	bg, err := os.ReadFile(bgWide)
	if err != nil {
		return errors.New("foreground needs the background first")
	}
	if small, err := downscale(bg, 1536); err == nil {
		bg = small
	}
	r.say("▶ foreground")
	prompt := fmt.Sprintf("%s\n\nThe first attached image is the finished background of a scene at the same framing as the output. Paint only the foreground plane that sits in front of it, matching its style, lighting and perspective exactly: %s Everything that is not a foreground element must be fully transparent. No characters, no animals, no text. %s", cfg.Style, cfg.Scene.Foreground, composition)
	img, err := r.oa.Edit(r.ctx, openai.ImageRequest{Model: editModel, Prompt: prompt, Size: wide, Quality: r.o.quality, Background: "transparent", References: [][]byte{bg, sheet}})
	if err != nil {
		return fmt.Errorf("foreground: %w", err)
	}
	if err := r.splitWide(img.PNG, fgBase, fgWide, true); err != nil {
		return fmt.Errorf("foreground: %w", err)
	}
	r.done(fgBase, fgFP)
	r.done(fgWide, fgFP)
	r.say("✓ foreground + wide (%s)", r.charge(img.Usage))
	return nil
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
	installed := 0
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
		rel := "stickers/" + s.ID + ".png"
		if err := copyFile(src, filepath.Join(c.packDir, rel)); err != nil {
			return err
		}
		if i, ok := byID[s.ID]; ok {
			c.pack.Stickers[i].Image = rel
			if len(s.Name) > 0 {
				c.pack.Stickers[i].Name = s.Name
			}
		} else {
			c.pack.Stickers = append(c.pack.Stickers, manifest.Sticker{ID: s.ID, Name: s.Name, Image: rel})
		}
		installed++
	}
	planes := map[string]*string{"background.png": &c.pack.Background, "foreground.png": &c.pack.Foreground, "background-wide.png": &c.pack.BackgroundWide, "foreground-wide.png": &c.pack.ForegroundWide}
	names := []string{"background.png", "foreground.png", "background-wide.png", "foreground-wide.png"}
	scene := 0
	for _, n := range names {
		src := filepath.Join(outDir, "art", n)
		if !exists(src) {
			continue
		}
		if err := copyFile(src, filepath.Join(c.packDir, "art", n)); err != nil {
			return err
		}
		*planes[n] = "art/" + n
		scene++
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
	fmt.Printf("✓ installed %d stickers and %d scene planes into %s (version %d); manifest validates\n", installed, scene, c.packDir, c.pack.Version)
	return nil
}

// downscale returns the PNG resized so its longer edge is maxEdge px.
func downscale(pngData []byte, maxEdge int) ([]byte, error) {
	img, err := stickerimg.Decode(pngData)
	if err != nil {
		return nil, err
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w <= maxEdge && h <= maxEdge {
		return pngData, nil
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
