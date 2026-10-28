package main

import (
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"maps"
	"math"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"stickerstories/tools/internal/stickerimg"
)

// faceroll: a face's pieces are drawn upright on their sheet. The rest
// face's (the eyes, the mouth as in the sticker) are drawn from the sticker
// and lean with its head, but the shapes drawn on their own — a happy or
// closed eye's arc, a laughing mouth — come out level, and on a head drawn
// tilted (looking up, a three-quarter turn) they look pasted on. The tilt
// is the line through the eyes at rest; those shapes turn by it.

type rollFit struct {
	slot, att string
	now, best float64 // degrees, the attachment's rotate
	from, to  float64 // how much of its lines lie on its expression sticker's, before and after
	ref       string  // that expression, or ""
}

func runFaceroll(args []string) error {
	fs := flag.NewFlagSet("faceroll", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	artDir := fs.String("art", "", "art directory (default author/art/<packID>)")
	only := fs.String("only", "", "comma-separated sticker ids")
	least := fs.Float64("least", 6, "degrees of tilt worth turning for")
	sheet := fs.String("sheet", "", "write a PNG of every face turned: before, after")
	fs.Parse(args)
	var rows []*image.RGBA
	c, err := load(*packDir, *artDir, *only)
	if err != nil {
		return err
	}
	for _, r := range c.rigs() {
		tilt, fits, err := c.faceRoll(r.Sticker, *least)
		if err != nil {
			fmt.Printf("%s: %v\n", r.Sticker, err)
			continue
		}
		fmt.Printf("%s: face tilted %.0f°, %d pieces to turn\n", r.Sticker, tilt, len(fits))
		for _, f := range fits {
			how := ""
			if f.ref != "" {
				how = fmt.Sprintf("  (on its %s sticker: %.2f → %.2f of its lines)", f.ref, f.from, f.to)
			}
			fmt.Printf("  %-8s %-8s rotate %5.1f → %5.1f%s\n", f.slot, f.att, f.now, f.best, how)
		}
		if *sheet != "" && len(fits) > 0 {
			p, _, err := c.loadPuppet(r.Sticker)
			if err != nil {
				return err
			}
			rows = append(rows, p.rollSheet(r.Sticker, fits))
		}
	}
	if *sheet != "" {
		return writeSheet(*sheet, rows)
	}
	return nil
}

// rollSheet draws the face at rest, then each turned expression (the
// attachments of one name together) before and after, side by side.
func (p *puppet) rollSheet(sticker string, fits []rollFit) *image.RGBA {
	rest := p.shown("", nil)
	// The face's box: its pieces at rest, grown by half.
	var box image.Rectangle
	for _, l := range func() []*layer { ls, _ := p.pose(nil, rest); return ls }() {
		if isFaceSlot(l.id) {
			box = box.Union(l.r)
		}
	}
	box = box.Inset(-max(box.Dx(), box.Dy()) / 2)
	const cell = 220
	s := float64(cell) / float64(max(box.Dx(), box.Dy()))
	var names []string
	for _, f := range fits {
		if !slices.Contains(names, f.att) {
			names = append(names, f.att)
		}
	}
	out := image.NewRGBA(image.Rect(0, 0, cell*(1+2*len(names))+8*len(names), cell+6))
	draw.Draw(out, out.Bounds(), &image.Uniform{color.RGBA{236, 236, 232, 255}}, image.Point{}, draw.Src)
	paint := func(x int, shown map[string]string) {
		cellImg := image.NewRGBA(image.Rect(0, 0, cell, cell))
		draw.Draw(cellImg, cellImg.Bounds(), &image.Uniform{color.RGBA{250, 248, 244, 255}}, image.Point{}, draw.Src)
		p.paint(cellImg, mat{a: s, d: s, e: -float64(box.Min.X) * s, f: -float64(box.Min.Y) * s}, nil, shown)
		draw.Draw(out, image.Rect(x, 3, x+cell, 3+cell), cellImg, image.Point{}, draw.Src)
	}
	paint(0, rest)
	for i, n := range names {
		x := cell*(1+2*i) + 8*(i+1)
		shown := maps.Clone(rest)
		for _, f := range fits {
			if f.att == n {
				shown[f.slot] = n
			}
		}
		paint(x, shown)
		saved := map[string]float64{}
		for _, f := range fits {
			if f.att == n {
				si := p.slot[f.slot]
				a := p.rig.Slots[si].Attachments[n]
				saved[f.slot] = a.Rotate
				a.Rotate = f.best
				p.rig.Slots[si].Attachments[n] = a
			}
		}
		paint(x+cell, shown)
		for id, r := range saved {
			si := p.slot[id]
			a := p.rig.Slots[si].Attachments[n]
			a.Rotate = r
			p.rig.Slots[si].Attachments[n] = a
		}
	}
	return out
}

func writeSheet(path string, rows []*image.RGBA) error {
	w, h := 0, 0
	for _, r := range rows {
		w, h = max(w, r.Bounds().Dx()), h+r.Bounds().Dy()+6
	}
	out := image.NewRGBA(image.Rect(0, 0, max(w, 1), max(h, 1)))
	draw.Draw(out, out.Bounds(), &image.Uniform{color.White}, image.Point{}, draw.Src)
	y := 0
	for _, r := range rows {
		draw.Draw(out, r.Bounds().Add(image.Pt(0, y)), r, image.Point{}, draw.Src)
		y += r.Bounds().Dy() + 6
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return png.Encode(f, out)
}

// faceTilt is the line through the rest face's eyes (eyeL to eyeR),
// degrees clockwise; false without a pair of eyes.
func (p *puppet) faceTilt(world map[string]mat) (float64, bool) {
	var c [2][2]float64
	for i, id := range []string{"eyeL", "eyeR"} {
		si, ok := p.slot[id]
		if !ok {
			return 0, false
		}
		s := p.rig.Slots[si]
		a, ok := s.Attachments[s.Default]
		if !ok {
			return 0, false
		}
		b := p.bone[s.Bone]
		c[i][0], c[i][1] = world[s.Bone].apply(a.X+a.W/2-b.X, a.Y+a.H/2-b.Y)
	}
	return math.Atan2(c[1][1]-c[0][1], c[1][0]-c[0][0]) * 180 / math.Pi, true
}

// headTilts says whether the eye line is a head's tilt: the eyes hang on
// a head bone (not on stalks, not a face drawn on a round body, whose eyes
// sit at different heights from the front) and there is no beak (a bird's
// far eye, in profile, is not level with its near one).
func (p *puppet) headTilts() bool {
	if _, ok := p.bone["head"]; !ok {
		return false
	}
	for _, s := range p.rig.Slots {
		if strings.HasPrefix(strings.ToLower(s.ID), "beak") {
			return false
		}
	}
	for _, id := range []string{"eyeL", "eyeR"} {
		b := p.rig.Slots[p.slot[id]].Bone
		for b != "" && b != "head" {
			if b != id && b != "face" && !strings.HasPrefix(b, "eye") {
				return false
			}
			b = p.bone[b].Parent
		}
		if b != "head" {
			return false
		}
	}
	return true
}

// turnsWithFace says whether an attachment is a shape drawn level on its
// own that should lean with the face: a shut eye (happy, closed, crying,
// asleep) or a mouth other than the rest one. Open eyes and the rest
// pieces are drawn from the sticker, leaning already; brows are set by
// hand; a beak is part of the head, hung on its own pivot.
func turnsWithFace(slot, att, def string) bool {
	id := strings.ToLower(slot)
	switch {
	case strings.HasPrefix(id, "eye"):
		return gazeless(att)
	case strings.HasPrefix(id, "mouth"):
		return att != def
	}
	return false
}

// faceRoll proposes the turns for the installed puppet's face.
func (c *ctxt) faceRoll(sticker string, least float64) (float64, []rollFit, error) {
	p, _, err := c.loadPuppet(sticker)
	if err != nil {
		return 0, nil, err
	}
	world := p.world(nil)
	tilt, ok := p.faceTilt(world)
	if !ok || math.Abs(tilt) < least || !p.headTilts() {
		return tilt, nil, nil
	}
	st := c.sticker(sticker)
	size := int(math.Round(p.rig.Size))
	refs := map[string]*image.RGBA{}
	for e, rel := range st.Expressions {
		data, err := os.ReadFile(filepath.Join(c.packDir, filepath.FromSlash(rel)))
		if err != nil {
			return 0, nil, err
		}
		img, err := stickerimg.Decode(data)
		if err != nil {
			return 0, nil, err
		}
		if img.Bounds().Dx() != size || img.Bounds().Dy() != size {
			img = stickerimg.Resize(img, size, size)
		}
		refs[e] = img
	}
	var fits []rollFit
	for i, s := range p.rig.Slots {
		if !isFaceSlot(s.ID) {
			continue
		}
		for _, att := range sortedKeys(s.Attachments) {
			a := s.Attachments[att]
			if att == "none" || a.Rotate != 0 || !turnsWithFace(s.ID, att, s.Default) {
				continue
			}
			f := rollFit{slot: s.ID, att: att, now: a.Rotate, best: math.Round(a.Rotate + tilt)}
			for _, e := range sortedKeys(p.rig.Faces) {
				if ref := refs[e]; ref != nil && p.rig.Faces[e][s.ID] == att {
					f.ref = e
					f.from = p.lineFit(i, att, world, 0, ref)
					f.to = p.lineFit(i, att, world, f.best-a.Rotate, ref)
					break
				}
			}
			fits = append(fits, f)
		}
	}
	return tilt, fits, nil
}

// lineFit is how much of an attachment's dark lines, turned d degrees more
// about its centre, lie on dark lines of ref (within 2 px), at the best
// shift of up to 4 px either way.
func (p *puppet) lineFit(slot int, att string, world map[string]mat, d float64, ref *image.RGBA) float64 {
	s := &p.rig.Slots[slot]
	a := s.Attachments[att]
	turned := a
	turned.Rotate += d
	s.Attachments[att] = turned
	l := p.draw(slot, att, world, a.Flip)
	s.Attachments[att] = a
	if l == nil {
		return 0
	}
	var pts []image.Point
	for y := l.r.Min.Y; y < l.r.Max.Y; y++ {
		for x := l.r.Min.X; x < l.r.Max.X; x++ {
			if l.alpha(x, y) >= opaqueAlpha && l.luma(x, y) < darkLuma {
				pts = append(pts, image.Pt(x, y))
			}
		}
	}
	if len(pts) < 10 {
		return 0
	}
	// The reference's dark pixels near the piece, grown by 2 px.
	area := l.r.Inset(-8).Intersect(ref.Bounds())
	dark := make([]bool, area.Dx()*area.Dy())
	at := func(x, y int) int { return (y-area.Min.Y)*area.Dx() + x - area.Min.X }
	for y := area.Min.Y; y < area.Max.Y; y++ {
		for x := area.Min.X; x < area.Max.X; x++ {
			o := ref.PixOffset(x, y)
			al := ref.Pix[o+3]
			if al < solidAlpha {
				continue
			}
			c := ref.Pix[o : o+3]
			if (0.299*float64(c[0])+0.587*float64(c[1])+0.114*float64(c[2]))*255/float64(al) >= darkLuma {
				continue
			}
			for dy := -2; dy <= 2; dy++ {
				for dx := -2; dx <= 2; dx++ {
					if q := image.Pt(x+dx, y+dy); q.In(area) {
						dark[at(q.X, q.Y)] = true
					}
				}
			}
		}
	}
	best := 0
	for sy := -4; sy <= 4; sy += 2 {
		for sx := -4; sx <= 4; sx += 2 {
			n := 0
			for _, q := range pts {
				if r := q.Add(image.Pt(sx, sy)); r.In(area) && dark[at(r.X, r.Y)] {
					n++
				}
			}
			best = max(best, n)
		}
	}
	return float64(best) / float64(len(pts))
}
