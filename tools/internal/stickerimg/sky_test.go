package stickerimg

import (
	"image"
	"image/color"
	"testing"
)

// A blue sky paling downwards with a white cloud in it, a green tree on
// green ground, and a planet's dark night side against a black sky.
func TestSkyMask(t *testing.T) {
	const w, h = 200, 150
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := color.RGBA{uint8(110 + y*50/h), uint8(196 + y*25/h), 250, 255} // sky
			switch {
			case y >= 100:
				c = color.RGBA{120, 170, 60, 255} // ground
			case x >= 40 && x < 60 && y >= 30:
				c = color.RGBA{60, 120, 50, 255} // a tree up from the ground
			case (x-140)*(x-140)+(y-30)*(y-30)*4 < 300:
				c = color.RGBA{250, 252, 255, 255} // a cloud
			}
			img.SetRGBA(x, y, c)
		}
	}
	mask := SkyMask(img, w)
	alpha := func(x, y int) uint8 { return mask.NRGBAAt(x, y).A }
	if a := alpha(100, 10); a != 255 {
		t.Errorf("open sky: alpha %d, want 255", a)
	}
	if a := alpha(140, 30); a != 255 {
		t.Errorf("the cloud is sky: alpha %d, want 255", a)
	}
	if a := alpha(50, 40); a != 0 {
		t.Errorf("the tree is not sky: alpha %d, want 0", a)
	}
	if a := alpha(100, 120); a != 0 {
		t.Errorf("the ground is not sky: alpha %d, want 0", a)
	}

	night := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := color.RGBA{21, 24, 27, 255} // space
			switch {
			case y >= 100:
				c = color.RGBA{150, 150, 150, 255} // the ridge
			case (x-100)*(x-100)+(y-90)*(y-90) < 900:
				c = color.RGBA{17, 33, 62, 255} // the planet's night side, on the ridge
			}
			night.SetRGBA(x, y, c)
		}
	}
	mask = SkyMask(night, w)
	if a := mask.NRGBAAt(20, 20).A; a != 255 {
		t.Errorf("space: alpha %d, want 255", a)
	}
	if a := mask.NRGBAAt(100, 80).A; a != 0 {
		t.Errorf("a planet's night side is not sky: alpha %d, want 0", a)
	}
}
