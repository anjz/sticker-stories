package main

import (
	"errors"
	"flag"
	"fmt"
	"image"
	"image/draw"
	"math"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"syscall"

	"stickerstories/tools/internal/manifest"
	"stickerstories/tools/internal/stickerimg"
)

// runInstall cuts every rig's parts out of its sheets into the pack's
// atlas (anims/<sticker>.rig.webp, each part with its border silhouette),
// writes the rig (anims/<sticker>.rig.json) and every animation's sidecar
// (anims/<sticker>.<id>.json, played by the puppet alone: a sprite sheet
// it replaces is deleted), and sets the sticker's animations in the
// manifest to the rig's, in its order.
func runInstall(args []string) error {
	fs := flag.NewFlagSet("install", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	artDir := fs.String("art", "", "art directory (default author/art/<packID>)")
	only := fs.String("only", "", "comma-separated sticker ids")
	bump := fs.Bool("bump", false, "increment the pack's content version")
	drop := fs.Bool("drop", false, "let the rig leave out animations the sticker has now (stories may cue them)")
	fs.Parse(args)
	// Several installs at once (one per sticker being rigged) would each
	// rewrite the manifest from what they read: one at a time.
	unlock, err := lockPack(*packDir)
	if err != nil {
		return err
	}
	defer unlock()
	c, err := load(*packDir, *artDir, *only)
	if err != nil {
		return err
	}
	templates, err := loadTemplates()
	if err != nil {
		return err
	}
	for _, r := range c.rigs() {
		if err := c.install(r, templates, *drop); err != nil {
			return fmt.Errorf("%s: %w", r.Sticker, err)
		}
	}
	if *bump {
		c.pack.Version++
	}
	if err := writeJSON(filepath.Join(c.packDir, "manifest.json"), c.pack); err != nil {
		return err
	}
	if errs := c.pack.Validate(c.packDir); len(errs) > 0 {
		for _, e := range errs {
			fmt.Printf("  ✗ %v\n", e)
		}
		return errors.New("the pack does not validate (files were written)")
	}
	fmt.Printf("✓ installed; the pack validates (version %d)\n", c.pack.Version)
	return nil
}

func (c *ctxt) install(r *rigSpec, templates map[string]animSpec, drop bool) error {
	sheets := map[string]*image.RGBA{}
	for _, sh := range r.Sheets {
		data, err := os.ReadFile(c.sheetPath(r.Sticker, sh.ID))
		if err != nil {
			return fmt.Errorf("sheet %s is not drawn (stickerrig draw): %w", sh.ID, err)
		}
		if sheets[sh.ID], err = stickerimg.Decode(data); err != nil {
			return err
		}
	}
	rig, art, err := c.buildRig(r, sheets)
	if err != nil {
		return err
	}
	st := c.sticker(r.Sticker)
	box, err := c.stickerBox(st)
	if err != nil {
		return err
	}
	// Resolve every animation before writing anything.
	var anims []animSpec
	for _, a := range r.Animations {
		resolved, notes, err := r.resolve(a, templates)
		if err != nil {
			return err
		}
		if len(notes) > 0 {
			fmt.Printf("  %s (%s): the rig has no %s\n", a.ID, a.Template, strings.Join(notes, ", "))
		}
		anims = append(anims, resolved)
	}
	var paths []string
	for _, a := range anims {
		paths = append(paths, "anims/"+r.Sticker+"."+a.ID+".json")
	}
	if !drop {
		for _, rel := range st.Animations {
			if !slices.Contains(paths, rel) {
				return fmt.Errorf("the sticker has %s and the rig has no animation for it (stories may cue it; -drop to let it go)", rel)
			}
		}
	}
	base := filepath.Join(c.packDir, "anims", r.Sticker+".rig")
	webp, err := stickerimg.EncodeWebP(art)
	if err != nil {
		return err
	}
	if err := os.WriteFile(base+".webp", webp, 0o644); err != nil {
		return err
	}
	if err := writeJSON(base+".json", rig); err != nil {
		return err
	}
	if errs := rig.Validate(c.packDir, r.Sticker); len(errs) > 0 {
		return fmt.Errorf("rig: %w", errors.Join(errs...))
	}
	fmt.Printf("✓ %s: %d parts in a %dx%d atlas, %d bones, %d slots\n", r.Sticker, len(rig.Parts), art.Bounds().Dx(), art.Bounds().Dy(), len(rig.Bones), len(rig.Slots))
	for i, a := range anims {
		side := manifest.StickerAnimation{
			ID: a.ID, Sticker: r.Sticker, Kind: a.Kind, Description: a.Description, StickerBox: box,
			Pause: a.Pause, Perched: a.Perched, Idle: a.Idle, Place: a.Place, Loop: a.Loop, Facing: a.Facing, Stride: a.Stride,
			Hops: a.Hops, Flies: a.Flies, Hovers: a.Hovers, On: a.On, Stays: a.Stays, Particles: a.Particles,
			Puppet: &manifest.AnimationPuppet{Rig: "anims/" + r.Sticker + ".rig.json", Keys: a.Keys, Wings: a.Wings},
		}
		path := filepath.Join(c.packDir, filepath.FromSlash(paths[i]))
		if old, err := manifest.LoadStickerAnimation(path); err == nil && old.Sheet != "" {
			// The puppet plays it now: the sheet goes.
			os.Remove(filepath.Join(c.packDir, filepath.FromSlash(old.Sheet)))
		}
		if err := writeJSON(path, side); err != nil {
			return err
		}
		pause := ""
		if a.Pause != nil {
			pause = fmt.Sprintf(", pause at key %d", a.Pause.Frame)
		}
		fmt.Printf("  %-12s %-6s %2d keys, %.2f s%s\n", a.ID, side.EffectiveKind(), len(a.Keys), keysDuration(a.Keys), pause)
	}
	for _, rel := range st.Animations {
		if !slices.Contains(paths, rel) {
			fmt.Printf("  dropped %s (its files stay; delete them)\n", rel)
		}
	}
	st.Animations = paths
	for name := range st.Expressions {
		if _, ok := rig.Faces[name]; !ok {
			fmt.Printf("  note: the sticker has a %s face and the rig none (the puppet keeps its own face)\n", name)
		}
	}
	return nil
}

// stickerBox is the sticker's drawing within its image (its opaque
// pixels, border included), as fractions: where the art reaches, for the
// app (how far its front is from its centre).
func (c *ctxt) stickerBox(st *manifest.Sticker) (manifest.UnitBox, error) {
	data, err := os.ReadFile(filepath.Join(c.packDir, filepath.FromSlash(st.Image)))
	if err != nil {
		return manifest.UnitBox{}, err
	}
	img, err := stickerimg.Decode(data)
	if err != nil {
		return manifest.UnitBox{}, err
	}
	b := img.Bounds()
	minX, minY, maxX, maxY := b.Max.X, b.Max.Y, b.Min.X-1, b.Min.Y-1
	for y := b.Min.Y; y < b.Max.Y; y++ {
		for x := b.Min.X; x < b.Max.X; x++ {
			if img.Pix[img.PixOffset(x, y)+3] > 8 {
				minX, minY, maxX, maxY = min(minX, x), min(minY, y), max(maxX, x), max(maxY, y)
			}
		}
	}
	if maxX < minX {
		return manifest.UnitBox{}, fmt.Errorf("%s is empty", st.Image)
	}
	w, h := float64(b.Dx()), float64(b.Dy())
	r5 := func(v float64) float64 { return math.Round(v*1e5) / 1e5 }
	return manifest.UnitBox{X: r5(float64(minX) / w), Y: r5(float64(minY) / h), Width: r5(float64(maxX-minX+1) / w), Height: r5(float64(maxY-minY+1) / h)}, nil
}

// lockPack holds an exclusive lock on the pack directory's install lock
// file until the returned function is called.
func lockPack(packDir string) (func(), error) {
	abs, err := filepath.Abs(packDir)
	if err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(os.TempDir(), "stickerrig-"+hashOf(abs)+".lock"), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		return nil, err
	}
	return func() { syscall.Flock(int(f.Fd()), syscall.LOCK_UN); f.Close() }, nil
}

