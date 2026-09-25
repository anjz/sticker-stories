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

func TestSplitGridCutsWhereTheSheetIsEmpty(t *testing.T) {
	// A 2×1 sheet of 200×100 whose left character reaches 8 px past the
	// nominal middle line, with a gap before the right one.
	sheet := image.NewRGBA(image.Rect(0, 0, 200, 100))
	for y := 20; y < 80; y++ {
		for x := 10; x < 108; x++ {
			sheet.SetRGBA(x, y, color.RGBA{200, 50, 50, 255})
		}
		for x := 125; x < 190; x++ {
			sheet.SetRGBA(x, y, color.RGBA{50, 50, 200, 255})
		}
	}
	cells := SplitGrid(sheet, 2, 1)
	if w := cells[0].Rect.Dx(); w < 108 || w > 125 {
		t.Errorf("left cell is %d wide; the cut should fall in the gap 108–125", w)
	}
	if box := Bounds(cells[0], 0); box.Dx() != 98 {
		t.Errorf("left character should be whole (98 px), got %v", box)
	}
	if box := Bounds(cells[1], 0); box.Dx() != 65 {
		t.Errorf("right character should be whole (65 px), got %v", box)
	}
}

func TestSheetScalesMatchEachSheetToTheFirst(t *testing.T) {
	// Two sheets of three; the second sheet's rest cell (index 5) has 81 %
	// of the first's area, so its cells scale up by √(1/0.81) ≈ 1.11.
	areas := []float64{100, 90, 95, 70, 75, 81}
	got := sheetScales(6, []int{3, 3}, []int{0, 5}, areas, 0.25)
	for i := 0; i < 3; i++ {
		if got[i] != 1 {
			t.Errorf("sheet 1 cell %d scale %.3f, want 1", i, got[i])
		}
	}
	for i := 3; i < 6; i++ {
		if d := got[i] - 1/0.9; d > 1e-9 || d < -1e-9 {
			t.Errorf("sheet 2 cell %d scale %.4f, want %.4f", i, got[i], 1/0.9)
		}
	}

	// A sheet without a rest frame carries the previous sheet's scale; a
	// wildly different area (not the same pose) is ignored.
	got = sheetScales(9, []int{3, 3, 3}, []int{0, 5}, []float64{100, 0, 0, 0, 0, 25, 0, 0, 0}, 0.25)
	for i, s := range got {
		if s != 1 {
			t.Errorf("cell %d scale %.3f, want 1 (drift beyond the limit is ignored)", i, s)
		}
	}
}

func TestAnimationBringsEverySheetToTheRestSize(t *testing.T) {
	// Sheet 1 drawn at 1.0, sheet 2 at 0.8: after assembly every frame's
	// pad should be the same width.
	var cells []*image.RGBA
	for i := 0; i < 2; i++ {
		cells = append(cells, cell(200, 30, 60, 20, 1.0))
	}
	for i := 0; i < 2; i++ {
		cells = append(cells, cell(200, 30, 60, 20, 0.8))
	}
	rest := cell(200, 30, 60, 20, 1.3)
	sheet, err := Animation(cells, AnimOptions{
		StickerSize: 400, Border: 0.02, Margin: 0.02, Threshold: 8, Columns: 4,
		Rest: rest, RestFrames: []int{0, 3}, SheetSizes: []int{2, 2},
	})
	if err != nil {
		t.Fatal(err)
	}
	var widths []int
	for i := 0; i < 4; i++ {
		frame := sheet.Image.SubImage(image.Rect(i*sheet.Frame.X, 0, (i+1)*sheet.Frame.X, sheet.Frame.Y)).(*image.RGBA)
		widths = append(widths, Bounds(frame, 8).Dx())
	}
	for i, w := range widths {
		if d := w - widths[0]; d > 3 || d < -3 {
			t.Errorf("frame %d is %d px wide, frame 1 %d: sheets not brought to one size (%v)", i+1, w, widths[0], widths)
		}
	}
}

// flyer draws a body with a pattern (so a match has something to hold on
// to) and a wing that sweeps from one side to the other, the whole thing
// shifted by (dx, dy) in its cell — the generator's placement wanders.
func flyer(wing, dx, dy int) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, 300, 300))
	for y := 0; y < 300; y++ {
		for x := 0; x < 300; x++ {
			bx, by := x-dx, y-dy
			switch {
			case bx >= 110 && bx < 190 && by >= 120 && by < 200:
				img.SetRGBA(x, y, color.RGBA{uint8(bx), uint8(by), 120, 255})
			case bx >= 150+wing-20 && bx < 150+wing+20 && by >= 80 && by < 120:
				img.SetRGBA(x, y, color.RGBA{250, 250, 250, 255})
			}
		}
	}
	return img
}

func TestAnimationMatchesMovingFramesOnTheirBody(t *testing.T) {
	cells := []*image.RGBA{
		flyer(0, 0, 0), flyer(-30, 12, -7), flyer(-10, -9, 5), flyer(20, 6, 10), flyer(30, -4, -8), flyer(0, 0, 0),
	}
	sheet, err := Animation(cells, AnimOptions{StickerSize: 300, Border: 0.01, Margin: 0.01, Threshold: 8, Columns: 6, Register: RegisterBody, Loop: [2]int{1, 4}})
	if err != nil {
		t.Fatal(err)
	}
	// The body's top-left corner (its darkest red) is in the same spot in every frame.
	var at []image.Point
	for i := 0; i < sheet.Count; i++ {
		frame := image.Rect(i*sheet.Frame.X, 0, (i+1)*sheet.Frame.X, sheet.Frame.Y)
		found := image.Pt(-1, -1)
		for y := frame.Min.Y; y < frame.Max.Y && found.X < 0; y++ {
			for x := frame.Min.X; x < frame.Max.X; x++ {
				c := sheet.Image.RGBAAt(x, y)
				if c.A == 255 && c.B == 120 && c.R < 115 && c.G < 125 {
					found = image.Pt(x-frame.Min.X, y)
					break
				}
			}
		}
		at = append(at, found)
	}
	for i, p := range at {
		if d := p.Sub(at[0]); abs(d.X) > 2 || abs(d.Y) > 2 {
			t.Errorf("frame %d body at %v, frame 0 at %v", i, p, at[0])
		}
	}
}
