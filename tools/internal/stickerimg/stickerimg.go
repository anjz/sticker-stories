// Package stickerimg post-processes generated art into what the pack format
// expects: stickers trimmed to their alpha, given a baked-in die-cut border
// with a printed-vinyl finish, padded and resized to a fixed square;
// backgrounds placed on a wider canvas with a mask for outpainting.
// Standard library only.
package stickerimg

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"math"
)

// Decode reads a PNG into RGBA.
func Decode(data []byte) (*image.RGBA, error) {
	img, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	rgba := image.NewRGBA(img.Bounds())
	draw.Draw(rgba, rgba.Bounds(), img, img.Bounds().Min, draw.Src)
	return rgba, nil
}

// Encode writes an image as PNG.
func Encode(img image.Image) ([]byte, error) {
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// StickerOptions controls Sticker.
type StickerOptions struct {
	Size      int     // output square size in px (e.g. 1024)
	Border    float64 // white border width as a fraction of Size (e.g. 0.02)
	Margin    float64 // empty margin around the bordered sticker, fraction of Size
	Threshold uint8   // alpha at or below this counts as transparent
	// Finish is the printed-sticker material; nil means DefaultFinish and
	// a zero Finish is flat white with no shading.
	Finish *Finish
}

// Finish makes the bordered art read as a real die-cut vinyl sticker: a
// paper-white border whose outer rim darkens like the cut edge of the
// vinyl, and a soft gloss over the whole sticker (a diagonal highlight
// from the upper left plus a top-lit gradient). The art stays what it is;
// only the material changes. Everything is a fraction; 0 disables a part.
type Finish struct {
	// RimShade is how dark the very edge of the border gets (0 flat, 1
	// black); it fades to nothing over RimWidth × the border radius.
	RimShade float64 `json:"rimShade"`
	RimWidth float64 `json:"rimWidth"`
	// Gloss is the strength of the highlight band (blend toward white at
	// its peak); GlossWidth its softness across the sticker (0…1).
	Gloss      float64 `json:"gloss"`
	GlossWidth float64 `json:"glossWidth"`
	// Lighting brightens the top and darkens the bottom by this much.
	Lighting float64 `json:"lighting"`
}

// DefaultFinish is a glossy die-cut vinyl sticker under soft light.
var DefaultFinish = Finish{RimShade: 0.22, RimWidth: 0.4, Gloss: 0.11, GlossWidth: 0.16, Lighting: 0.035}

// stickerWhite is the border colour: paper-white, a touch warm, so the
// border reads as printed vinyl rather than a flat digital fill.
var stickerWhite = color.RGBA{250, 250, 247, 255}

// Sticker trims the alpha bounding box, adds a white outline with the
// printed finish, and fits the result into a Size×Size square with a
// margin. Returns an error if the image is fully transparent.
func Sticker(src *image.RGBA, o StickerOptions) (*image.RGBA, error) {
	if o.Size <= 0 {
		o.Size = 1024
	}
	finish := DefaultFinish
	if o.Finish != nil {
		finish = *o.Finish
	}
	cleaned := Clean(src, o.Threshold)
	box := Bounds(cleaned, o.Threshold)
	if box.Empty() {
		return nil, fmt.Errorf("image is fully transparent")
	}
	crop := image.NewRGBA(image.Rect(0, 0, box.Dx(), box.Dy()))
	draw.Draw(crop, crop.Bounds(), cleaned, box.Min, draw.Src)

	// Work at a scale where the content fits the inner square, then outline.
	inner := float64(o.Size) * (1 - 2*o.Margin - 2*o.Border)
	scale := math.Min(inner/float64(crop.Rect.Dx()), inner/float64(crop.Rect.Dy()))
	w, h := int(float64(crop.Rect.Dx())*scale+0.5), int(float64(crop.Rect.Dy())*scale+0.5)
	scaled := Resize(crop, w, h)
	radius := int(math.Round(o.Border * float64(o.Size)))
	outlined := Outline(scaled, radius, stickerWhite)

	out := image.NewRGBA(image.Rect(0, 0, o.Size, o.Size))
	off := image.Pt((o.Size-outlined.Bounds().Dx())/2, (o.Size-outlined.Bounds().Dy())/2)
	draw.Draw(out, outlined.Bounds().Add(off), outlined, image.Point{}, draw.Over)
	ApplyFinish(out, finish, radius)
	return out, nil
}

// ApplyFinish shades a bordered sticker in place (see Finish). radius is
// the border width in pixels, which sets the rim's reach.
func ApplyFinish(img *image.RGBA, f Finish, radius int) {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w == 0 || h == 0 {
		return
	}
	rim := f.RimWidth * float64(radius)
	var dist []float64
	if f.RimShade > 0 && rim > 0 {
		dist = edgeDistance(img)
	}
	for y := 0; y < h; y++ {
		v := (float64(y) + 0.5) / float64(h)
		for x := 0; x < w; x++ {
			i := img.PixOffset(x+b.Min.X, y+b.Min.Y)
			a := float64(img.Pix[i+3])
			if a == 0 {
				continue
			}
			u := (float64(x) + 0.5) / float64(w)
			// Multiplicative shading: the cut edge and the top-to-bottom light.
			gain := 1 + f.Lighting*(1-2*v)
			if dist != nil {
				if d := dist[y*w+x]; d < rim {
					t := 1 - d/rim
					gain *= 1 - f.RimShade*t*t
				}
			}
			// Additive gloss: blend toward white along a soft diagonal band
			// centred in the upper left. Colour is premultiplied, so white
			// at this pixel is its own alpha.
			k := 0.0
			if f.Gloss > 0 && f.GlossWidth > 0 {
				p := 0.55*u + 0.45*v - 0.42
				k = f.Gloss * math.Exp(-p*p/(2*f.GlossWidth*f.GlossWidth))
			}
			for c := 0; c < 3; c++ {
				value := float64(img.Pix[i+c])*gain*(1-k) + a*k
				img.Pix[i+c] = uint8(clampF(value, 0, a) + 0.5)
			}
		}
	}
}

// edgeDistance returns, per pixel, the distance in pixels to the nearest
// transparent pixel (alpha < 128), as a 3-4 chamfer transform: two passes,
// close enough to Euclidean for shading.
func edgeDistance(img *image.RGBA) []float64 {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	const inf = 1 << 20
	d := make([]int, w*h)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if img.Pix[img.PixOffset(x+b.Min.X, y+b.Min.Y)+3] >= 128 {
				d[y*w+x] = inf
			}
		}
	}
	at := func(x, y int) int {
		if x < 0 || y < 0 || x >= w || y >= h {
			return 0 // outside the image counts as transparent
		}
		return d[y*w+x]
	}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			v := d[y*w+x]
			v = min(v, at(x-1, y)+3, at(x, y-1)+3, at(x-1, y-1)+4, at(x+1, y-1)+4)
			d[y*w+x] = v
		}
	}
	for y := h - 1; y >= 0; y-- {
		for x := w - 1; x >= 0; x-- {
			v := d[y*w+x]
			v = min(v, at(x+1, y)+3, at(x, y+1)+3, at(x+1, y+1)+4, at(x-1, y+1)+4)
			d[y*w+x] = v
		}
	}
	out := make([]float64, w*h)
	for i, v := range d {
		out[i] = float64(v) / 3
	}
	return out
}

