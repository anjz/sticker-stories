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
	// Edge overrides the band along the silhouette's edge the expression
	// never touches (fraction of the image's larger side; 0 = the default).
	// Thinner for a face that sits at the edge — the snail's eyes on stalks.
	Edge float64 `json:"edge,omitempty"`
}

// edgeKeep is the band along the silhouette the mask keeps the model off;
// the composite fades the new face in just inside it.
func (f FaceBox) edgeKeep() float64 {
	if f.Edge > 0 {
		return f.Edge
	}
	return faceMaskKeep
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

// The silhouette's edge band an expression never touches, as fractions of
// the image's larger side: the mask keeps the model off anything closer
// than faceMaskKeep to the transparent background, and the composite takes
// nothing of the new face closer than faceKeep, fading it in over
// faceKeepFade. So the head's outline is always the sticker's own — when
// the model turned the head or redrew its edge, compositing it inside the
// old outline left both showing.
const (
	faceMaskKeep = 0.03
	faceKeepFade = 0.008
	// The mask's ellipse is the face box grown by faceMaskGrow; the
	// composite takes the new face fully over the whole box and fades it out
	// only across that margin, which the model also repainted — a wider
	// fade left the old eyes half-showing next to the new ones.
	faceMaskGrow = 0.12
)

// FaceMask is the edit mask for an expression: opaque everywhere except a
// transparent ellipse over the face (grown a little so the edit has room),
// minus the band along the silhouette's edge — what the API repaints.
func FaceMask(base *image.RGBA, f FaceBox) *image.RGBA {
	b := base.Bounds()
	w, h := b.Dx(), b.Dy()
	dist := edgeDistance(base)
	keep := f.edgeKeep() * float64(max(w, h))
	m := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			a := uint8(255)
			if dist[y*w+x] >= keep && f.faceWeight(float64(x)+0.5, float64(y)+0.5, w, h, faceMaskGrow, 0.001) > 0 {
				a = 0
			}
			m.SetRGBA(x, y, color.RGBA{0, 0, 0, a})
		}
	}
	return m
}

// FaceSeam measures how much the edit changed the picture where the new
// face fades into the old (the feathered rim of the composite), as the
// mean colour difference 0–1. A high value means a feature crosses the rim
// and part of the old face shows through: look at that variant.
func FaceSeam(base, gen *image.RGBA, f FaceBox) float64 {
	b := base.Bounds()
	w, h := b.Dx(), b.Dy()
	if gb := gen.Bounds(); gb.Dx() != w || gb.Dy() != h {
		gen = Resize(gen, w, h)
	}
	weights := faceWeights(base, f)
	sum, n := 0.0, 0
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			k := weights[y*w+x]
			o := base.RGBAAt(b.Min.X+x, b.Min.Y+y)
			if k <= 0.1 || k >= 0.6 || o.A < 200 {
				continue
			}
			g := gen.RGBAAt(x, y)
			d := (math.Abs(float64(o.R)-float64(g.R)) + math.Abs(float64(o.G)-float64(g.G)) + math.Abs(float64(o.B)-float64(g.B))) / (3 * 255)
			sum += d
			n++
		}
	}
	if n == 0 {
		return 0
	}
	return sum / float64(n)
}

// faceWeights is how much of the new face shows at each pixel: the
// feathered face ellipse, faded out towards the silhouette's edge.
func faceWeights(base *image.RGBA, f FaceBox) []float64 {
	b := base.Bounds()
	w, h := b.Dx(), b.Dy()
	dist := edgeDistance(base)
	side := float64(max(w, h))
	keep, fade := f.edgeKeep()*side, faceKeepFade*side
	out := make([]float64, w*h)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			k := f.faceWeight(float64(x)+0.5, float64(y)+0.5, w, h, faceMaskGrow, faceMaskGrow/(1+faceMaskGrow))
			if k <= 0 {
				continue
			}
			t := clampF((dist[y*w+x]-keep)/fade, 0, 1)
			out[y*w+x] = k * t * t * (3 - 2*t)
		}
	}
	return out
}

// Face puts the face of gen (the edited image) onto base (the sticker's
// raw art): only inside a feathered ellipse over the face box and away from
// the silhouette's edge, and only the colour — the alpha stays base's, so the outline, and with it the
// finished sticker's size and placement, are exactly the sticker's. The
// variant can then replace the sticker's texture without moving it.
func Face(base, gen *image.RGBA, f FaceBox) *image.RGBA {
	b := base.Bounds()
	w, h := b.Dx(), b.Dy()
	if gb := gen.Bounds(); gb.Dx() != w || gb.Dy() != h {
		gen = Resize(gen, w, h)
	}
	weights := faceWeights(base, f)
	out := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			o := base.RGBAAt(b.Min.X+x, b.Min.Y+y)
			k := weights[y*w+x]
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
