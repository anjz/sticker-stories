package stickerimg

import (
	"image"
	"image/color"
	"testing"
)

// cell draws a frame like the generator would: a wide pad at the bottom
// and a body square some way above it, at the given scale, inside a
// transparent 300×300 cell.
func cell(padW, padH, body, lift int, scale float64) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, 300, 300))
	s := func(v int) int { return int(float64(v)*scale + 0.5) }
	cx, bottom := 150, 280
	pad := image.Rect(cx-s(padW)/2, bottom-s(padH), cx+s(padW)/2, bottom)
	bodyBottom := pad.Min.Y - s(lift)
	bod := image.Rect(cx-s(body)/2, bodyBottom-s(body), cx+s(body)/2, bodyBottom)
	for y := 0; y < 300; y++ {
		for x := 0; x < 300; x++ {
			p := image.Pt(x, y)
			switch {
			case p.In(pad):
				img.SetRGBA(x, y, color.RGBA{40, 140, 60, 255})
			case p.In(bod):
				img.SetRGBA(x, y, color.RGBA{200, 60, 60, 255})
			}
		}
	}
	return img
}

func TestAnimationRegistersOnTheBase(t *testing.T) {
	cells := []*image.RGBA{
		cell(160, 30, 60, 0, 1),     // resting
		cell(160, 30, 60, 80, 1),    // in the air
		cell(160, 30, 60, 0, 1.1),   // resting, drawn 10 % bigger by the generator
		cell(160, 30, 60, 40, 0.95), // a little smaller
	}
	sheet, err := Animation(cells, AnimOptions{StickerSize: 512, Border: 0.025, Margin: 0.03, Columns: 2, Normalize: true})
	if err != nil {
		t.Fatal(err)
	}
	if sheet.Count != 4 || sheet.Columns != 2 {
		t.Fatalf("count %d columns %d", sheet.Count, sheet.Columns)
	}
	if sheet.Image.Bounds().Dx() != 2*sheet.Frame.X || sheet.Image.Bounds().Dy() != 2*sheet.Frame.Y {
		t.Fatalf("sheet %v for frame %v", sheet.Image.Bounds(), sheet.Frame)
	}
	// Normalisation: frames 3 and 4 were scaled back to the first frame's pad.
	if s := sheet.Scales; s[0] != 1 || s[1] != 1 || s[2] > 0.92 || s[2] < 0.89 || s[3] < 1.04 || s[3] > 1.07 {
		t.Errorf("scales %v", s)
	}
	// The pad's bottom edge and centre are at the same spot in every frame.
	var padBottom, padCentre []int
	for i := 0; i < sheet.Count; i++ {
		col, row := i%sheet.Columns, i/sheet.Columns
		frame := image.NewRGBA(image.Rect(0, 0, sheet.Frame.X, sheet.Frame.Y))
		for y := 0; y < sheet.Frame.Y; y++ {
			for x := 0; x < sheet.Frame.X; x++ {
				frame.SetRGBA(x, y, sheet.Image.RGBAAt(col*sheet.Frame.X+x, row*sheet.Frame.Y+y))
			}
		}
		// Green pad pixels only (the border is white, the body red).
		minX, maxX, maxY := frame.Rect.Dx(), -1, -1
		for y := 0; y < frame.Rect.Dy(); y++ {
			for x := 0; x < frame.Rect.Dx(); x++ {
				c := frame.RGBAAt(x, y)
				if c.A == 255 && c.G > 100 && c.R < 100 {
					minX, maxX = min(minX, x), max(maxX, x)
					maxY = max(maxY, y)
				}
			}
		}
		padBottom = append(padBottom, maxY)
		padCentre = append(padCentre, (minX+maxX)/2)
		if w := maxX - minX + 1; w < 155 || w > 165 {
			t.Errorf("frame %d: pad width %d, want ≈160", i+1, w)
		}
	}
	for i := 1; i < sheet.Count; i++ {
		if d := padBottom[i] - padBottom[0]; d < -1 || d > 1 {
			t.Errorf("frame %d: pad bottom %d vs %d", i+1, padBottom[i], padBottom[0])
		}
		if d := padCentre[i] - padCentre[0]; d < -1 || d > 1 {
			t.Errorf("frame %d: pad centre %d vs %d", i+1, padCentre[i], padCentre[0])
		}
	}
	// The frame is tall enough for the jump: the rest content sits in the
	// lower part of the frame with headroom above.
	if sheet.Rest.Min.Y < 60 {
		t.Errorf("rest box %v should leave headroom for the jump in frame %v", sheet.Rest, sheet.Frame)
	}
	// Border: paper-white just outside the pad.
	if c := sheet.Image.RGBAAt(padCentre[0], padBottom[0]+4); c.R < 200 || c.G < 200 || c.B < 200 || c.A != 255 {
		t.Errorf("expected the white border under the pad, got %v", c)
	}
}

