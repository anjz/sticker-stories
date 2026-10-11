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

	"stickerstories/tools/internal/manifest"
	"stickerstories/tools/internal/stickerimg"
)

// runInstall cuts every rig's parts out of its sheets into the pack's
// atlas (anims/<sticker>.rig.webp, each part with its border silhouette),
// writes the rig (anims/<sticker>.rig.json) and puts each animation's
// keys into the sidecar of the sticker's animation with that id.
func runInstall(args []string) error {
	fs := flag.NewFlagSet("install", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	artDir := fs.String("art", "", "art directory (default author/art/<packID>)")
	only := fs.String("only", "", "comma-separated sticker ids")
	bump := fs.Bool("bump", false, "increment the pack's content version")
	fs.Parse(args)
	c, err := load(*packDir, *artDir, *only)
	if err != nil {
		return err
	}
	for _, r := range c.rigs() {
		if err := c.install(r); err != nil {
			return fmt.Errorf("%s: %w", r.Sticker, err)
		}
	}
	if *bump {
		c.pack.Version++
	}
	if errs := c.pack.Validate(c.packDir); len(errs) > 0 {
		for _, e := range errs {
			fmt.Printf("  ✗ %v\n", e)
		}
		return errors.New("the pack does not validate (files were written)")
	}
	if *bump {
		if err := writeJSON(filepath.Join(c.packDir, "manifest.json"), c.pack); err != nil {
			return err
		}
	}
	fmt.Printf("✓ installed; the pack validates (version %d)\n", c.pack.Version)
	return nil
}

func (c *ctxt) install(r *rigSpec) error {
	sheets := map[string]*image.RGBA{}
	for _, sh := range r.Sheets {
		data, err := os.ReadFile(c.sheetPath(r.Sticker, sh.ID, 0))
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
	st := c.sticker(r.Sticker)
	for _, a := range r.Animations {
		rel := "anims/" + r.Sticker + "." + a.ID + ".json"
		if !slices.Contains(st.Animations, rel) {
			return fmt.Errorf("animation %s: the sticker has no %s (the puppet plays the sticker's own animations)", a.ID, rel)
		}
		path := filepath.Join(c.packDir, filepath.FromSlash(rel))
		side, err := manifest.LoadStickerAnimation(path)
		if err != nil {
			return err
		}
		p := a.AnimationPuppet
		p.Rig = "anims/" + r.Sticker + ".rig.json"
		side.Puppet = &p
		if err := writeJSON(path, side); err != nil {
			return err
		}
		fmt.Printf("  %s: %d keys, %.2f s\n", a.ID, len(p.Keys), keysDuration(p.Keys))
	}
	return nil
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
