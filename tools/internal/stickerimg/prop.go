package stickerimg

import (
	"image"
	"image/color"
)

// A prop is something a sticker's character was drawn on — a lily pad, a
// branch, a leaf — that the sticker should no longer carry: the scene has
// its own branches and pond, and a character that walks or flies in on
// its own reads better without it. The prop is removed by a masked edit
// over its area (PropMask), and only that area of the result is laid back
// over the raw art (RemoveProp), so the character outside it keeps its
// exact pixels.

// propMaskGrow is how far beyond the prop's box the edit may repaint, as a
// fraction of the image's larger side; the composite fades from the box's
// edge out across that margin, so the join sits in repainted pixels.
const propMaskGrow = 0.02

// propKeepFraction: after the composite, a separate blob of alpha smaller
// than this fraction of the largest one is a leftover of the prop (a leaf
// reaching out of the box) and is cleared.
const propKeepFraction = 0.05

// PropMask is the edit mask for removing a prop: opaque everywhere except
// the box (grown by propMaskGrow), which the API repaints.
func PropMask(base *image.RGBA, box FaceBox) *image.RGBA {
	b := base.Bounds()
	w, h := b.Dx(), b.Dy()
	m := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			a := uint8(255)
			if propWeight(box, float64(x)+0.5, float64(y)+0.5, w, h) > 0 {
				a = 0
			}
			m.SetRGBA(x, y, color.RGBA{A: a})
		}
	}
	return m
}

// propWeight is how much of the edit shows at (x, y): 1 inside the box,
// falling smoothly to 0 across the margin the mask adds around it.
func propWeight(box FaceBox, x, y float64, w, h int) float64 {
	grow := propMaskGrow * float64(max(w, h))
	x0, y0 := box.X*float64(w), box.Y*float64(h)
	x1, y1 := (box.X+box.Width)*float64(w), (box.Y+box.Height)*float64(h)
	dx := max(x0-x, x-x1, 0)
	dy := max(y0-y, y-y1, 0)
	d := max(dx, dy)
	switch {
	case d <= 0:
		return 1
	case d >= grow:
		return 0
	}
	t := 1 - d/grow
	return t * t * (3 - 2*t)
}

// RemoveProp lays the edited image's box area over the base (the raw art
// with the prop), fading across the mask's margin, then clears what is
// left of the prop outside the box: every blob of alpha much smaller than
// the character. The model tends to redraw the whole character a little
// bigger once the prop is gone (it fills the frame again), so the edit is
// first scaled and moved to match the base where the base was kept.
func RemoveProp(base, gen *image.RGBA, box FaceBox) *image.RGBA {
	b := base.Bounds()
	w, h := b.Dx(), b.Dy()
	g := gen
	if gb := gen.Bounds(); gb.Dx() != w || gb.Dy() != h {
		g = Resize(gen, w, h)
	}
	fit := Align(base, g, AlignOptions{
		MinScale: 0.75, MaxScale: 1.25, MaxShift: 0.2,
		Region: func(x, y int) bool { return propWeight(box, float64(x)+0.5, float64(y)+0.5, w, h) == 0 },
	})
	g = Warp(g, fit, w, h)
	out := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			k := propWeight(box, float64(x)+0.5, float64(y)+0.5, w, h)
			o := out.PixOffset(x, y)
			bo := base.PixOffset(x+b.Min.X, y+b.Min.Y)
			gbo := g.PixOffset(x+g.Rect.Min.X, y+g.Rect.Min.Y)
			for c := 0; c < 4; c++ {
				// Premultiplied, so a straight mix of the channels is right.
				out.Pix[o+c] = uint8(float64(base.Pix[bo+c])*(1-k) + float64(g.Pix[gbo+c])*k + 0.5)
			}
		}
	}
	KeepLargeBlobs(out, 8, propKeepFraction)
	return out
}

// KeepLargeBlobs clears every 8-connected blob of alpha (above threshold)
// smaller than keep × the largest blob, with the faint pixels around it.
func KeepLargeBlobs(img *image.RGBA, threshold uint8, keep float64) {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	label := make([]int32, w*h)
	opaque := func(i int) bool { return img.Pix[img.PixOffset(i%w+b.Min.X, i/w+b.Min.Y)+3] > threshold }
	var sizes []int
	var stack []int
	for start := 0; start < w*h; start++ {
		if label[start] != 0 || !opaque(start) {
			continue
		}
		id := int32(len(sizes) + 1)
		size := 0
		stack = append(stack[:0], start)
		label[start] = id
		for len(stack) > 0 {
			i := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			size++
			x, y := i%w, i/w
			for dy := -1; dy <= 1; dy++ {
				for dx := -1; dx <= 1; dx++ {
					nx, ny := x+dx, y+dy
					if nx < 0 || ny < 0 || nx >= w || ny >= h {
						continue
					}
					n := ny*w + nx
					if label[n] == 0 && opaque(n) {
						label[n] = id
						stack = append(stack, n)
					}
				}
			}
		}
		sizes = append(sizes, size)
	}
	largest := 0
	for _, s := range sizes {
		largest = max(largest, s)
	}
	dropped := func(id int32) bool { return id > 0 && float64(sizes[id-1]) < keep*float64(largest) }
	// Pixels at or under the threshold belong to the nearest labelled
	// neighbour (a blob's soft rim): cleared with it.
	for i := 0; i < w*h; i++ {
		id := label[i]
		if id == 0 {
			x, y := i%w, i/w
			for dy := -1; dy <= 1 && id == 0; dy++ {
				for dx := -1; dx <= 1 && id == 0; dx++ {
					nx, ny := x+dx, y+dy
					if nx >= 0 && ny >= 0 && nx < w && ny < h {
						id = label[ny*w+nx]
					}
				}
			}
		}
		if dropped(id) {
			o := img.PixOffset(i%w+b.Min.X, i/w+b.Min.Y)
			img.Pix[o], img.Pix[o+1], img.Pix[o+2], img.Pix[o+3] = 0, 0, 0, 0
		}
	}
}