func keysDuration(keys []manifest.PuppetKey) float64 {
	t := 0.0
	for _, k := range keys {
		t += k.Hold
	}
	return t
}

// buildRig turns the spec into the pack's rig: each attachment's box from
// its piece's size, scale and centre, each part cut out at the largest
// size an attachment shows it, with its border, packed into one atlas.
func (c *ctxt) buildRig(r *rigSpec, sheets map[string]*image.RGBA) (*manifest.PuppetRig, *image.RGBA, error) {
	pieces := map[string]*image.RGBA{}
	for name, p := range r.Parts {
		img, ok := pieceAt(sheets[p.Sheet], image.Pt(p.At[0], p.At[1]))
		if !ok {
			return nil, nil, fmt.Errorf("part %s: no piece of sheet %s at %v (stickerrig parts lists them)", name, p.Sheet, p.At)
		}
		pieces[name] = img
	}
	rig := &manifest.PuppetRig{
		Sticker: r.Sticker, Atlas: "anims/" + r.Sticker + ".rig.webp", Size: float64(c.art.StickerSize),
		Parts: map[string]manifest.PuppetPart{}, Bones: r.Bones, Faces: r.Faces, Idle: r.Idle,
	}
	// The size each part is cut at: the largest any attachment shows it.
	sizes := map[string][2]int{}
	for _, s := range r.Slots {
		slot := manifest.PuppetSlot{ID: s.ID, Bone: s.Bone, Default: s.Default, Attachments: map[string]manifest.PuppetAttachment{}}
		for name, a := range s.Attachments {
			img, ok := pieces[a.Part]
			if !ok {
				return nil, nil, fmt.Errorf("slot %s attachment %s: part %q is not in parts", s.ID, name, a.Part)
			}
			scale := a.Scale
			if scale <= 0 {
				scale = 1
			}
			w, h := float64(img.Bounds().Dx())*scale, float64(img.Bounds().Dy())*scale
			if a.ScaleY > 0 {
				h *= a.ScaleY
			}
			slot.Attachments[name] = manifest.PuppetAttachment{
				Part: a.Part, X: round2(a.X - w/2), Y: round2(a.Y - h/2), W: round2(w), H: round2(h),
				Rotate: a.Rotate, Flip: a.Flip, Shade: a.Shade,
			}
			cur := sizes[a.Part]
			sizes[a.Part] = [2]int{max(cur[0], int(math.Ceil(w))), max(cur[1], int(math.Ceil(h)))}
		}
		rig.Slots = append(rig.Slots, slot)
	}
	radius := int(math.Round(c.art.Border * float64(c.art.StickerSize)))
	type cut struct {
		name         string
		art, outline *image.RGBA
	}
	var cuts []cut
	for name, size := range sizes {
		art := stickerimg.Resize(pieces[name], size[0], size[1])
		cuts = append(cuts, cut{name, art, silhouette(art, radius)})
	}
	// Tallest first packs shelves tightly.
	sort.Slice(cuts, func(i, j int) bool {
		if cuts[i].outline.Bounds().Dy() != cuts[j].outline.Bounds().Dy() {
			return cuts[i].outline.Bounds().Dy() > cuts[j].outline.Bounds().Dy()
		}
		return cuts[i].name < cuts[j].name
	})
	const gap = 2
	width := 2048
	x, y, shelf := 0, 0, 0
	place := func(img *image.RGBA) image.Rectangle {
		w, h := img.Bounds().Dx(), img.Bounds().Dy()
		if x+w > width {
			x, y, shelf = 0, y+shelf+gap, 0
		}
		r := image.Rect(x, y, x+w, y+h)
		x += w + gap
		shelf = max(shelf, h)
		return r
	}
	rects := map[string][2]image.Rectangle{}
	for _, ct := range cuts {
		rects[ct.name] = [2]image.Rectangle{place(ct.art), place(ct.outline)}
	}
	atlas := image.NewRGBA(image.Rect(0, 0, width, y+shelf))
	box := func(r image.Rectangle) [4]int { return [4]int{r.Min.X, r.Min.Y, r.Dx(), r.Dy()} }
	for _, ct := range cuts {
		rr := rects[ct.name]
		draw.Draw(atlas, rr[0], ct.art, image.Point{}, draw.Src)
		draw.Draw(atlas, rr[1], ct.outline, image.Point{}, draw.Src)
		rig.Parts[ct.name] = manifest.PuppetPart{Rect: box(rr[0]), Border: box(rr[1]), Pad: radius + 1}
	}
	return rig, atlas, nil
}

