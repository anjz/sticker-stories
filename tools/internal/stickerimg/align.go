package stickerimg

import (
	"image"
	"math"
)

// Placement maps an image onto a reference: the pixel at (x, y) of the
// image lands at (S·x + Tx, S·y + Ty) in the reference.
type Placement struct {
	S, Tx, Ty float64
}

// Warp draws img placed by p on a w×h canvas (bilinear, premultiplied).
func Warp(img *image.RGBA, p Placement, w, h int) *image.RGBA {
	out := image.NewRGBA(image.Rect(0, 0, w, h))
	b := img.Bounds()
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			fx := (float64(x)+0.5-p.Tx)/p.S - 0.5
			fy := (float64(y)+0.5-p.Ty)/p.S - 0.5
			x0, y0 := int(math.Floor(fx)), int(math.Floor(fy))
			tx, ty := fx-float64(x0), fy-float64(y0)
			var acc [4]float64
			for _, s := range [4]struct {
				dx, dy int
				wgt    float64
			}{{0, 0, (1 - tx) * (1 - ty)}, {1, 0, tx * (1 - ty)}, {0, 1, (1 - tx) * ty}, {1, 1, tx * ty}} {
				px, py := x0+s.dx+b.Min.X, y0+s.dy+b.Min.Y
				if px < b.Min.X || py < b.Min.Y || px >= b.Max.X || py >= b.Max.Y {
					continue
				}
				i := img.PixOffset(px, py)
				for c := 0; c < 4; c++ {
					acc[c] += float64(img.Pix[i+c]) * s.wgt
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

// AlignOptions bounds Align's search.
type AlignOptions struct {
	// MinScale and MaxScale bound the scale (both 1: translation only).
	MinScale, MaxScale float64
	// MaxShift bounds the translation, as a fraction of the reference's
	// larger side.
	MaxShift float64
	// Region, when set, says which reference pixels count (x, y in the
	// reference's own coordinates); nil counts every pixel.
	Region func(x, y int) bool
	// Start is where the search centres (zero value: S 1, no shift).
	Start Placement
}

// Align finds where img best sits over ref — the placement that makes the
// two most alike (premultiplied RGBA, absolute difference) over the
// region — coarse to fine. Used to put an edit the model redrew at its
// own scale back over the original (a prop removal) and to register
// animation frames whose base moves (a walk cycle) on the one before.
func Align(ref, img *image.RGBA, o AlignOptions) Placement {
	if o.MinScale <= 0 {
		o.MinScale = 1
	}
	if o.MaxScale < o.MinScale {
		o.MaxScale = o.MinScale
	}
	if o.MaxShift <= 0 {
		o.MaxShift = 0.1
	}
	best := o.Start
	if best.S == 0 {
		best.S = 1
	}
	rb := ref.Bounds()
	side := float64(max(rb.Dx(), rb.Dy()))
	type level struct {
		size              float64 // working size of the reference's larger side
		scaleStep, scaleR float64 // step and ± range around the best scale
		shiftR            int     // ± range, in working pixels
		full              bool    // search the whole scale range
	}
	levels := []level{
		{size: 64, scaleStep: 0.02, full: true, shiftR: int(math.Ceil(o.MaxShift * 64))},
		{size: 256, scaleStep: 0.005, scaleR: 0.02, shiftR: 5},
		{size: side, scaleStep: 0.002, scaleR: 0.004, shiftR: 3},
	}
	for _, lv := range levels {
		f := math.Min(lv.size/side, 1) // working px per reference px
		rw, rh := max(1, int(math.Round(float64(rb.Dx())*f))), max(1, int(math.Round(float64(rb.Dy())*f)))
		r := Resize(ref, rw, rh)
		ib := img.Bounds()
		// The image at the same working scale (its pixels share the reference's
		// size when S is 1).
		iw, ih := max(1, int(math.Round(float64(ib.Dx())*f))), max(1, int(math.Round(float64(ib.Dy())*f)))
		im := Resize(img, iw, ih)
		var pts []int
		for y := 0; y < rh; y++ {
			for x := 0; x < rw; x++ {
				if o.Region == nil || o.Region(int(float64(x)/f), int(float64(y)/f)) {
					pts = append(pts, y*rw+x)
				}
			}
		}
		if len(pts) == 0 {
			return best
		}
		cost := func(p Placement) float64 {
			// p in working pixels.
			total := 0.0
			for _, i := range pts {
				x, y := i%rw, i/rw
				sx := int(math.Round((float64(x)+0.5-p.Tx)/p.S - 0.5))
				sy := int(math.Round((float64(y)+0.5-p.Ty)/p.S - 0.5))
				ro := r.PixOffset(x, y)
				if sx < 0 || sy < 0 || sx >= iw || sy >= ih {
					total += float64(r.Pix[ro+3]) * 2
					continue
				}
				io := im.PixOffset(sx, sy)
				for c := 0; c < 4; c++ {
					d := int(r.Pix[ro+c]) - int(im.Pix[io+c])
					if d < 0 {
						d = -d
					}
					total += float64(d)
				}
			}
			return total
		}
		lo, hi := best.S-lv.scaleR, best.S+lv.scaleR
		if lv.full {
			lo, hi = o.MinScale, o.MaxScale
		}
		lo, hi = math.Max(lo, o.MinScale), math.Min(hi, o.MaxScale)
		cx, cy := best.Tx*f, best.Ty*f
		bestCost := math.Inf(1)
		next := best
		for s := lo; s <= hi+1e-9; s += lv.scaleStep {
			// Scaling about the image's centre keeps the shift search centred
			// on the same spot whatever the scale.
			ox := float64(iw) / 2 * (best.S - s)
			oy := float64(ih) / 2 * (best.S - s)
			for dy := -lv.shiftR; dy <= lv.shiftR; dy++ {
				for dx := -lv.shiftR; dx <= lv.shiftR; dx++ {
					p := Placement{S: s, Tx: cx + ox + float64(dx), Ty: cy + oy + float64(dy)}
					if c := cost(p); c < bestCost {
						bestCost, next = c, Placement{S: s, Tx: p.Tx / f, Ty: p.Ty / f}
					}
				}
			}
			if lo == hi {
				break
			}
		}
		best = next
	}
	return best
}