// Generated art is never quite opaque: alpha at or above this is treated as
// solid, because a printed sticker is.
const solidAlpha = 232

// Clean makes the generated art a clean cut-out: faint alpha (generation
// noise, at or below threshold) becomes fully transparent so the outline
// follows the real silhouette; near-opaque alpha becomes solid; and the
// remaining anti-aliased edge pixels borrow the colour of their most
// opaque neighbour, so the model's background tint does not fringe the
// art where it meets the border.
func Clean(src *image.RGBA, threshold uint8) *image.RGBA {
	out := image.NewRGBA(src.Bounds())
	copy(out.Pix, src.Pix)
	for i := 3; i < len(out.Pix); i += 4 {
		switch a := out.Pix[i]; {
		case a <= threshold:
			out.Pix[i-3], out.Pix[i-2], out.Pix[i-1], out.Pix[i] = 0, 0, 0, 0
		case a >= solidAlpha && a < 255:
			for c := i - 3; c < i; c++ {
				out.Pix[c] = uint8(clampF(float64(out.Pix[c])*255/float64(a), 0, 255) + 0.5)
			}
			out.Pix[i] = 255
		}
	}
	defringe(out, src.Bounds())
	return out
}

// defringe recolours every partially transparent pixel from the most opaque
// pixel within two pixels of it (keeping its own alpha), in one pass over
// a snapshot so results do not chain.
func defringe(img *image.RGBA, b image.Rectangle) {
	ref := make([]uint8, len(img.Pix))
	copy(ref, img.Pix)
	for y := b.Min.Y; y < b.Max.Y; y++ {
		for x := b.Min.X; x < b.Max.X; x++ {
			i := img.PixOffset(x, y)
			a := ref[i+3]
			if a == 0 || a == 255 {
				continue
			}
			best, bestA := -1, a
			for dy := -2; dy <= 2; dy++ {
				for dx := -2; dx <= 2; dx++ {
					nx, ny := x+dx, y+dy
					if nx < b.Min.X || ny < b.Min.Y || nx >= b.Max.X || ny >= b.Max.Y {
						continue
					}
					j := img.PixOffset(nx, ny)
					if ref[j+3] > bestA {
						best, bestA = j, ref[j+3]
					}
				}
			}
			if best < 0 {
				continue
			}
			// Premultiplied: scale the neighbour's colour to this pixel's alpha.
			for c := 0; c < 3; c++ {
				img.Pix[i+c] = uint8(float64(ref[best+c])*float64(a)/float64(bestA) + 0.5)
			}
		}
	}
}

