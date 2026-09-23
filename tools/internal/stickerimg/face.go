package stickerimg

import (
	"image"
	"image/color"
	"math"
)

// FaceBox is the face of a sticker's raw art as fractions of the image
// (top-left origin): the only part an expression variant may change.
type FaceBox struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"width"`
	Height float64 `json:"height"`
}

// faceWeight is how much of the new face shows at (x, y): 1 inside the
// ellipse inscribed in the box grown by grow, falling smoothly to 0 across
// the outer feather (both fractions of the box's size).
func (f FaceBox) faceWeight(x, y float64, w, h int, grow, feather float64) float64 {
	cx, cy := (f.X+f.Width/2)*float64(w), (f.Y+f.Height/2)*float64(h)
	rx, ry := f.Width/2*float64(w)*(1+grow), f.Height/2*float64(h)*(1+grow)
	if rx <= 0 || ry <= 0 {
		return 0
	}
	d := math.Hypot((x-cx)/rx, (y-cy)/ry) // 1 on the ellipse
	switch {
	case d <= 1-feather:
		return 1
	case d >= 1:
		return 0
	}
	t := (1 - d) / feather
	return t * t * (3 - 2*t)
}

// FaceMask is the edit mask for an expression: opaque everywhere except a
// transparent ellipse over the face (grown a little so the edit has room),
// which is what the API repaints.
func FaceMask(w, h int, f FaceBox) *image.RGBA {
	m := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			a := uint8(255)
			if f.faceWeight(float64(x)+0.5, float64(y)+0.5, w, h, 0.12, 0.001) > 0 {
				a = 0
			}
			m.SetRGBA(x, y, color.RGBA{0, 0, 0, a})
		}
	}
	return m
}

// Face puts the face of gen (the edited image) onto base (the sticker's
// raw art): only inside a feathered ellipse over the face box, and only
// the colour — the alpha stays base's, so the outline, and with it the
// finished sticker's size and placement, are exactly the sticker's. The
// variant can then replace the sticker's texture without moving it.
func Face(base, gen *image.RGBA, f FaceBox) *image.RGBA {
	b := base.Bounds()
	w, h := b.Dx(), b.Dy()
	if gb := gen.Bounds(); gb.Dx() != w || gb.Dy() != h {
		gen = Resize(gen, w, h)
	}
	out := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			o := base.RGBAAt(b.Min.X+x, b.Min.Y+y)
			k := f.faceWeight(float64(x)+0.5, float64(y)+0.5, w, h, 0.06, 0.3)
			if k > 0 && o.A > 0 {
				n := gen.RGBAAt(x, y)
				// Premultiplied; bring the new colour to the base's alpha.
				scale := func(c uint8, a uint8) float64 {
					if a == 0 {
						return 0
					}
					return float64(c) / float64(a)
				}
				// A transparent pixel in gen has no colour to give.
				k *= float64(n.A) / 255
				mix := func(oc, nc uint8) uint8 {
					v := (1-k)*scale(oc, o.A) + k*scale(nc, n.A)
					return uint8(math.Round(clampF(v, 0, 1) * float64(o.A)))
				}
				o = color.RGBA{mix(o.R, n.R), mix(o.G, n.G), mix(o.B, n.B), o.A}
			}
			out.SetRGBA(x, y, o)
		}
	}
	return out
}
