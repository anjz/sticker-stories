// Command uiart makes the app's own art — the main screen's background,
// the "Sticker Stories" title, the store tile and each sticker pack's
// cover — as a few alternatives to choose from, then installs the chosen
// one.
//
//	uiart render [-only background,title,store,cover,cover:forest] [-count 4]
//	uiart pick background 3 | title 2 | store 4 | cover:forest 1
//
// Prompts live in author/art/app/ui.json; candidates land in
// author/art/app/out/<asset>/<n>.png with a choices.png contact sheet per
// asset. Rendering fills each asset up to -count candidates and keeps the
// ones already there, so a prompt tweak plus -more 2 adds two alternatives
// without losing the others (-fresh archives the old set instead). See
// README.md.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"stickerstories/tools/internal/dotenv"
	"stickerstories/tools/internal/manifest"
	"stickerstories/tools/internal/openai"
	"stickerstories/tools/internal/stickerimg"
)

const (
	genModel  = "gpt-image-2.5-flare"    // text → image
	editModel = "gpt-image-2.5-sunburst" // with reference images (covers)
	// Where the chosen app art goes: bundled with the app target.
	appArtDir = "../app/StickerStories/Art"
	// Longest edge of a reference image sent to the API.
	referencePx = 1536
	// How many of the packs' finished stickers the store tile is drawn
	// from, spread across the packs, and their longest edge.
	storeStickers  = 8
	storeStickerPx = 512
)

// uiConfig is ui.json.
type uiConfig struct {
	Notes map[string]string `json:"notes,omitempty"`
	// Style is prepended to every prompt, so the pieces belong together.
	Style      string    `json:"style"`
	Candidates int       `json:"candidates,omitempty"`
	Background assetSpec `json:"background"`
	Title      titleSpec `json:"title"`
	Cover      coverSpec `json:"cover"`
	// Store is the main menu tile that opens the store (More stories).
	Store assetSpec `json:"store"`
}

type assetSpec struct {
	Size   string `json:"size"`
	Prompt string `json:"prompt"`
}

type titleSpec struct {
	assetSpec
	// Text is the exact wording to letter.
	Text string `json:"text"`
}

type coverSpec struct {
	assetSpec
	// Packs adds pack-specific direction by pack ID (optional).
	Packs map[string]string `json:"packs,omitempty"`
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
	case "pick":
		err = runPick(os.Args[2:])
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "✗ %v\n", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: uiart render [flags] | uiart pick <background|title|store|cover:<pack>> <n>  (see -h)")
	os.Exit(2)
}

func loadConfig(artDir string) (*uiConfig, error) {
	data, err := os.ReadFile(filepath.Join(artDir, "ui.json"))
	if err != nil {
		return nil, err
	}
	var c uiConfig
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("ui.json: %w", err)
	}
	if c.Candidates <= 0 {
		c.Candidates = 4
	}
	return &c, nil
}

// ---------- render ----------

// job is one asset to fill with candidates.
type job struct {
	key    string // background | title | cover:<pack>
	dir    string // its candidates folder
	prompt string
	size   string
	// transparent asks for a transparent background (the title).
	transparent bool
	// references are sent with an edit call (covers); none means generate.
	references [][]byte
}