// Bounds returns the bounding box of pixels with alpha above threshold.
func Bounds(img *image.RGBA, threshold uint8) image.Rectangle {
	b := img.Bounds()
	minX, minY, maxX, maxY := b.Max.X, b.Max.Y, b.Min.X-1, b.Min.Y-1
	for y := b.Min.Y; y < b.Max.Y; y++ {
		for x := b.Min.X; x < b.Max.X; x++ {
			if img.Pix[img.PixOffset(x, y)+3] > threshold {
				if x < minX {
					minX = x
				}
				if x > maxX {
					maxX = x
				}
				if y < minY {
					minY = y
				}
				if y > maxY {
					maxY = y
				}
			}
		}
	}
	if maxX < minX {
		return image.Rectangle{}
	}
	return image.Rect(minX, minY, maxX+1, maxY+1)
}

// Outline adds a solid border of the given radius around every opaque pixel
// (a disc dilation of the alpha), returning a larger image with the
// original composited on top. The border pixels are written premultiplied
// (colour scaled by their alpha), as image.RGBA requires — a colour above
// its alpha wraps to black when encoded.
func Outline(src *image.RGBA, radius int, c color.RGBA) *image.RGBA {
	if radius <= 0 {
		return src
	}
	b := src.Bounds()
	w, h := b.Dx()+2*radius, b.Dy()+2*radius
	out := image.NewRGBA(image.Rect(0, 0, w, h))
	// Distance-limited dilation: for each source pixel with alpha, stamp a disc.
	// Use the alpha as coverage so anti-aliased edges give a soft outline.
	disc := make([][2]int, 0, (2*radius+1)*(2*radius+1))
	for dy := -radius; dy <= radius; dy++ {
		for dx := -radius; dx <= radius; dx++ {
			if dx*dx+dy*dy <= radius*radius {
				disc = append(disc, [2]int{dx, dy})
			}
		}
	}
	for y := b.Min.Y; y < b.Max.Y; y++ {
		for x := b.Min.X; x < b.Max.X; x++ {
			a := src.Pix[src.PixOffset(x, y)+3]
			if a == 0 {
				continue
			}
			pr, pg, pb := uint8(int(c.R)*int(a)/255), uint8(int(c.G)*int(a)/255), uint8(int(c.B)*int(a)/255)
			for _, d := range disc {
				ox, oy := x-b.Min.X+radius+d[0], y-b.Min.Y+radius+d[1]
				i := out.PixOffset(ox, oy)
				if out.Pix[i+3] < a {
					out.Pix[i], out.Pix[i+1], out.Pix[i+2], out.Pix[i+3] = pr, pg, pb, a
				}
			}
		}
	}
	draw.Draw(out, b.Add(image.Pt(radius-b.Min.X, radius-b.Min.Y)), src, b.Min, draw.Over)
	return out
}

