package main

import (
	"image"
	"image/color"
	"testing"
)

func TestCutThroughKeepsThePictureWhereTheMaskIs(t *testing.T) {
	// A wide picture (8×2) and a 4:3-sized mask (4×2) on its centre.
	pic := image.NewRGBA(image.Rect(0, 0, 8, 2))
	for x := 0; x < 8; x++ {
		for y := 0; y < 2; y++ {
			pic.Set(x, y, color.RGBA{uint8(x * 10), 100, 50, 255})
		}
	}
	mask := image.NewGray(image.Rect(0, 0, 4, 2))
	mask.SetGray(1, 0, color.Gray{255})
	mask.SetGray(2, 1, color.Gray{128})
	out, err := cutThrough(pic, mask)
	if err != nil {
		t.Fatal(err)
	}
	if got := out.RGBAAt(3, 0); got.A != 255 || got.R != 30 {
		t.Errorf("under the mask: %v, want the picture's (30, 100, 50)", got)
	}
	if got := out.RGBAAt(4, 1); got.A < 126 || got.A > 130 {
		t.Errorf("under a half-white mask: alpha %d, want about half", got.A)
	}
	if got := out.RGBAAt(0, 0); got.A != 0 {
		t.Errorf("outside the mask: %v, want transparent", got)
	}
	if _, err := cutThrough(pic, image.NewGray(image.Rect(0, 0, 4, 3))); err == nil {
		t.Error("a mask of another height: want an error")
	}
}

func TestCutThroughCentresAWideMaskOnThe43Picture(t *testing.T) {
	// A 4×2 picture and a wide mask (8×2): the picture shows its centre.
	pic := image.NewRGBA(image.Rect(0, 0, 4, 2))
	for x := 0; x < 4; x++ {
		for y := 0; y < 2; y++ {
			pic.Set(x, y, color.RGBA{uint8(x * 10), 100, 50, 255})
		}
	}
	mask := image.NewGray(image.Rect(0, 0, 8, 2))
	mask.SetGray(2, 0, color.Gray{255}) // the picture's x 0
	mask.SetGray(7, 0, color.Gray{255}) // past its right side
	out, err := cutThrough(pic, mask)
	if err != nil {
		t.Fatal(err)
	}
	if got := out.RGBAAt(0, 0); got.A != 255 || got.R != 0 {
		t.Errorf("under the mask: %v, want the picture's (0, 100, 50)", got)
	}
	if got := out.RGBAAt(3, 0); got.A != 0 {
		t.Errorf("outside the mask: %v, want transparent", got)
	}
}
