// Command scenespace fits a pack's scene with depth (space.json beside its
// art.json) and shows it in the browser: the painted art on the ground,
// the backdrop and the foreground's layers, to turn around, look at from
// the camera, and watch stickers walk in.
package main

import (
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"slices"

	"github.com/gen2brain/webp"

	"stickerstories/tools/internal/manifest"
)

//go:embed web
var web embed.FS

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "check":
		err = runCheck(os.Args[2:])
	case "serve":
		err = runServe(os.Args[2:])
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "scenespace:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `usage:
  scenespace check -pack ../packs/forest        validate space.json, print depths
  scenespace serve -pack ../packs/forest        the 3D viewer on http://127.0.0.1:8737`)
	os.Exit(2)
}

type pack struct {
	m        *manifest.Manifest
	dir      string
	artDir   string
	aspect   float64 // base art width / height
	wide     float64 // wide art width / base art width (0: no wide art)
	space    *Space
	problems []error
}

func load(packDir, artDir string) (*pack, error) {
	if packDir == "" {
		return nil, fmt.Errorf("-pack is required")
	}
	m, err := manifest.Load(packDir)
	if err != nil {
		return nil, err
	}
	if artDir == "" {
		artDir = filepath.Join("author", "art", m.ID)
	}
	p := &pack{m: m, dir: packDir, artDir: artDir}
	w, h, err := imageSize(filepath.Join(packDir, m.Background))
	if err != nil {
		return nil, err
	}
	p.aspect = w / h
	if m.BackgroundWide != "" {
		ww, _, err := imageSize(filepath.Join(packDir, m.BackgroundWide))
		if err != nil {
			return nil, err
		}
		p.wide = ww / w
	}
	if p.space, err = LoadSpace(filepath.Join(artDir, "space.json")); err != nil {
		return nil, err
	}
	stickers, features := map[string]bool{}, map[string]bool{}
	for _, s := range m.Stickers {
		stickers[s.ID] = true
	}
	for id := range m.Features {
		features[id] = true
	}
	p.problems = p.space.Validate(stickers, features)
	return p, nil
}

func imageSize(path string) (w, h float64, err error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, 0, err
	}
	defer f.Close()
	c, err := webp.DecodeConfig(f)
	if err != nil {
		return 0, 0, fmt.Errorf("%s: %w", path, err)
	}
	return float64(c.Width), float64(c.Height), nil
}

func runCheck(args []string) error {
	fs := flag.NewFlagSet("check", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	artDir := fs.String("art", "", "art directory (default author/art/<packID>)")
	fs.Parse(args)
	p, err := load(*packDir, *artDir)
	if err != nil {
		return err
	}
	s := p.space
	fmt.Printf("eye height %.3f, ground at depth 1 on art y %.3f, horizon %.3f\n", s.EyeHeight(), s.Ground, s.Horizon)
	fmt.Println("art y → depth (ground):")
	for v := s.Ground; v < s.Horizon-0.02; v += 0.05 {
		fmt.Printf("  %.2f → %.2f\n", v, s.GroundDepth(v))
	}
	for _, l := range s.Layers {
		fmt.Printf("layer %-12s depth %.2f\n", l.ID, l.Depth)
	}
	for id, size := range s.Sizes {
		fmt.Printf("size %-10s %.3f: drawn %.3f at the front (%.2f), %.3f at the back (%.2f)\n",
			id, size, s.DrawnHeight(size, s.Stand.Near), s.Stand.Near, s.DrawnHeight(size, s.Stand.Far), s.Stand.Far)
	}
	if len(p.problems) > 0 {
		for _, e := range p.problems {
			fmt.Fprintln(os.Stderr, " -", e)
		}
		return fmt.Errorf("%d problems", len(p.problems))
	}
	fmt.Println("ok")
	return nil
}

func runServe(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	artDir := fs.String("art", "", "art directory (default author/art/<packID>)")
	addr := fs.String("addr", "127.0.0.1:8737", "address to serve on (local only)")
	fromOut := fs.Bool("out", false, "show the scene planes rendered in <art>/out/art (stickerart, before install) instead of the pack's")
	fs.Parse(args)
	first, err := load(*packDir, *artDir)
	if err != nil {
		return err
	}
	site, _ := subFS(web, "web")
	mux := http.NewServeMux()
	mux.Handle("/", http.FileServerFS(site))
	mux.Handle("/pack/", http.StripPrefix("/pack/", http.FileServer(http.Dir(*packDir))))
	mux.Handle("/out/", http.StripPrefix("/out/", http.FileServer(http.Dir(filepath.Join(first.artDir, "out", "art")))))
	// The space is read again on every request, so an edit to space.json
	// shows on a reload.
	mux.HandleFunc("/api/scene", func(w http.ResponseWriter, r *http.Request) {
		p, err := load(*packDir, *artDir)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		problems := []string{}
		for _, e := range p.problems {
			problems = append(problems, e.Error())
		}
		type sticker struct {
			ID     string `json:"id"`
			Image  string `json:"image"`
			Facing string `json:"facing,omitempty"` // the way its usual move goes
		}
		var stickers []sticker
		for _, s := range p.m.Stickers {
			st := sticker{ID: s.ID, Image: s.Image}
			for _, rel := range s.Animations {
				a, err := manifest.LoadStickerAnimation(filepath.Join(p.dir, filepath.FromSlash(rel)))
				if err == nil && a.EffectiveKind() == "move" && a.Facing != "" {
					st.Facing = a.Facing
					break
				}
			}
			stickers = append(stickers, st)
		}
		// Each plane's image (base and wide) by name: background,
		// foreground and the layers between.
		type plane struct {
			Base string `json:"base"`
			Wide string `json:"wide,omitempty"`
		}
		planes := map[string]plane{}
		names := []string{"background", "foreground"}
		for _, l := range p.space.Layers {
			if !slices.Contains(names, l.Plane()) {
				names = append(names, l.Plane())
			}
		}
		for _, n := range names {
			file := n
			if n != "background" && n != "foreground" {
				file = "layer-" + n
			}
			switch {
			case *fromOut:
				planes[n] = plane{"/out/" + file + ".png", "/out/" + file + "-wide.png"}
			case n == "background":
				planes[n] = plane{"/pack/" + p.m.Background, "/pack/" + p.m.BackgroundWide}
			case n == "foreground":
				planes[n] = plane{"/pack/" + p.m.Foreground, "/pack/" + p.m.ForegroundWide}
			default:
				planes[n] = plane{"/pack/art/" + file + ".webp", "/pack/art/" + file + "-wide.webp"}
			}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"pack": p.m.ID, "aspect": p.aspect, "wide": p.wide, "planes": planes,
			"stickers": stickers, "space": p.space, "problems": problems,
		})
	})
	log.Printf("scenespace: %s on http://%s", *packDir, *addr)
	return http.ListenAndServe(*addr, mux)
}

func subFS(f embed.FS, dir string) (fs.FS, error) { return fs.Sub(f, dir) }