// Resize scales with bilinear sampling (box-averaged when shrinking a lot
// would be nicer, but generated art is smooth enough for bilinear).
// image.RGBA is premultiplied, so the four channels interpolate as they
// are: transparent neighbours contribute nothing and the result stays
// valid (colour never above alpha).
func Resize(src *image.RGBA, w, h int) *image.RGBA {
	b := src.Bounds()
	out := image.NewRGBA(image.Rect(0, 0, w, h))
	if w <= 0 || h <= 0 || b.Empty() {
		return out
	}
	sx := float64(b.Dx()) / float64(w)
	sy := float64(b.Dy()) / float64(h)
	for y := 0; y < h; y++ {
		fy := (float64(y)+0.5)*sy - 0.5
		y0 := int(math.Floor(fy))
		ty := fy - float64(y0)
		for x := 0; x < w; x++ {
			fx := (float64(x)+0.5)*sx - 0.5
			x0 := int(math.Floor(fx))
			tx := fx - float64(x0)
			var acc [4]float64
			for _, s := range [4]struct {
				dx, dy int
				wgt    float64
			}{{0, 0, (1 - tx) * (1 - ty)}, {1, 0, tx * (1 - ty)}, {0, 1, (1 - tx) * ty}, {1, 1, tx * ty}} {
				px := clampInt(x0+s.dx, b.Min.X, b.Max.X-1)
				py := clampInt(y0+s.dy, b.Min.Y, b.Max.Y-1)
				i := src.PixOffset(px, py)
				for c := 0; c < 4; c++ {
					acc[c] += float64(src.Pix[i+c]) * s.wgt
				}
			}
			o := out.PixOffset(x, y)
			a := clampF(acc[3], 0, 255)
			out.Pix[o+3] = uint8(a + 0.5)
			for c := 0; c < 3; c++ {
				out.Pix[o+c] = uint8(clampF(acc[c], 0, float64(out.Pix[o+3])) + 0.5)
			}
		}
	}
	return out
}

// Flatten composites an image over a solid colour (RGB output for opaque art).
func Flatten(src image.Image, bg color.Color) *image.RGBA {
	out := image.NewRGBA(src.Bounds())
	draw.Draw(out, out.Bounds(), image.NewUniform(bg), image.Point{}, draw.Src)
	draw.Draw(out, out.Bounds(), src, src.Bounds().Min, draw.Over)
	return out
}

// WideCanvas places base centred on a canvas of the given width and the
// base's height, and returns it with a mask whose centre is opaque (keep)
// and whose side bands are transparent (paint). The API paints the
// transparent parts of the mask.
func WideCanvas(base *image.RGBA, width int) (canvas, mask *image.RGBA, err error) {
	b := base.Bounds()
	if width <= b.Dx() {
		return nil, nil, fmt.Errorf("wide width %d must exceed base width %d", width, b.Dx())
	}
	off := (width - b.Dx()) / 2
	canvas = image.NewRGBA(image.Rect(0, 0, width, b.Dy()))
	draw.Draw(canvas, image.Rect(off, 0, off+b.Dx(), b.Dy()), base, b.Min, draw.Src)
	mask = image.NewRGBA(canvas.Bounds())
	draw.Draw(mask, image.Rect(off, 0, off+b.Dx(), b.Dy()), image.NewUniform(color.RGBA{0, 0, 0, 255}), image.Point{}, draw.Src)
	return canvas, mask, nil
}

// Centre returns the centred crop of the given width from a wider image
// (used to re-derive a base that matches the wide rendition exactly).
func Centre(src *image.RGBA, width int) *image.RGBA {
	b := src.Bounds()
	off := (b.Dx() - width) / 2
	out := image.NewRGBA(image.Rect(0, 0, width, b.Dy()))
	draw.Draw(out, out.Bounds(), src, image.Pt(b.Min.X+off, b.Min.Y), draw.Src)
	return out
}

func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func clampF(v, lo, hi float64) float64 { return math.Max(lo, math.Min(hi, v)) }
