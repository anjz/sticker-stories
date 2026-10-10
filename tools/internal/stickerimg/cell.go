package stickerimg

import (
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"math"
)

// PlaceArt is the sticker's art exactly where Sticker puts it — trimmed,
// scaled to its Fill (or the margin), centred in a Size×Size square — but
// without the border or the finish: a scaffold cell, the sticker at its
// size and place for the generator to re-pose.
func PlaceArt(src *image.RGBA, o StickerOptions) (*image.RGBA, error) {
	if o.Size <= 0 {
		o.Size = 1024
	}
	cleaned := Clean(src, o.Threshold)
	box := Bounds(cleaned, o.Threshold)
	if box.Empty() {
		return nil, fmt.Errorf("image is fully transparent")
	}
	crop := image.NewRGBA(image.Rect(0, 0, box.Dx(), box.Dy()))
	draw.Draw(crop, crop.Bounds(), cleaned, box.Min, draw.Src)
	inner := float64(o.Size) * (1 - 2*o.Margin - 2*o.Border)
	if o.Fill > 0 {
		inner = float64(o.Size) * (o.Fill - 2*o.Border)
	}
	scale := math.Min(inner/float64(crop.Rect.Dx()), inner/float64(crop.Rect.Dy()))
	w, h := int(float64(crop.Rect.Dx())*scale+0.5), int(float64(crop.Rect.Dy())*scale+0.5)
	scaled := Resize(crop, w, h)
	radius := int(math.Round(o.Border * float64(o.Size)))
	// The same arithmetic as Sticker, which centres the outlined art.
	off := image.Pt((o.Size-(w+2*radius))/2+radius, (o.Size-(h+2*radius))/2+radius)
	out := image.NewRGBA(image.Rect(0, 0, o.Size, o.Size))
	draw.Draw(out, scaled.Bounds().Add(off), scaled, image.Point{}, draw.Over)
	return out, nil
}

// FrameQA is what MeasureFrames found on one frame of an assembled sheet,
// against its first frame (the sticker's rest pose): how its drawing's size
// and place compare, and whether it was cut.
type FrameQA struct {
	Frame int `json:"frame"` // 1-based
	// Area is the frame's solid area over the rest pose's; Height its
	// drawing's height over the rest's; Jump the change in solid area
	// from the frame before (0 for the first).
	Area   float64 `json:"area"`
	Height float64 `json:"height"`
	Jump   float64 `json:"jump"`
	// Bottom and Centre are how far the drawing's bottom and its centre
	// moved from the rest's, as fractions of the rest drawing's height.
	Bottom float64 `json:"bottom"`
	Centre float64 `json:"centre"`
	// Edge: the drawing touches the frame's edge — cut off.
	Edge bool `json:"edge"`
	// Problems are the checks it failed, in words.
	Problems []string `json:"problems,omitempty"`
}

// Limits of FrameQA's checks: a frame outside them is reported.
const (
	qaAreaLow, qaAreaHigh = 0.8, 1.3 // solid area vs the rest pose
	qaHeightLow           = 0.8      // a crouch is fine, a shrunk drawing is not
	qaJump                = 0.15     // area change from one frame to the next
	qaBottom              = 0.05     // the ground under it moving, in rest heights
	qaCentre              = 0.12     // the drawing wandering sideways, in rest heights
)