func round2(v float64) float64 { return math.Round(v*100) / 100 }

// silhouette is the part's shape grown by the sticker's border, in the
// border's white, radius+1 px larger on every side: under the art of
// every part, these make the die-cut border of the whole posed puppet
// (the union of grown parts is the grown union).
func silhouette(art *image.RGBA, radius int) *image.RGBA {
	pad := radius + 1
	b := art.Bounds()
	w, h := b.Dx()+2*pad, b.Dy()+2*pad
	alpha := make([]float64, w*h)
	var disc [][3]int
	for dy := -pad; dy <= pad; dy++ {
		for dx := -pad; dx <= pad; dx++ {
			// Coverage of the disc's edge pixel, for a smooth rim.
			d := math.Hypot(float64(dx), float64(dy))
			if cov := math.Min(1, float64(radius)+0.5-d); cov > 0 {
				disc = append(disc, [3]int{dx, dy, int(cov * 255)})
			}
		}
	}
	for y := 0; y < b.Dy(); y++ {
		for x := 0; x < b.Dx(); x++ {
			a := float64(art.Pix[art.PixOffset(x+b.Min.X, y+b.Min.Y)+3]) / 255
			if a < 0.02 {
				continue
			}
			for _, d := range disc {
				i := (y+pad+d[1])*w + x + pad + d[0]
				if v := a * float64(d[2]) / 255; v > alpha[i] {
					alpha[i] = v
				}
			}
		}
	}
	out := image.NewRGBA(image.Rect(0, 0, w, h))
	white := [3]float64{250, 250, 247}
	for i, a := range alpha {
		if a == 0 {
			continue
		}
		o := i * 4
		for k := 0; k < 3; k++ {
			out.Pix[o+k] = uint8(white[k]*a + 0.5)
		}
		out.Pix[o+3] = uint8(a*255 + 0.5)
	}
	return out
}