func runRender(args []string) error {
	fs := flag.NewFlagSet("render", flag.ExitOnError)
	artDir := fs.String("art", filepath.Join("author", "art", "app"), "art directory holding ui.json")
	packsDir := fs.String("packs", filepath.Join("..", "packs"), "folder of packs (for covers)")
	only := fs.String("only", "", "comma-separated: background, title, store, cover (every pack), cover:<pack>")
	count := fs.Int("count", 0, "candidates per asset (default: ui.json's candidates, or 4)")
	more := fs.Int("more", 0, "add this many candidates beyond those already there")
	fresh := fs.Bool("fresh", false, "archive the existing candidates and start a new set")
	quality := fs.String("quality", "high", "low | medium | high | xhigh | max")
	parallel := fs.Int("parallel", 4, "images generated concurrently")
	dry := fs.Bool("dry-run", false, "list what would be generated; no API calls")
	fs.Parse(args)

	cfg, err := loadConfig(*artDir)
	if err != nil {
		return err
	}
	want := func(key string) bool {
		if *only == "" {
			return true
		}
		for _, k := range strings.Split(*only, ",") {
			k = strings.TrimSpace(k)
			if k == key || (k == "cover" && strings.HasPrefix(key, "cover:")) {
				return true
			}
		}
		return false
	}
	out := filepath.Join(*artDir, "out")
	style := strings.TrimSpace(cfg.Style)

	var jobs []job
	if want("background") {
		jobs = append(jobs, job{
			key: "background", dir: filepath.Join(out, "background"), size: cfg.Background.Size,
			prompt: style + "\n\n" + strings.TrimSpace(cfg.Background.Prompt) +
				"\n\nNo text, no letters, no characters or animals, no sticker shapes, no frames or borders.",
		})
	}
	if want("title") {
		jobs = append(jobs, job{
			key: "title", dir: filepath.Join(out, "title"), size: cfg.Title.Size, transparent: true,
			prompt: style + "\n\n" + strings.TrimSpace(cfg.Title.Prompt) +
				fmt.Sprintf("\n\nThe lettering reads exactly \"%s\" — spelled exactly so, nothing else written anywhere. A fully transparent background around the title: no scenery, no backdrop, no box behind it.", cfg.Title.Text),
		})
	}
	packs, err := listPacks(*packsDir)
	if err != nil {
		return err
	}
	if want("store") && cfg.Store.Prompt != "" {
		refs, err := storeReferences(packs)
		if err != nil {
			return fmt.Errorf("store: %w", err)
		}
		jobs = append(jobs, job{
			key: "store", dir: filepath.Join(out, "store"), size: cfg.Store.Size, references: refs,
			prompt: style + "\n\nThe attached images are stickers from this app's sticker packs: use these characters and this exact painted style.\n\n" +
				strings.TrimSpace(cfg.Store.Prompt) +
				"\n\nNo text, no letters, no logo anywhere in the picture — the app writes the tile's label. No frame or border around the picture.",
		})
	}
	for _, p := range packs {
		key := "cover:" + p.m.ID
		if !want(key) {
			continue
		}
		j, err := coverJob(cfg, style, p, out)
		if err != nil {
			return fmt.Errorf("%s: %w", key, err)
		}
		jobs = append(jobs, j)
	}
	if len(jobs) == 0 {
		return errors.New("nothing to render (check -only)")
	}

	// Plan: which candidate numbers each asset gets.
	type task struct {
		j job
		n int
	}
	var tasks []task
	for _, j := range jobs {
		if *fresh && !*dry {
			if err := archive(j.dir); err != nil {
				return err
			}
		}
		have := candidates(j.dir)
		if *fresh {
			have = nil
		}
		target := *count
		if target <= 0 {
			target = cfg.Candidates
		}
		var numbers []int
		if *more > 0 {
			next := 1
			if len(have) > 0 {
				next = have[len(have)-1] + 1
			}
			for i := 0; i < *more; i++ {
				numbers = append(numbers, next+i)
			}
		} else {
			present := map[int]bool{}
			for _, n := range have {
				present[n] = true
			}
			for n := 1; n <= target; n++ {
				if !present[n] {
					numbers = append(numbers, n)
				}
			}
		}
		if len(numbers) == 0 {
			fmt.Printf("· %s: %d candidates already there (-more N adds some, -fresh starts over)\n", j.key, len(have))
		}
		for _, n := range numbers {
			tasks = append(tasks, task{j, n})
		}
	}
	if *dry {
		fmt.Printf("Dry run: %d images at quality %s:\n", len(tasks), *quality)
		for _, t := range tasks {
			kind := "generate"
			if len(t.j.references) > 0 {
				kind = fmt.Sprintf("edit, %d references", len(t.j.references))
			}
			fmt.Printf("  %s #%d (%s, %s)\n", t.j.key, t.n, t.j.size, kind)
		}
		return nil
	}
	if len(tasks) == 0 {
		return nil
	}
	oa, err := client()
	if err != nil {
		return err
	}

	ctx := context.Background()
	var (
		mu    sync.Mutex
		usage openai.Usage
		fails []string
		wg    sync.WaitGroup
	)
	sem := make(chan struct{}, max(1, *parallel))
	for _, t := range tasks {
		wg.Add(1)
		sem <- struct{}{}
		go func(t task) {
			defer wg.Done()
			defer func() { <-sem }()
			start := time.Now()
			req := openai.ImageRequest{Prompt: t.j.prompt, Size: t.j.size, Quality: *quality, Background: "opaque"}
			if t.j.transparent {
				req.Background = "transparent"
			}
			var img *openai.Image
			var err error
			if len(t.j.references) > 0 {
				req.Model, req.References = editModel, t.j.references
				img, err = oa.Edit(ctx, req)
			} else {
				req.Model = genModel
				img, err = oa.Generate(ctx, req)
			}
			if err == nil {
				err = os.MkdirAll(t.j.dir, 0o755)
			}
			if err == nil {
				err = os.WriteFile(filepath.Join(t.j.dir, fmt.Sprintf("%d.png", t.n)), img.PNG, 0o644)
			}
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				fails = append(fails, fmt.Sprintf("%s #%d: %v", t.j.key, t.n, err))
				fmt.Printf("✗ %s #%d: %v\n", t.j.key, t.n, err)
				return
			}
			usage.Add(img.Usage)
			fmt.Printf("✓ %s #%d ($%.3f, %.0fs)\n", t.j.key, t.n, img.Usage.Cost(openai.DefaultPrices), time.Since(start).Seconds())
		}(t)
	}
	wg.Wait()

	for _, j := range jobs {
		if err := contactSheet(j.dir, j.transparent); err != nil {
			fmt.Printf("  (no choices.png for %s: %v)\n", j.key, err)
		}
	}
	fmt.Printf("\nThis run ≈ $%.2f (list prices). Compare each asset's choices.png (numbered left to right, top to bottom), then: uiart pick <asset> <n>\n", usage.Cost(openai.DefaultPrices))
	if len(fails) > 0 {
		return fmt.Errorf("%d image(s) failed", len(fails))
	}
	return nil
}