func TestAnimationCapsTheSheet(t *testing.T) {
	cells := []*image.RGBA{cell(160, 30, 60, 0, 1), cell(160, 30, 60, 100, 1)}
	sheet, err := Animation(cells, AnimOptions{StickerSize: 512, Border: 0.025, Margin: 0.03, Columns: 2, MaxSheet: 200})
	if err != nil {
		t.Fatal(err)
	}
	if b := sheet.Image.Bounds(); b.Dx() > 200 || b.Dy() > 200 {
		t.Errorf("sheet %v exceeds the cap", b)
	}
	if sheet.Frame.X*2 != sheet.Image.Bounds().Dx() {
		t.Errorf("frame %v does not tile the sheet %v", sheet.Frame, sheet.Image.Bounds())
	}
}

func TestSplitGrid(t *testing.T) {
	sheet := image.NewRGBA(image.Rect(0, 0, 40, 20))
	sheet.SetRGBA(35, 15, color.RGBA{255, 0, 0, 255}) // in the last cell of a 4×2 grid
	cells := SplitGrid(sheet, 4, 2)
	if len(cells) != 8 {
		t.Fatalf("%d cells", len(cells))
	}
	if c := cells[7].RGBAAt(5, 5); c.R != 255 {
		t.Errorf("last cell should hold the pixel, got %v", c)
	}
	if c := cells[0].RGBAAt(5, 5); c.A != 0 {
		t.Errorf("first cell should be empty, got %v", c)
	}
}

func TestStripEdgeCrumbs(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 100, 100))
	fill := func(r image.Rectangle) {
		for y := r.Min.Y; y < r.Max.Y; y++ {
			for x := r.Min.X; x < r.Max.X; x++ {
				img.SetRGBA(x, y, color.RGBA{0, 120, 0, 255})
			}
		}
	}
	fill(image.Rect(20, 30, 80, 100)) // the character, touching the bottom edge
	fill(image.Rect(40, 0, 60, 3))    // a sliver of the neighbour's art on the top edge
	fill(image.Rect(85, 10, 92, 17))  // a small fly, not on an edge
	StripEdgeCrumbs(img, 8, 0.02)
	if img.RGBAAt(50, 1).A != 0 {
		t.Errorf("the edge sliver should be gone")
	}
	if img.RGBAAt(50, 99).A == 0 {
		t.Errorf("the character touching the edge must stay")
	}
	if img.RGBAAt(88, 13).A == 0 {
		t.Errorf("the fly must stay")
	}
}

func TestAnimationRestFramesUseTheRealArt(t *testing.T) {
	// The generated rest cells draw the body 20 % too small; the real art
	// (at 1.5× the sheet's scale) replaces them.
	cells := []*image.RGBA{cell(160, 30, 48, 0, 1), cell(160, 30, 60, 80, 1), cell(160, 30, 48, 0, 1)}
	real := cell(240, 45, 90, 0, 1)
	sheet, err := Animation(cells, AnimOptions{StickerSize: 512, Border: 0.025, Margin: 0.03, Columns: 3, Rest: real, RestFrames: []int{0, 2}})
	if err != nil {
		t.Fatal(err)
	}
	bodyWidth := func(frame int) int {
		minX, maxX := sheet.Frame.X, -1
		for y := 0; y < sheet.Frame.Y; y++ {
			for x := 0; x < sheet.Frame.X; x++ {
				c := sheet.Image.RGBAAt(frame*sheet.Frame.X+x, y)
				if c.A == 255 && c.R > 150 && c.G < 100 {
					minX, maxX = min(minX, x), max(maxX, x)
				}
			}
		}
		return maxX - minX + 1
	}
	if w := bodyWidth(0); w < 58 || w > 62 {
		t.Errorf("rest frame body width %d, want ≈60 (the real art scaled to the pad)", w)
	}
	if w := bodyWidth(2); w < 58 || w > 62 {
		t.Errorf("last rest frame body width %d, want ≈60", w)
	}
	if w := bodyWidth(1); w < 58 || w > 62 {
		t.Errorf("generated frame body width %d, want ≈60", w)
	}
}
