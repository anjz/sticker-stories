package stickerimg

import (
	"image"
	"image/color"
	"testing"
)

func blob(w, h int, r image.Rectangle) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := r.Min.Y; y < r.Max.Y; y++ {
		for x := r.Min.X; x < r.Max.X; x++ {
			img.SetRGBA(x, y, color.RGBA{200, 50, 50, 255})
		}
	}
	return img
}

func TestSticker(t *testing.T) {
	src := blob(400, 400, image.Rect(100, 150, 200, 350)) // 100×200 red block off-centre
	out, err := Sticker(src, StickerOptions{Size: 256, Border: 0.04, Margin: 0.05})
	if err != nil {
		t.Fatal(err)
	}
	if out.Bounds().Dx() != 256 || out.Bounds().Dy() != 256 {
		t.Fatalf("size %v", out.Bounds())
	}
	box := Bounds(out, 0)
	// centred: symmetric margins within a pixel
	if d := box.Min.X - (256 - box.Max.X); d < -2 || d > 2 {
		t.Errorf("not centred horizontally: %v", box)
	}
	if d := box.Min.Y - (256 - box.Max.Y); d < -2 || d > 2 {
		t.Errorf("not centred vertically: %v", box)
	}
	// outline: pixel just inside the top edge of the box is white
	c := out.RGBAAt(128, box.Min.Y+2)
	if c.R < 240 || c.G < 240 || c.B < 240 {
		t.Errorf("expected white border at top, got %v", c)
	}
	// centre still red
	if c := out.RGBAAt(128, 128); c.R < 150 || c.G > 90 {
		t.Errorf("centre should be red, got %v", c)
	}
	if _, err := Sticker(image.NewRGBA(image.Rect(0, 0, 10, 10)), StickerOptions{Size: 64}); err == nil {
		t.Errorf("fully transparent should error")
	}
}

func TestWideCanvasAndCentre(t *testing.T) {
	base := blob(40, 30, image.Rect(0, 0, 40, 30))
	canvas, mask, err := WideCanvas(base, 60)
	if err != nil {
		t.Fatal(err)
	}
	if canvas.Bounds().Dx() != 60 || mask.RGBAAt(5, 5).A != 0 || mask.RGBAAt(30, 5).A != 255 {
		t.Errorf("mask wrong: side %v centre %v", mask.RGBAAt(5, 5), mask.RGBAAt(30, 5))
	}
	if c := canvas.RGBAAt(30, 15); c.R != 200 {
		t.Errorf("base not centred: %v", c)
	}
	back := Centre(canvas, 40)
	if back.Bounds().Dx() != 40 || back.RGBAAt(0, 0).R != 200 {
		t.Errorf("centre crop wrong")
	}
}

func TestResizeKeepsAlphaEdges(t *testing.T) {
	src := blob(100, 100, image.Rect(0, 0, 50, 100))
	out := Resize(src, 10, 10)
	if out.RGBAAt(1, 5).A != 255 || out.RGBAAt(8, 5).A != 0 {
		t.Errorf("alpha not preserved: %v %v", out.RGBAAt(1, 5), out.RGBAAt(8, 5))
	}
	if c := out.RGBAAt(1, 5); c.R != 200 {
		t.Errorf("colour bled: %v", c)
	}
}