type pack struct {
	dir string
	m   *manifest.Manifest
}

func listPacks(dir string) ([]pack, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var packs []pack
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		p := filepath.Join(dir, e.Name())
		if _, err := os.Stat(filepath.Join(p, "manifest.json")); err != nil {
			continue
		}
		m, err := manifest.Load(p)
		if err != nil {
			return nil, err
		}
		packs = append(packs, pack{p, m})
	}
	return packs, nil
}

// coverJob asks for a cover drawn from the pack itself: its style sheet
// (the characters and the look) and its background art as references, so
// the cover belongs to the pack.
func coverJob(cfg *uiConfig, style string, p pack, out string) (job, error) {
	lang := p.m.Languages[0]
	name := p.m.DisplayName[lang]
	about := ""
	if d := p.m.Description[lang]; d != "" {
		about = " — " + d
	}
	packArt := filepath.Join("author", "art", p.m.ID, "out")
	var refs [][]byte
	for _, path := range []string{
		filepath.Join(packArt, "stylesheet.png"),
		filepath.Join(packArt, "art", "background.png"),
		filepath.Join(p.dir, filepath.FromSlash(p.m.Background)),
	} {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		small, err := downscale(data, referencePx)
		if err != nil {
			return job{}, fmt.Errorf("%s: %w", path, err)
		}
		refs = append(refs, small)
		if len(refs) == 2 {
			break
		}
	}
	if len(refs) == 0 {
		return job{}, errors.New("no style sheet or background art to draw the cover from")
	}
	prompt := style + "\n\n" +
		fmt.Sprintf("A cover for the sticker pack \"%s\"%s. The attached images are this pack's own art: its characters and style (first) and its scene (second). Use the very same style, palette and characters.\n\n", name, about) +
		strings.TrimSpace(cfg.Cover.Prompt)
	if extra := strings.TrimSpace(cfg.Cover.Packs[p.m.ID]); extra != "" {
		prompt += " " + extra
	}
	prompt += "\n\nNo text, no letters, no title, no logo anywhere in the picture — the app writes the pack's name itself. No border or frame."
	return job{key: "cover:" + p.m.ID, dir: filepath.Join(out, "cover-"+p.m.ID), prompt: prompt, size: cfg.Cover.Size, references: refs}, nil
}

