package stickerimg

import (
	"image"
	"image/color"
	"testing"
)

func TestRemovePropKeepsTheCharacterAndDropsTheProp(t *testing.T) {
	// A 100×100 character (red, top) standing on a wide prop (green,
	// bottom), plus a leaf of the prop sticking out above the box.
	base := image.NewRGBA(image.Rect(0, 0, 200, 200))
	fill := func(img *image.RGBA, r image.Rectangle, c color.RGBA) {
		for y := r.Min.Y; y < r.Max.Y; y++ {
			for x := r.Min.X; x < r.Max.X; x++ {
				img.SetRGBA(x, y, c)
			}
		}
	}
	red, green := color.RGBA{200, 0, 0, 255}, color.RGBA{0, 160, 0, 255}
	fill(base, image.Rect(50, 20, 150, 150), red)
	fill(base, image.Rect(10, 150, 190, 180), green)
	fill(base, image.Rect(5, 120, 12, 128), green) // a leaf outside the box
	// The edit: the same character, the prop gone, the feet redrawn.
	gen := image.NewRGBA(image.Rect(0, 0, 200, 200))
	fill(gen, image.Rect(50, 20, 150, 160), red)
	box := FaceBox{X: 0, Y: 0.7, Width: 1, Height: 0.3}

	out := RemoveProp(base, gen, box)
	if got := out.RGBAAt(100, 50); got != red {
		t.Errorf("character above the box changed: %v", got)
	}
	if got := out.RGBAAt(100, 155); got != red {
		t.Errorf("redrawn feet missing: %v", got)
	}
	if got := out.RGBAAt(20, 170); got.A != 0 {
		t.Errorf("prop still there: %v", got)
	}
	if got := out.RGBAAt(8, 124); got.A != 0 {
		t.Errorf("stray leaf outside the box kept: %v", got)
	}

	mask := PropMask(base, box)
	if mask.RGBAAt(100, 50).A != 255 || mask.RGBAAt(100, 170).A != 0 {
		t.Errorf("mask should be opaque outside the box and clear inside")
	}
}

func TestAlignFindsTheScaleAndShift(t *testing.T) {
	// A pattern, and the same pattern drawn 15 % bigger and shifted.
	ref := image.NewRGBA(image.Rect(0, 0, 256, 256))
	for y := 60; y < 180; y++ {
		for x := 70; x < 190; x++ {
			ref.SetRGBA(x, y, color.RGBA{uint8(x), uint8(y), 90, 255})
		}
	}
	want := Placement{S: 1 / 1.15, Tx: 12, Ty: -6}
	inv := Placement{S: 1 / want.S, Tx: -want.Tx / want.S, Ty: -want.Ty / want.S}
	img := Warp(ref, inv, 256, 256)
	got := Align(ref, img, AlignOptions{MinScale: 0.75, MaxScale: 1.25, MaxShift: 0.2})
	if d := got.S - want.S; d > 0.01 || d < -0.01 {
		t.Errorf("scale %.3f, want %.3f", got.S, want.S)
	}
	check := Warp(img, got, 256, 256)
	if c := check.RGBAAt(120, 120); absDiff(c.R, 120) > 6 || absDiff(c.G, 120) > 6 {
		t.Errorf("aligned pixel %v, want about (120,120)", c)
	}
}
