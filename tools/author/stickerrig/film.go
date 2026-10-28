package main

import (
	"errors"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/color/palette"
	"image/draw"
	"image/gif"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"strings"

	"stickerstories/tools/internal/manifest"
)

// film plays an installed animation as the app does — the keys eased,
// a move's loop going round while it travels at its stride, a hop's arc —
// into a GIF to watch: the motion, which the preview's still keys cannot
// show. With -before, another copy of the pack plays above it, the same
// animation before a change.
func runFilm(args []string) error {
	fs := flag.NewFlagSet("film", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	artDir := fs.String("art", "", "art directory (default author/art/<packID>)")
	only := fs.String("only", "", "comma-separated sticker ids")
	anim := fs.String("anim", "", "comma-separated animation ids (default: its moves)")
	before := fs.String("before", "", "a copy of the pack before the change, filmed above")
	outDir := fs.String("out", "", "where the GIFs go (default <art>/out/rigs)")
	loops := fs.Int("loops", 3, "times a move's loop goes round")
	scale := fs.Float64("scale", 0.45, "the film's pixels per rig pixel")
	fs.Parse(args)
	c, err := load(*packDir, *artDir, *only)
	if err != nil {
		return err
	}
	var b *ctxt
	if *before != "" {
		if b, err = load(*before, *artDir, *only); err != nil {
			return err
		}
	}
	dir := *outDir
	if dir == "" {
		dir = filepath.Join(c.artDir, "out", "rigs")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	for _, r := range c.rigs() {
		p, anims, err := c.loadPuppet(r.Sticker)
		if err != nil {
			fmt.Printf("%s: %v\n", r.Sticker, err)
			continue
		}
		var bp *puppet
		var banims []*manifest.StickerAnimation
		if b != nil {
			if bp, banims, err = b.loadPuppet(r.Sticker); err != nil {
				return fmt.Errorf("%s before: %w", r.Sticker, err)
			}
		}
		for _, a := range anims {
			if *anim == "" && a.EffectiveKind() != manifest.KindMove || *anim != "" && !containsStr(strings.Split(*anim, ","), a.ID) {
				continue
			}
			rows := []filmRow{{p, a}}
			if bp != nil {
				for _, ba := range banims {
					if ba.ID == a.ID {
						rows = append([]filmRow{{bp, ba}}, rows...)
					}
				}
			}
			path := filepath.Join(dir, r.Sticker+"."+a.ID+".gif")
			if err := film(path, rows, *loops, *scale); err != nil {
				return err
			}
			fmt.Printf("✓ %s\n", path)
		}
	}
	return nil
}

type filmRow struct {
	p *puppet
	a *manifest.StickerAnimation
}

// filmPose is the animation at a moment: its pose, and how far it has
// travelled (rig pixels along its way, up for a hop).
type filmPose struct {
	bones map[string]manifest.BonePose
	slots map[string]string
	dx    float64
	dy    float64
}

// timeline plays the keys: up to the loop's end, round the loop, then on
// to the last key and a moment at rest.
func timeline(p *puppet, a *manifest.StickerAnimation, loops int, fps float64) []filmPose {
	keys := a.Puppet.Keys
	type seg struct {
		from, to int
		wrap     bool
	}
	var segs []seg
	from, to := -1, -1
	if a.Loop != nil {
		from, to = a.Loop.From, a.Loop.To
	}
	if from >= 0 {
		for i := 0; i < to; i++ {
			segs = append(segs, seg{i, i + 1, false})
		}
		for l := 0; l < loops; l++ {
			for i := from; i < to; i++ {
				if l > 0 || i >= to {
					segs = append(segs, seg{i, i + 1, false})
				}
			}
			if l < loops-1 {
				segs = append(segs, seg{to, from, true})
			}
		}
		for i := to; i < len(keys)-1; i++ {
			segs = append(segs, seg{i, i + 1, false})
		}
	} else {
		for i := 0; i < len(keys)-1; i++ {
			segs = append(segs, seg{i, i + 1, false})
		}
	}
	// The pace: stride widths per loop, while in the loop.
	var loopTime float64
	if from >= 0 {
		for i := from; i <= to; i++ {
			loopTime += keys[i].Hold
		}
	}
	speed := 0.0
	if loopTime > 0 && a.Stride > 0 {
		speed = a.Stride * a.StickerBox.Width * p.rig.Size / loopTime
	}
	// One clock for the whole film, so short holds play at their length
	// (rounding each to whole frames would slow them down).
	var out []filmPose
	var travelled, elapsed, at float64
	tick := 1 / fps
	for _, s := range segs {
		hold := keys[s.from].Hold
		end := at + hold
		moving := from >= 0 && s.from >= from && s.from <= to && !(s.from == to && !s.wrap)
		for ; elapsed < end; elapsed += tick {
			k := puppetBetween(p.rig, keys[s.from], keys[s.to], (elapsed-at)/hold, s.wrap)
			if moving {
				travelled += speed * tick
			}
			fp := filmPose{bones: k, slots: keys[s.from].Slots, dx: travelled}
			if a.Hops && moving && loopTime > 0 {
				// As the app does: the arc's clock starts as it sets off.
				fp.dy = 0.12 * p.rig.Size * math.Abs(math.Sin(math.Pi*elapsed/loopTime))
			}
			out = append(out, fp)
		}
		at = end
	}
	for t := 0.0; t < 0.5; t += tick {
		out = append(out, filmPose{dx: travelled})
	}
	return out
}

func puppetBetween(rig *manifest.PuppetRig, a, b manifest.PuppetKey, progress float64, wrap bool) map[string]manifest.BonePose {
	t := easeApply(a.Ease, progress)
	out := map[string]manifest.BonePose{}
	for _, bone := range rig.Bones {
		x, y := a.Bones[bone.ID], b.Bones[bone.ID]
		if wrap {
			y.R += 360 * math.Round((x.R-y.R)/360)
		}
		mix := func(u, v float64) float64 { return u + (v-u)*t }
		one := func(v *float64) float64 {
			if v == nil {
				return 1
			}
			return *v
		}
		sx, sy := mix(one(x.SX), one(y.SX)), mix(one(x.SY), one(y.SY))
		out[bone.ID] = manifest.BonePose{R: mix(x.R, y.R), X: mix(x.X, y.X), Y: mix(x.Y, y.Y), SX: &sx, SY: &sy}
	}
	return out
}

func easeApply(ease string, t float64) float64 {
	switch ease {
	case "linear":
		return t
	case "in":
		return t * t
	case "out":
		return 1 - (1-t)*(1-t)
	case "step":
		return 0
	default:
		return t * t * (3 - 2*t)
	}
}

// film writes the rows playing together, one above the other.
func film(path string, rows []filmRow, loops int, s float64) error {
	const fps = 25.0
	var lines [][]filmPose
	frames, reach := 0, 0.0
	for _, r := range rows {
		l := timeline(r.p, r.a, loops, fps)
		lines = append(lines, l)
		frames = max(frames, len(l))
		reach = math.Max(reach, l[len(l)-1].dx)
	}
	size := rows[0].p.rig.Size
	w := int((size + reach) * s)
	h := int(size * s)
	var images []*image.Paletted
	var delays []int
	// The strip: frames 0.08 s apart through the first loops, each cut
	// round the character, to look at as a still.
	const cells, cols = 24, 8
	cw := int(size * s)
	strip := image.NewRGBA(image.Rect(0, 0, cw*cols, h*len(rows)*cells/cols))
	stripAt := map[int]int{}
	if lead := firstLoopFrame(rows[len(rows)-1].a, fps); true {
		for i := range cells {
			stripAt[lead+i*2] = i
		}
	}
	for f := 0; f < frames; f++ {
		frame := image.NewRGBA(image.Rect(0, 0, w, h*len(rows)))
		draw.Draw(frame, frame.Bounds(), &image.Uniform{color.RGBA{236, 236, 232, 255}}, image.Point{}, draw.Src)
		for i, r := range rows {
			l := lines[i]
			fp := l[min(f, len(l)-1)]
			dir := 1.0
			if r.a.Facing == "left" {
				dir = -1
			}
			start := 0.0
			if dir < 0 {
				start = reach
			}
			ground := int((r.p.rig.Bones[0].Y)*s) + h*i
			for x := 0; x < w; x++ {
				frame.Set(x, ground, color.RGBA{180, 170, 150, 255})
			}
			off := mat{a: s, d: s, e: (start + dir*fp.dx) * s, f: float64(h*i) - fp.dy*s}
			r.p.paint(frame, off, fp.bones, r.p.shown("", fp.slots))
		}
		if cell, ok := stripAt[f]; ok {
			at := image.Pt(cell%cols*cw, cell/cols*h*len(rows))
			for i, r := range rows {
				l := lines[i]
				fp := l[min(f, len(l)-1)]
				dir, start := 1.0, 0.0
				if r.a.Facing == "left" {
					dir, start = -1, reach
				}
				x0 := int((start + dir*fp.dx) * s)
				draw.Draw(strip, image.Rect(at.X, at.Y+h*i, at.X+cw, at.Y+h*(i+1)), frame, image.Pt(x0, h*i), draw.Src)
			}
		}
		pal := image.NewPaletted(frame.Bounds(), palette.Plan9)
		draw.FloydSteinberg.Draw(pal, frame.Bounds(), frame, image.Point{})
		images = append(images, pal)
		delays = append(delays, int(100/fps))
	}
	if len(images) == 0 {
		return errors.New("nothing to film")
	}
	if f, err := os.Create(strings.TrimSuffix(path, ".gif") + ".strip.png"); err == nil {
		png.Encode(f, strip)
		f.Close()
	}
	out, err := os.Create(path)
	if err != nil {
		return err
	}
	defer out.Close()
	return gif.EncodeAll(out, &gif.GIF{Image: images, Delay: delays})
}

// paint draws the posed puppet into dst under view (rig pixels to dst):
// every part's border first, then the art, back to front.
func (p *puppet) paint(dst *image.RGBA, view mat, bones map[string]manifest.BonePose, shown map[string]string) {
	world := p.world(bones)
	for _, border := range []bool{true, false} {
		for _, s := range p.rig.Slots {
			a, ok := s.Attachments[shown[s.ID]]
			if !ok || shown[s.ID] == manifest.PuppetHidden {
				continue
			}
			part, ok := p.rig.Parts[a.Part]
			if !ok || a.W <= 0 || a.H <= 0 {
				continue
			}
			b := p.bone[s.Bone]
			fx := 1.0
			if a.Flip {
				fx = -1
			}
			m := view.mul(world[s.Bone]).mul(translate(a.X+a.W/2-b.X, a.Y+a.H/2-b.Y)).mul(rotate(a.Rotate)).mul(scale(fx, 1))
			rect := [4]float64{float64(part.Rect[0]), float64(part.Rect[1]), float64(part.Rect[2]), float64(part.Rect[3])}
			src := rect
			hw, hh := a.W/2, a.H/2
			if border {
				if part.Border == ([4]int{}) || part.Rect[2] == 0 || part.Rect[3] == 0 {
					continue
				}
				src = [4]float64{float64(part.Border[0]), float64(part.Border[1]), float64(part.Border[2]), float64(part.Border[3])}
				hw *= src[2] / rect[2]
				hh *= src[3] / rect[3]
			}
			shade := 0.0
			if !border {
				shade = a.Shade
			}
			blit(dst, p.atlas, src, m, hw, hh, shade)
		}
	}
}

// blit draws the atlas rectangle src, as a box of half-size hw×hh about
// the origin of m, into dst.
func blit(dst *image.RGBA, atlas *image.RGBA, src [4]float64, m mat, hw, hh, shade float64) {
	minX, minY, maxX, maxY := math.Inf(1), math.Inf(1), math.Inf(-1), math.Inf(-1)
	for _, c := range [4][2]float64{{-hw, -hh}, {hw, -hh}, {-hw, hh}, {hw, hh}} {
		x, y := m.apply(c[0], c[1])
		minX, minY, maxX, maxY = math.Min(minX, x), math.Min(minY, y), math.Max(maxX, x), math.Max(maxY, y)
	}
	r := image.Rect(int(math.Floor(minX)), int(math.Floor(minY)), int(math.Ceil(maxX)), int(math.Ceil(maxY))).Intersect(dst.Bounds())
	inv := m.inv()
	ab := atlas.Bounds()
	for y := r.Min.Y; y < r.Max.Y; y++ {
		for x := r.Min.X; x < r.Max.X; x++ {
			lx, ly := inv.apply(float64(x)+0.5, float64(y)+0.5)
			if lx < -hw || lx >= hw || ly < -hh || ly >= hh {
				continue
			}
			u := int(src[0] + (lx+hw)*src[2]/(2*hw))
			v := int(src[1] + (ly+hh)*src[3]/(2*hh))
			if u < ab.Min.X || v < ab.Min.Y || u >= ab.Max.X || v >= ab.Max.Y {
				continue
			}
			o := atlas.PixOffset(u, v)
			al := float64(atlas.Pix[o+3]) / 255
			if al == 0 {
				continue
			}
			d := dst.PixOffset(x, y)
			for k := 0; k < 3; k++ {
				c := float64(atlas.Pix[o+k]) * (1 - shade)
				dst.Pix[d+k] = uint8(math.Min(255, c+float64(dst.Pix[d+k])*(1-al)))
			}
		}
	}
}

// firstLoopFrame is the frame where a move's loop first starts (0 for an
// action).
func firstLoopFrame(a *manifest.StickerAnimation, fps float64) int {
	if a.Loop == nil {
		return 0
	}
	var t float64
	for i := 0; i < a.Loop.From; i++ {
		t += a.Puppet.Keys[i].Hold
	}
	return int(math.Ceil(t * fps))
}