// storeReferences picks up to storeStickers of the packs' finished
// stickers (from stickerart's out/), taking them in turn from each pack so
// every pack is represented.
func storeReferences(packs []pack) ([][]byte, error) {
	var perPack [][]string
	for _, p := range packs {
		var paths []string
		for _, st := range p.m.Stickers {
			path := filepath.Join("author", "art", p.m.ID, "out", "stickers", st.ID+".png")
			if _, err := os.Stat(path); err == nil {
				paths = append(paths, path)
			}
		}
		perPack = append(perPack, paths)
	}
	var refs [][]byte
	for i := 0; len(refs) < storeStickers; i++ {
		took := false
		for _, paths := range perPack {
			if i < len(paths) && len(refs) < storeStickers {
				data, err := os.ReadFile(paths[i])
				if err != nil {
					return nil, err
				}
				small, err := downscale(data, storeStickerPx)
				if err != nil {
					return nil, fmt.Errorf("%s: %w", paths[i], err)
				}
				refs = append(refs, small)
				took = true
			}
		}
		if !took {
			break
		}
	}
	if len(refs) == 0 {
		return nil, errors.New("no finished stickers in author/art/<pack>/out/stickers to draw from")
	}
	return refs, nil
}

// candidates lists the candidate numbers already in dir, ascending.
func candidates(dir string) []int {
	entries, _ := os.ReadDir(dir)
	var ns []int
	for _, e := range entries {
		if n, err := strconv.Atoi(strings.TrimSuffix(e.Name(), ".png")); err == nil && strings.HasSuffix(e.Name(), ".png") {
			ns = append(ns, n)
		}
	}
	sort.Ints(ns)
	return ns
}

// archive moves an asset's candidates into old/<timestamp>/.
func archive(dir string) error {
	ns := candidates(dir)
	if len(ns) == 0 {
		return nil
	}
	dst := filepath.Join(dir, "old", time.Now().Format("20060102-150405"))
	if err := os.MkdirAll(dst, 0o755); err != nil {
		return err
	}
	for _, n := range ns {
		name := fmt.Sprintf("%d.png", n)
		if err := os.Rename(filepath.Join(dir, name), filepath.Join(dst, name)); err != nil {
			return err
		}
	}
	os.Remove(filepath.Join(dir, "choices.png"))
	return nil
}

// contactSheet lays every candidate out in a grid (two per row, in number
// order) on a mid-grey so transparent art shows, as choices.png.
func contactSheet(dir string, checker bool) error {
	ns := candidates(dir)
	if len(ns) == 0 {
		return nil
	}
	var imgs []*image.RGBA
	for _, n := range ns {
		data, err := os.ReadFile(filepath.Join(dir, fmt.Sprintf("%d.png", n)))
		if err != nil {
			return err
		}
		img, err := stickerimg.Decode(data)
		if err != nil {
			return err
		}
		imgs = append(imgs, img)
	}
	cellW, cellH := 0, 0
	for _, img := range imgs {
		// Cells of 800 px wide, keeping each image's shape.
		w := 800
		h := img.Bounds().Dy() * w / img.Bounds().Dx()
		cellW, cellH = max(cellW, w), max(cellH, h)
	}
	cols := 2
	rows := (len(imgs) + cols - 1) / cols
	gap := 24
	sheet := image.NewRGBA(image.Rect(0, 0, cols*cellW+(cols+1)*gap, rows*cellH+(rows+1)*gap))
	draw.Draw(sheet, sheet.Bounds(), &image.Uniform{color.RGBA{120, 120, 120, 255}}, image.Point{}, draw.Src)
	for i, img := range imgs {
		h := img.Bounds().Dy() * cellW / img.Bounds().Dx()
		small := stickerimg.Resize(img, cellW, h)
		x := gap + (i%cols)*(cellW+gap)
		y := gap + (i/cols)*(cellH+gap)
		if checker {
			drawChecker(sheet, image.Rect(x, y, x+cellW, y+h))
		}
		draw.Draw(sheet, small.Bounds().Add(image.Pt(x, y)), small, image.Point{}, draw.Over)
	}
	data, err := stickerimg.Encode(sheet)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, "choices.png"), data, 0o644)
}

func drawChecker(img *image.RGBA, r image.Rectangle) {
	for y := r.Min.Y; y < r.Max.Y; y++ {
		for x := r.Min.X; x < r.Max.X; x++ {
			c := color.RGBA{200, 200, 200, 255}
			if ((x-r.Min.X)/24+(y-r.Min.Y)/24)%2 == 0 {
				c = color.RGBA{235, 235, 235, 255}
			}
			img.SetRGBA(x, y, c)
		}
	}
}

