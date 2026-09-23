package stickerimg

import (
	"image"
	"image/color"
	"testing"
)

func TestFaceKeepsTheOutlineAndChangesOnlyTheFace(t *testing.T) {
	base := image.NewRGBA(image.Rect(0, 0, 100, 100))
	gen := image.NewRGBA(image.Rect(0, 0, 100, 100))
	for y := 0; y < 100; y++ {
		for x := 0; x < 100; x++ {
			if x >= 10 && x < 90 {
				base.SetRGBA(x, y, color.RGBA{200, 0, 0, 255}) // red body, transparent sides
			}
			gen.SetRGBA(x, y, color.RGBA{0, 0, 200, 255}) // the edit painted everything blue
		}
	}
	out := Face(base, gen, FaceBox{X: 0.3, Y: 0.3, Width: 0.4, Height: 0.4})
	if c := out.RGBAAt(50, 50); c.B < 190 || c.R > 10 {
		t.Errorf("centre of the face should be the new face, got %v", c)
	}
	if c := out.RGBAAt(20, 20); c != (color.RGBA{200, 0, 0, 255}) {
		t.Errorf("outside the face must be untouched, got %v", c)
	}
	if c := out.RGBAAt(5, 50); c.A != 0 {
		t.Errorf("the outline (alpha) must stay the base's, got %v", c)
	}
	m := FaceMask(100, 100, FaceBox{X: 0.3, Y: 0.3, Width: 0.4, Height: 0.4})
	if m.RGBAAt(50, 50).A != 0 || m.RGBAAt(5, 5).A != 255 {
		t.Errorf("mask: face transparent, rest opaque")
	}
}
