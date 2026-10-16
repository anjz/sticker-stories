package stickerimg

import (
	"image"
	"image/color"
	"math"
)

// Sky masks: which part of a scene's background is open sky
// (docs/pack-format.md, "Sky"), so the app keeps sky effects — the moon,
// stars, clouds — off the treetops, ridges and buildings painted into it.
//
// The sky is found by colour, from the top edge down: a flood fill that
// starts on the top row and spreads to each neighbour whose colour is
// close to the pixel it comes from (a painted edge is a jump in colour,
// the sky's gradient never is) and still looks like this sky (close to
// the colour along the top edge, or a pale cloud). Whatever the fill
// closed round without touching the bottom edge — a cloud, a star, a
// bird — is sky too: everything standing on the ground (trees, a ridge,
// a planet rising behind the ridge, a lighthouse) reaches the bottom
// through what it stands on. The edge is then pulled a pixel into the
// sky and softened, so an effect fades out just before the scenery.
const (
	// skyStep is the largest colour step (Euclidean, 0–255 RGB, on the
	// lightly blurred mask-sized image) the fill crosses between
	// neighbours.
	skyStep = 18
	// A pixel is still sky this far from the top edge's colour, plus
	// skyPale of that colour's own brightness: a blue sky pales a long
	// way towards the horizon, a black one stays black (and the night
	// side of a planet against it is not sky).
	skyReach = 18
	skyPale  = 0.24
	// skySoft is the blur radius, in mask pixels, of the soft edge.
	skySoft = 2
)

// SkyMask returns the open sky of an opaque background as a mask `width`
// pixels wide (the height in proportion): white, its alpha the sky — 255
// in open sky, 0 on the scenery, soft in between.
func SkyMask(bg *image.RGBA, width int) *image.NRGBA {
	b := bg.Bounds()
	if width <= 0 || b.Dx() == 0 {
		return image.NewNRGBA(image.Rect(0, 0, 0, 0))
	}
	height := int(math.Round(float64(width) * float64(b.Dy()) / float64(b.Dx())))
	w, h := width, height
	small := boxBlurRGB(Resize(bg, w, h), w, h)
	at := func(x, y int) [3]float64 { return small[y*w+x] }

	// The sky's own colour, along the top edge.
	var ref [3]float64
	band := max(2, h/100)
	for y := 0; y < band; y++ {
		for x := 0; x < w; x++ {
			c := at(x, y)
			for i := range ref {
				ref[i] += c[i]
			}
		}
	}
	for i := range ref {
		ref[i] /= float64(band * w)
	}
	reach := skyReach + skyPale*dist(ref, [3]float64{})
	looksLikeSky := func(c [3]float64) bool {
		if dist(c, ref) < reach {
			return true
		}
		// A pale, unsaturated cloud.
		lo := math.Min(c[0], math.Min(c[1], c[2]))
		hi := math.Max(c[0], math.Max(c[1], c[2]))
		return lo >= 190 && hi-lo <= 70
	}

	sky := make([]bool, w*h)
	queue := make([]int, 0, w*h/4)
	for x := 0; x < w; x++ {
		if looksLikeSky(at(x, 0)) {
			sky[x] = true
			queue = append(queue, x)
		}
	}
	for len(queue) > 0 {
		p := queue[len(queue)-1]
		queue = queue[:len(queue)-1]
		px, py := p%w, p/w
		c := at(px, py)
		for _, d := range [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}} {
			nx, ny := px+d[0], py+d[1]
			if nx < 0 || ny < 0 || nx >= w || ny >= h {
				continue
			}
			n := ny*w + nx
			if sky[n] {
				continue
			}
			nc := at(nx, ny)
			if dist(c, nc) < skyStep && looksLikeSky(nc) {
				sky[n] = true
				queue = append(queue, n)
			}
		}
	}
	fillEnclosed(sky, w, h)

	// Pulled a pixel into the sky, then softened.
	alpha := make([]float64, w*h)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if !sky[y*w+x] {
				continue
			}
			inside := true
			for _, d := range [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}} {
				nx, ny := x+d[0], y+d[1]
				if nx >= 0 && ny >= 0 && nx < w && ny < h && !sky[ny*w+nx] {
					inside = false
				}
			}
			if inside {
				alpha[y*w+x] = 1
			}
		}
	}
	alpha = boxBlur(boxBlur(alpha, w, h, skySoft), w, h, skySoft)

	out := image.NewNRGBA(image.Rect(0, 0, w, h))
	for i, a := range alpha {
		o := i * 4
		out.Pix[o], out.Pix[o+1], out.Pix[o+2] = 255, 255, 255
		out.Pix[o+3] = uint8(clampF(a*255, 0, 255) + 0.5)
	}
	return out
}