// MeasureFrames checks every frame of an assembled sheet against its first
// (the rest pose): its size, its place, its step from the frame before and
// whether the frame's edge cut it. grow skips the size checks (a sprout,
// a panel unfolding: meant to change size); flies skips the bottom check
// (a flight's flame or a hop's lift move the bottom on purpose).
func MeasureFrames(s *AnimSheet, threshold uint8, grow, flies bool) []FrameQA {
	frame := func(i int) *image.RGBA {
		col, row := i%s.Columns, i/s.Columns
		out := image.NewRGBA(image.Rect(0, 0, s.Frame.X, s.Frame.Y))
		draw.Draw(out, out.Bounds(), s.Image, image.Pt(col*s.Frame.X, row*s.Frame.Y), draw.Src)
		return out
	}
	ref := frame(0)
	refArea := float64(opaqueCount(ref, 128))
	refBox := Bounds(ref, threshold)
	unit := float64(max(refBox.Dy(), 1))
	out := make([]FrameQA, s.Count)
	prevArea := 0.0
	for i := 0; i < s.Count; i++ {
		art := frame(i)
		area := float64(opaqueCount(art, 128))
		box := Bounds(art, threshold)
		q := FrameQA{Frame: i + 1}
		if refArea > 0 {
			q.Area = round3(area / refArea)
		}
		q.Height = round3(float64(box.Dy()) / unit)
		if i > 0 && prevArea > 0 {
			q.Jump = round3(math.Abs(area-prevArea) / prevArea)
		}
		q.Bottom = round3(float64(box.Max.Y-refBox.Max.Y) / unit)
		q.Centre = round3(float64((box.Min.X+box.Max.X)-(refBox.Min.X+refBox.Max.X)) / 2 / unit)
		b := art.Bounds()
		q.Edge = !box.Empty() && (box.Min.X <= b.Min.X || box.Min.Y <= b.Min.Y || box.Max.X >= b.Max.X || box.Max.Y >= b.Max.Y)
		if !grow {
			if q.Area < qaAreaLow || q.Area > qaAreaHigh {
				q.Problems = append(q.Problems, fmt.Sprintf("size: %.0f%% of the sticker's area", q.Area*100))
			}
			if q.Height < qaHeightLow {
				q.Problems = append(q.Problems, fmt.Sprintf("shrunk: %.0f%% of the sticker's height", q.Height*100))
			}
			if q.Jump > qaJump {
				q.Problems = append(q.Problems, fmt.Sprintf("pops: area %+.0f%% from the frame before", (area-prevArea)/prevArea*100))
			}
		}
		if !flies && math.Abs(q.Bottom) > qaBottom {
			q.Problems = append(q.Problems, fmt.Sprintf("moved: its bottom %+.0f%% of its height", q.Bottom*100))
		}
		if math.Abs(q.Centre) > qaCentre {
			q.Problems = append(q.Problems, fmt.Sprintf("wandered: %+.0f%% of its height sideways", q.Centre*100))
		}
		if q.Edge {
			q.Problems = append(q.Problems, "cut off at the frame's edge")
		}
		out[i] = q
		prevArea = area
	}
	return out
}

func round3(v float64) float64 { return math.Round(v*1000) / 1000 }

// SplitExact cuts a sheet into cols×rows cells on the nominal grid — for a
// sheet drawn over a scaffold, whose drawings stay inside their cells
// (SplitGrid looks for the emptiest line instead).
func SplitExact(sheet *image.RGBA, cols, rows int) []*image.RGBA {
	b := sheet.Bounds()
	cw, ch := b.Dx()/cols, b.Dy()/rows
	var cells []*image.RGBA
	for row := 0; row < rows; row++ {
		for col := 0; col < cols; col++ {
			cell := image.NewRGBA(image.Rect(0, 0, cw, ch))
			draw.Draw(cell, cell.Bounds(), sheet, image.Pt(b.Min.X+col*cw, b.Min.Y+row*ch), draw.Src)
			cells = append(cells, cell)
		}
	}
	return cells
}

// Scaffold lays cells out in a cols×rows grid of cell-sized squares: the
// sheet a generator re-poses, every cell the sticker at its size, or what a
// caller puts in a cell (the pose a sheet starts from).
func Scaffold(cells []*image.RGBA, cols, rows, cell int) *image.RGBA {
	out := image.NewRGBA(image.Rect(0, 0, cols*cell, rows*cell))
	for i, c := range cells {
		if i >= cols*rows {
			break
		}
		if c.Bounds().Dx() != cell || c.Bounds().Dy() != cell {
			c = Resize(c, cell, cell)
		}
		col, row := i%cols, i/cols
		draw.Draw(out, image.Rect(col*cell, row*cell, (col+1)*cell, (row+1)*cell), c, c.Bounds().Min, draw.Over)
	}
	return out
}

