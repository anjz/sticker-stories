package stickerimg

import (
	"fmt"
	"image"
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
