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
	m := FaceMask(base, FaceBox{X: 0.3, Y: 0.3, Width: 0.4, Height: 0.4})
	if m.RGBAAt(50, 50).A != 0 || m.RGBAAt(5, 5).A != 255 {
		t.Errorf("mask: face transparent, rest opaque")
	}
	// A face box that reaches the silhouette's edge: the edge band stays the
	// sticker's own, in the mask and in the composite.
	edge := FaceBox{X: 0.05, Y: 0.3, Width: 0.4, Height: 0.4}
	if m := FaceMask(base, edge); m.RGBAAt(11, 50).A != 255 {
		t.Errorf("the mask must keep the model off the outline")
	}
	if c := Face(base, gen, edge).RGBAAt(11, 50); c != (color.RGBA{200, 0, 0, 255}) {
		t.Errorf("the outline band must stay the base's, got %v", c)
	}
	if FaceSeam(base, base, edge) != 0 || FaceSeam(base, gen, edge) == 0 {
		t.Errorf("seam: zero for an unchanged face, positive for a changed one")
	}
}