// LightSheet is an animation of light alone: every frame the sticker's
// finished image (trimmed to its art), lit by that frame's entry of light
// (0 as drawn, 1 brightest): its brightest parts flare toward white, its
// colours deepen a little and a soft bloom spreads from the bright core,
// all within the drawing — a galaxy's centre glowing while its border
// stays as it is. opacity (optional, one entry per frame, 0–1) fades the
// whole sticker: a galaxy appearing where it is.
func LightSheet(sticker *image.RGBA, light, opacity []float64, columns int) *AnimSheet {
	box := Bounds(sticker, 0)
	pad := max(box.Dx(), box.Dy()) / 40
	box = box.Inset(-pad).Intersect(sticker.Bounds())
	w, h := box.Dx(), box.Dy()
	if columns <= 0 {
		columns = 4
	}
	columns = min(columns, len(light))
	rows := (len(light) + columns - 1) / columns

	// The drawing un-premultiplied, its luminance, and the bloom: the
	// bright core, blurred.
	n := w * h
	rgb := make([][3]float64, n)
	alpha := make([]float64, n)
	lum := make([]float64, n)
	bright := make([][3]float64, n)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			i := y*w + x
			c := sticker.RGBAAt(box.Min.X+x, box.Min.Y+y)
			if c.A == 0 {
				continue
			}
			a := float64(c.A)
			alpha[i] = a / 255
			rgb[i] = [3]float64{float64(c.R) / a, float64(c.G) / a, float64(c.B) / a}
			lum[i] = 0.3*rgb[i][0] + 0.59*rgb[i][1] + 0.11*rgb[i][2]
			k := math.Max(lum[i]-0.6, 0) / 0.4 * alpha[i]
			bright[i] = [3]float64{rgb[i][0] * k, rgb[i][1] * k, rgb[i][2] * k}
		}
	}
	bloom := boxBlur3(bright, w, h, max(w, h)/30)

	out := image.NewRGBA(image.Rect(0, 0, columns*w, rows*h))
	for f, amount := range light {
		ox, oy := (f%columns)*w, (f/columns)*h
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				i := y*w + x
				if alpha[i] == 0 {
					continue
				}
				var c [3]float64
				k := math.Min(amount*math.Pow(lum[i], 2.5)*1.3, 1)
				for ch := 0; ch < 3; ch++ {
					v := rgb[i][ch] + (rgb[i][ch]-lum[i])*amount*0.35 // a little more colour
					v += (1 - v) * k                                  // the bright parts flare
					v += bloom[i][ch] * amount * 0.8                  // the core's glow spreading
					c[ch] = math.Min(math.Max(v, 0), 1)
				}
				a := alpha[i] * 255
				if f < len(opacity) {
					a *= math.Min(math.Max(opacity[f], 0), 1)
				}
				out.SetRGBA(ox+x, oy+y, color.RGBA{
					R: uint8(c[0]*a + 0.5), G: uint8(c[1]*a + 0.5), B: uint8(c[2]*a + 0.5), A: uint8(a + 0.5)})
			}
		}
	}
	rest := Bounds(sticker, 0).Sub(box.Min)
	return &AnimSheet{Image: out, Frame: image.Pt(w, h), Columns: columns, Count: len(light), Rest: rest}
}

// boxBlur3 blurs a w×h field of colours with three box passes of radius r
// each way, close to a Gaussian.
func boxBlur3(field [][3]float64, w, h, r int) [][3]float64 {
	if r < 1 {
		return field
	}
	cur := field
	for pass := 0; pass < 3; pass++ {
		for _, horizontal := range []bool{true, false} {
			next := make([][3]float64, len(cur))
			length, lines := w, h
			if !horizontal {
				length, lines = h, w
			}
			at := func(line, pos int) int {
				if horizontal {
					return line*w + pos
				}
				return pos*w + line
			}
			for line := 0; line < lines; line++ {
				var sum [3]float64
				count := 0
				for pos := -r; pos < length+r; pos++ {
					if in := pos + r; in < length {
						for ch := range sum {
							sum[ch] += cur[at(line, in)][ch]
						}
						count++
					}
					if out := pos - r - 1; out >= 0 {
						for ch := range sum {
							sum[ch] -= cur[at(line, out)][ch]
						}
						count--
					}
					if pos >= 0 && pos < length && count > 0 {
						for ch := range sum {
							next[at(line, pos)][ch] = sum[ch] / float64(count)
						}
					}
				}
			}
			cur = next
		}
	}
	return cur
}