// ---------- pick ----------

func runPick(args []string) error {
	fs := flag.NewFlagSet("pick", flag.ExitOnError)
	artDir := fs.String("art", filepath.Join("author", "art", "app"), "art directory holding ui.json")
	packsDir := fs.String("packs", filepath.Join("..", "packs"), "folder of packs (for covers)")
	fs.Parse(args)
	if fs.NArg() != 2 {
		return errors.New("usage: uiart pick <background|title|store|cover:<pack>> <n>")
	}
	key := fs.Arg(0)
	n, err := strconv.Atoi(fs.Arg(1))
	if err != nil {
		return fmt.Errorf("candidate number: %w", err)
	}
	dirName := key
	if id, ok := strings.CutPrefix(key, "cover:"); ok {
		dirName = "cover-" + id
	}
	src := filepath.Join(*artDir, "out", dirName, fmt.Sprintf("%d.png", n))
	data, err := os.ReadFile(src)
	if err != nil {
		return fmt.Errorf("no candidate %d for %s: %w", n, key, err)
	}
	img, err := stickerimg.Decode(data)
	if err != nil {
		return err
	}

	switch {
	case key == "background":
		return install(img, filepath.Join(appArtDir, "menu-background.webp"))
	case key == "store":
		return install(img, filepath.Join(appArtDir, "menu-store.webp"))
	case key == "title":
		// Trim the transparent surround so the app can size the title by
		// its lettering.
		box := stickerimg.Bounds(img, 8)
		if box.Empty() {
			return errors.New("the title candidate is fully transparent")
		}
		pad := max(box.Dx(), box.Dy()) / 40
		box = box.Inset(-pad).Intersect(img.Bounds())
		trimmed := image.NewRGBA(image.Rect(0, 0, box.Dx(), box.Dy()))
		draw.Draw(trimmed, trimmed.Bounds(), img, box.Min, draw.Src)
		return install(trimmed, filepath.Join(appArtDir, "menu-title.webp"))
	case strings.HasPrefix(key, "cover:"):
		id := strings.TrimPrefix(key, "cover:")
		dir := filepath.Join(*packsDir, id)
		m, err := manifest.Load(dir)
		if err != nil {
			return err
		}
		rel := "art/cover.webp"
		if err := install(img, filepath.Join(dir, filepath.FromSlash(rel))); err != nil {
			return err
		}
		m.Cover = rel
		m.Version++
		if errs := m.Validate(dir); len(errs) > 0 {
			for _, e := range errs {
				fmt.Printf("  ✗ %v\n", e)
			}
			return errors.New("manifest would not validate; manifest.json left unchanged")
		}
		out, err := json.MarshalIndent(m, "", "  ")
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dir, "manifest.json"), append(out, '\n'), 0o644); err != nil {
			return err
		}
		fmt.Printf("✓ %s: cover set in the manifest (version %d); manifest validates\n", id, m.Version)
		return nil
	}
	return fmt.Errorf("unknown asset %q (background, title, store or cover:<pack>)", key)
}

// install writes img as WebP (lossy q90, lossless alpha) at dst.
func install(img image.Image, dst string) error {
	data, err := stickerimg.EncodeWebP(img)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(dst, data, 0o644); err != nil {
		return err
	}
	fmt.Printf("✓ installed %s (%d KB)\n", dst, len(data)/1024)
	return nil
}

// ---------- shared ----------

func client() (*openai.Client, error) {
	key := os.Getenv("OPENAI_API_KEY")
	if key == "" {
		return nil, errors.New("OPENAI_API_KEY is not set (put it in tools/.env)")
	}
	return openai.New(key), nil
}

// downscale returns the image (PNG or WebP) as a PNG whose longer edge is
// at most maxEdge px — what the API is sent as a reference.
func downscale(data []byte, maxEdge int) ([]byte, error) {
	img, err := stickerimg.Decode(data)
	if err != nil {
		return nil, err
	}
	w, h := img.Bounds().Dx(), img.Bounds().Dy()
	if w > maxEdge || h > maxEdge {
		if w >= h {
			w, h = maxEdge, h*maxEdge/w
		} else {
			w, h = w*maxEdge/h, maxEdge
		}
		img = stickerimg.Resize(img, w, h)
	}
	return stickerimg.Encode(img)
}
