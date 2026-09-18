// Package stickerimg post-processes generated art into what the pack format
// expects: stickers trimmed to their alpha, given a baked-in white border,
// padded and resized to a fixed square; backgrounds placed on a wider
// canvas with a mask for outpainting. Standard library only.
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
}

// Sticker trims the alpha bounding box, adds a white outline, and fits the
// result into a Size×Size square with a margin. Returns an error if the
// image is fully transparent.
func Sticker(src *image.RGBA, o StickerOptions) (*image.RGBA, error) {
	if o.Size <= 0 {
		o.Size = 1024
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
	outlined := Outline(scaled, radius, color.RGBA{255, 255, 255, 255})

	out := image.NewRGBA(image.Rect(0, 0, o.Size, o.Size))
	off := image.Pt((o.Size-outlined.Bounds().Dx())/2, (o.Size-outlined.Bounds().Dy())/2)
	draw.Draw(out, outlined.Bounds().Add(off), outlined, image.Point{}, draw.Over)
	return out, nil
}

// Clean zeroes colour under fully transparent pixels and clamps faint alpha
// (generation noise) to zero so the outline follows the real silhouette.
func Clean(src *image.RGBA, threshold uint8) *image.RGBA {
	out := image.NewRGBA(src.Bounds())
	copy(out.Pix, src.Pix)
	for i := 3; i < len(out.Pix); i += 4 {
		if out.Pix[i] <= threshold {
			out.Pix[i-3], out.Pix[i-2], out.Pix[i-1], out.Pix[i] = 0, 0, 0, 0
		}
	}
	return out
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
// original composited on top.
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
			for _, d := range disc {
				ox, oy := x-b.Min.X+radius+d[0], y-b.Min.Y+radius+d[1]
				i := out.PixOffset(ox, oy)
				if out.Pix[i+3] < a {
					out.Pix[i], out.Pix[i+1], out.Pix[i+2], out.Pix[i+3] = c.R, c.G, c.B, a
				}
			}
		}
	}
	draw.Draw(out, b.Add(image.Pt(radius-b.Min.X, radius-b.Min.Y)), src, b.Min, draw.Over)
	return out
}

// Resize scales with bilinear sampling (box-averaged when shrinking a lot
// would be nicer, but generated art is smooth enough for bilinear).
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
				a := float64(src.Pix[i+3]) / 255
				// premultiply so transparent neighbours do not bleed colour
				acc[0] += float64(src.Pix[i]) * a * s.wgt
				acc[1] += float64(src.Pix[i+1]) * a * s.wgt
				acc[2] += float64(src.Pix[i+2]) * a * s.wgt
				acc[3] += a * s.wgt
			}
			o := out.PixOffset(x, y)
			if acc[3] > 0 {
				out.Pix[o] = uint8(clampF(acc[0]/acc[3], 0, 255) + 0.5)
				out.Pix[o+1] = uint8(clampF(acc[1]/acc[3], 0, 255) + 0.5)
				out.Pix[o+2] = uint8(clampF(acc[2]/acc[3], 0, 255) + 0.5)
				out.Pix[o+3] = uint8(clampF(acc[3]*255, 0, 255) + 0.5)
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