// fillEnclosed turns into sky every part of the scenery that does not
// reach the bottom edge: what the sky closes round (clouds, stars).
func fillEnclosed(sky []bool, w, h int) {
	seen := make([]bool, w*h)
	var component, queue []int
	for start := range sky {
		if sky[start] || seen[start] {
			continue
		}
		component, queue = component[:0], append(queue[:0], start)
		seen[start] = true
		grounded := false
		for len(queue) > 0 {
			p := queue[len(queue)-1]
			queue = queue[:len(queue)-1]
			component = append(component, p)
			px, py := p%w, p/w
			if py == h-1 {
				grounded = true
			}
			for _, d := range [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}} {
				nx, ny := px+d[0], py+d[1]
				if nx < 0 || ny < 0 || nx >= w || ny >= h {
					continue
				}
				n := ny*w + nx
				if !sky[n] && !seen[n] {
					seen[n] = true
					queue = append(queue, n)
				}
			}
		}
		if !grounded {
			for _, p := range component {
				sky[p] = true
			}
		}
	}
}

// SkyPreview tints the sky of a background so a mask can be checked by
// eye: magenta where the mask says sky, the art untouched elsewhere.
func SkyPreview(bg *image.RGBA, mask *image.NRGBA) *image.RGBA {
	b := bg.Bounds()
	scaled := Resize(nrgbaToRGBA(mask), b.Dx(), b.Dy())
	out := image.NewRGBA(b)
	for y := 0; y < b.Dy(); y++ {
		for x := 0; x < b.Dx(); x++ {
			a := float64(scaled.Pix[scaled.PixOffset(x, y)+3]) / 255 * 0.65
			c := bg.RGBAAt(b.Min.X+x, b.Min.Y+y)
			tint := [3]float64{255, 0, 200}
			mix := func(v uint8, t float64) uint8 { return uint8(float64(v)*(1-a) + t*a + 0.5) }
			out.SetRGBA(x, y, color.RGBA{mix(c.R, tint[0]), mix(c.G, tint[1]), mix(c.B, tint[2]), 255})
		}
	}
	return out
}

func nrgbaToRGBA(src *image.NRGBA) *image.RGBA {
	out := image.NewRGBA(src.Bounds())
	for i := 0; i < len(src.Pix); i += 4 {
		a := uint32(src.Pix[i+3])
		out.Pix[i] = uint8(uint32(src.Pix[i]) * a / 255)
		out.Pix[i+1] = uint8(uint32(src.Pix[i+1]) * a / 255)
		out.Pix[i+2] = uint8(uint32(src.Pix[i+2]) * a / 255)
		out.Pix[i+3] = uint8(a)
	}
	return out
}

func dist(a, b [3]float64) float64 {
	dr, dg, db := a[0]-b[0], a[1]-b[1], a[2]-b[2]
	return math.Sqrt(dr*dr + dg*dg + db*db)
}

// boxBlurRGB returns an opaque image's colours, each the mean of its 3×3
// neighbourhood (the paper's grain smoothed away).
func boxBlurRGB(img *image.RGBA, w, h int) [][3]float64 {
	var ch [3][]float64
	for c := range ch {
		ch[c] = make([]float64, w*h)
		for i := range ch[c] {
			ch[c][i] = float64(img.Pix[i*4+c])
		}
		ch[c] = boxBlur(ch[c], w, h, 1)
	}
	out := make([][3]float64, w*h)
	for i := range out {
		out[i] = [3]float64{ch[0][i], ch[1][i], ch[2][i]}
	}
	return out
}

// boxBlur averages each value with its neighbours up to r away (the
// edges clamped), horizontally then vertically.
func boxBlur(v []float64, w, h, r int) []float64 {
	tmp := make([]float64, w*h)
	out := make([]float64, w*h)
	n := float64(2*r + 1)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			var s float64
			for k := -r; k <= r; k++ {
				s += v[y*w+clampInt(x+k, 0, w-1)]
			}
			tmp[y*w+x] = s / n
		}
	}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			var s float64
			for k := -r; k <= r; k++ {
				s += tmp[clampInt(y+k, 0, h-1)*w+x]
			}
			out[y*w+x] = s / n
		}
	}
	return out
}
