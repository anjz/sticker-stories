// Command stickerrig makes puppets: a sticker cut into parts that the app
// moves on a skeleton (docs/pack-format.md, "Puppets"), so a character's
// animations are keyframes — data, not drawn frames — and a new one costs
// no image generation at all.
//
// Usage:
//
//	stickerrig draw    -pack ../packs/forest [-only owl] [-sheet face] [-quality high] [-local]
//	stickerrig parts   -pack ../packs/forest [-only owl]
//	stickerrig install -pack ../packs/forest [-only owl] [-bump]
//	stickerrig preview -pack ../packs/forest [-only owl] [-png]
//	stickerrig check   -pack ../packs/forest [-only owl] [-tuck 17 …]
//
// A sticker's rig file (tools/author/art/<packID>/rigs/<sticker>.json)
// holds the sheets the edits model draws from the sticker's raw art (the
// parts on one, the face pieces on another), which piece of a sheet each
// part is, the skeleton and its slots at rest, the faces, and the
// animations as keyframes — its own, or shared ones from templates/. draw
// costs API calls (none with -local); everything after it is free: parts
// lists the pieces it finds on each sheet, install cuts them out into the
// pack's atlas and writes the rig, every animation's sidecar and the
// sticker's list of them in the manifest, and preview writes an HTML page
// that plays them (and with -png, pictures of it to look at). The README
// has the whole workflow.
//
// The API key is OPENAI_API_KEY from tools/.env. Dev-time only.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"stickerstories/tools/internal/dotenv"
	"stickerstories/tools/internal/localimage"
	"stickerstories/tools/internal/manifest"
	"stickerstories/tools/internal/openai"
	"stickerstories/tools/internal/stickerimg"
)

// The OpenAI edits model, as stickerart uses it (with
// -local, the local model's ID).
var editModel = "gpt-image-2.5-sunburst"

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	dotenv.LoadFirst(".env", filepath.Join("..", ".env"))
	var err error
	switch os.Args[1] {
	case "draw":
		err = runDraw(os.Args[2:])
	case "parts":
		err = runParts(os.Args[2:])
	case "install":
		err = runInstall(os.Args[2:])
	case "preview":
		err = runPreview(os.Args[2:])
	case "check":
		err = runCheck(os.Args[2:])
	case "film":
		err = runFilm(os.Args[2:])
	case "faceroll":
		err = runFaceroll(os.Args[2:])
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "✗ %v\n", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: stickerrig draw|parts|install|preview|check|film|faceroll -pack <pack-dir> [flags]  (see -h on each)")
	os.Exit(2)
}

type ctxt struct {
	pack    *manifest.Manifest
	packDir string
	artDir  string
	spec    []rigSpec
	art     struct {
		StickerSize int     `json:"stickerSize"`
		Border      float64 `json:"border"`
	}
	only map[string]bool
}

func load(packDir, artDir, only string) (*ctxt, error) {
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
	c := &ctxt{pack: m, packDir: packDir, artDir: artDir, only: map[string]bool{}}
	if err := readJSON(filepath.Join(artDir, "art.json"), &c.art); err != nil {
		return nil, fmt.Errorf("art.json: %w", err)
	}
	if c.art.StickerSize == 0 {
		c.art.StickerSize = 1024
	}
	if c.art.Border == 0 {
		c.art.Border = 0.025
	}
	if c.spec, err = loadRigs(filepath.Join(artDir, "rigs")); err != nil {
		return nil, err
	}
	for _, id := range strings.Split(only, ",") {
		if id = strings.TrimSpace(id); id != "" {
			c.only[id] = true
		}
	}
	for i := range c.spec {
		if err := c.spec[i].check(c); err != nil {
			return nil, fmt.Errorf("rigs/%s.json: %w", c.spec[i].Sticker, err)
		}
	}
	for id := range c.only {
		if !slices.ContainsFunc(c.spec, func(r rigSpec) bool { return r.Sticker == id }) {
			return nil, fmt.Errorf("-only %s: there is no rigs/%s.json", id, id)
		}
	}
	return c, nil
}

// rigs are the ones -only asks for (all without it).
func (c *ctxt) rigs() []*rigSpec {
	var out []*rigSpec
	for i := range c.spec {
		if len(c.only) == 0 || c.only[c.spec[i].Sticker] {
			out = append(out, &c.spec[i])
		}
	}
	return out
}

func (c *ctxt) sticker(id string) *manifest.Sticker {
	for i := range c.pack.Stickers {
		if c.pack.Stickers[i].ID == id {
			return &c.pack.Stickers[i]
		}
	}
	return nil
}

func (c *ctxt) out(parts ...string) string {
	p := filepath.Join(append([]string{c.artDir, "out", "rigs"}, parts...)...)
	os.MkdirAll(filepath.Dir(p), 0o755)
	return p
}

// rawPath is the sticker's raw art (no border), without its prop when
// stickerart removed one — what the puppet is drawn from.
func (c *ctxt) rawPath(stickerID string) string {
	noprop := filepath.Join(c.artDir, "out", "stickers", stickerID+".noprop.png")
	if exists(noprop) {
		return noprop
	}
	return filepath.Join(c.artDir, "out", "stickers", stickerID+".raw.png")
}

// sheetPath is where a drawn sheet is kept.
func (c *ctxt) sheetPath(stickerID, sheet string) string {
	return c.out(stickerID + "." + sheet + ".png")
}

func readJSON(path string, v any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, v)
}

// readJSONStrict reads a file the tool's author writes: an unknown key is
// a typo, not something to ignore.
func readJSONStrict(path string, v any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}

func writeJSON(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(data, '\n'), 0o644)
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

// ---------- draw ----------

func runDraw(args []string) error {
	fs := flag.NewFlagSet("draw", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	artDir := fs.String("art", "", "art directory (default author/art/<packID>)")
	only := fs.String("only", "", "comma-separated sticker ids")
	sheetOnly := fs.String("sheet", "", "draw only this sheet (e.g. face)")
	quality := fs.String("quality", "high", "low | medium | high")
	force := fs.Bool("force", false, "redraw even when up to date")
	dry := fs.Bool("dry-run", false, "list what would be drawn")
	local := fs.Bool("local", false, "draw with the local model instead of the OpenAI API (author/localimage)")
	localConfig := fs.String("local-config", localimage.DefaultConfig, "the local model's config (with -local)")
	fs.Parse(args)
	c, err := load(*packDir, *artDir, *only)
	if err != nil {
		return err
	}
	var oa *openai.Client
	if *local {
		lc, err := localimage.Load(*localConfig)
		if err != nil {
			return err
		}
		editModel = lc.ModelID(*quality)
		if !*dry {
			if oa, err = lc.Client(context.Background(), func(s string) { fmt.Println(s) }); err != nil {
				return err
			}
		}
	} else {
		key := os.Getenv("OPENAI_API_KEY")
		if key == "" && !*dry {
			return errors.New("OPENAI_API_KEY is not set (put it in tools/.env)")
		}
		oa = openai.New(key)
	}
	fps := map[string]string{}
	readJSON(c.out("render.json"), &fps)
	var spent openai.Usage
	ctx := context.Background()
	for _, r := range c.rigs() {
		raw := c.rawPath(r.Sticker)
		rawData, err := os.ReadFile(raw)
		if err != nil {
			return fmt.Errorf("%s: the puppet is drawn from stickerart's raw art: %w", r.Sticker, err)
		}
		for _, sh := range r.Sheets {
			if *sheetOnly != "" && sh.ID != *sheetOnly {
				continue
			}
			refs := [][]byte{rawData}
			refFPs := []string{hashFile(raw)}
			for _, id := range sh.References {
				p := c.sheetPath(r.Sticker, id)
				data, err := os.ReadFile(p)
				if err != nil {
					return fmt.Errorf("%s.%s needs the %s sheet drawn first: %w", r.Sticker, sh.ID, id, err)
				}
				refs = append(refs, data)
				refFPs = append(refFPs, hashFile(p))
			}
			fp := hashOf("sheet", sh.Prompt, sh.Size, *quality, editModel, strings.Join(refFPs, ","))
			path := c.sheetPath(r.Sticker, sh.ID)
			if !*force && exists(path) && fps[path] == fp {
				fmt.Printf("  %s up to date\n", filepath.Base(path))
				continue
			}
			if *dry {
				fmt.Printf("would draw %s\n", filepath.Base(path))
				continue
			}
			fmt.Printf("▶ %s\n", filepath.Base(path))
			started := time.Now()
			img, err := oa.Edit(ctx, openai.ImageRequest{
				Model: editModel, Prompt: sh.Prompt, Size: sh.Size, Quality: *quality,
				Background: "transparent", References: refs,
			})
			if err != nil {
				return fmt.Errorf("%s.%s: %w", r.Sticker, sh.ID, err)
			}
			if err := os.WriteFile(path, img.PNG, 0o644); err != nil {
				return err
			}
			// Read it again before writing: another run may have drawn
			// other stickers meanwhile.
			latest := map[string]string{}
			readJSON(c.out("render.json"), &latest)
			latest[path] = fp
			writeJSON(c.out("render.json"), latest)
			fps[path] = fp
			spent.Add(img.Usage)
			fmt.Printf("✓ %s ($%.3f, %.0fs)\n", filepath.Base(path), img.Usage.Cost(openai.DefaultPrices), time.Since(started).Seconds())
		}
	}
	fmt.Printf("This run ≈ $%.2f (list prices). Next: stickerrig parts -pack %s\n", spent.Cost(openai.DefaultPrices), *packDir)
	return nil
}

// ---------- parts ----------

// runParts lists the pieces found on each drawn sheet — where each is and
// how big — and writes an overview with every piece boxed and numbered, to
// say in rig.json which piece is which part (a point inside it).
func runParts(args []string) error {
	fs := flag.NewFlagSet("parts", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	artDir := fs.String("art", "", "art directory (default author/art/<packID>)")
	only := fs.String("only", "", "comma-separated sticker ids")
	fs.Parse(args)
	c, err := load(*packDir, *artDir, *only)
	if err != nil {
		return err
	}
	for _, r := range c.rigs() {
		for _, sh := range r.Sheets {
			path := c.sheetPath(r.Sticker, sh.ID)
			data, err := os.ReadFile(path)
			if err != nil {
				fmt.Printf("%s.%s: not drawn yet\n", r.Sticker, sh.ID)
				continue
			}
			img, err := stickerimg.Decode(data)
			if err != nil {
				return err
			}
			pieces := findPieces(img)
			fmt.Printf("%s.%s: %d pieces\n", r.Sticker, sh.ID, len(pieces))
			for i, p := range pieces {
				fmt.Printf("  %2d  at [%d, %d]  box %v  %d px\n", i+1, p.inside.X, p.inside.Y, p.box, p.area)
			}
			overview := c.out(r.Sticker + "." + sh.ID + ".pieces.png")
			png, err := stickerimg.Encode(piecesOverview(img, pieces))
			if err != nil {
				return err
			}
			if err := os.WriteFile(overview, png, 0o644); err != nil {
				return err
			}
			fmt.Printf("  overview: %s\n", overview)
		}
	}
	return nil
}
