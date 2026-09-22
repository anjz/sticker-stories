package stickerimg

import (
	"fmt"
	"image"
	"image/draw"
	"math"
)

// SplitGrid cuts a generated sprite sheet into cols×rows equal cells, read
// left to right then top to bottom.
func SplitGrid(sheet *image.RGBA, cols, rows int) []*image.RGBA {
	b := sheet.Bounds()
	cw, ch := b.Dx()/cols, b.Dy()/rows
	cells := make([]*image.RGBA, 0, cols*rows)
	for r := 0; r < rows; r++ {
		for c := 0; c < cols; c++ {
			cell := image.NewRGBA(image.Rect(0, 0, cw, ch))
			draw.Draw(cell, cell.Bounds(), sheet, image.Pt(b.Min.X+c*cw, b.Min.Y+r*ch), draw.Src)
			cells = append(cells, cell)
		}
	}
	return cells
}

// AnimOptions controls Animation. Border, Margin, StickerSize and Finish
// are the pack's sticker settings (StickerOptions): the frames get the same
// border and finish as the sticker they animate, at the frames' own scale.
type AnimOptions struct {
	StickerSize int
	Border      float64
	Margin      float64
	Threshold   uint8
	Finish      *Finish
	// Columns of the output sheet.
	Columns int
	// MaxSheet caps either dimension of the output sheet in px; the frames
	// are downscaled uniformly to fit. 0 = no cap.
	MaxSheet int
	// Normalize rescales each frame so its base (the widest row in the
	// bottom part of the art: a lily pad, the feet on the ground) is the
	// same width as the first frame's, hiding the generator's small
	// scale drift between cells. A frame whose base measures more than
	// MaxDrift away from the first (fraction; 0 = 0.25) is left alone,
	// since that means the measurement caught something else.
	Normalize bool
	MaxDrift  float64
	// Rest is the sticker's own raw art (no border) and RestFrames the
	// indices of the cells that show the rest pose: those frames take the
	// real art, scaled onto the generated cell's base, so an animation
	// starts and ends on exactly the sticker instead of a redrawing of it.
	Rest       *image.RGBA
	RestFrames []int
}

// AnimSheet is an assembled animation: every frame registered on its base,
// bordered, finished and laid out in a grid.
type AnimSheet struct {
	Image   *image.RGBA
	Frame   image.Point // one frame's size
	Columns int
	Count   int
	// Rest is the first frame's bordered content box within its frame;
	// with Sticker (the same content's box in the finished sticker image)
	// it is how the app scales and offsets the frames onto the placed
	// sticker.
	Rest image.Rectangle
	// Scales is the per-frame normalisation applied (1 = none), for the log.
	Scales []float64
}

// edgeCrumbFraction is how small a blob on a cell's edge must be, as a
// fraction of the cell's opaque pixels, to count as a neighbour's stray
// sliver (StripEdgeCrumbs): a fly is a few percent, a sliver far less.
const edgeCrumbFraction = 0.02

// registered is one frame trimmed to its art with its anchor: the centre
// of its base row and the bottom of the art.
type registered struct {
	art    *image.RGBA
	anchor image.Point
}

// Animation registers, borders and finishes a run of generated frames
// (transparent cells of one character, same design and scale) into one
// sprite sheet. Registration anchors every frame on its base so the part
// that stays still (a lily pad, the ground under the feet) does not drift
// while the character moves.
func Animation(cells []*image.RGBA, o AnimOptions) (*AnimSheet, error) {
	if len(cells) == 0 {
		return nil, fmt.Errorf("no frames")
	}
	if o.StickerSize <= 0 {
		o.StickerSize = 1024
	}
	if o.Columns <= 0 {
		o.Columns = 4
	}
	if o.MaxDrift <= 0 {
		o.MaxDrift = 0.25
	}
	finish := DefaultFinish
	if o.Finish != nil {
		finish = *o.Finish
	}

	// Trim every cell and measure its base.
	frames := make([]registered, len(cells))
	widths := make([]float64, len(cells))
	for i, cell := range cells {
		cleaned := Clean(cell, o.Threshold)
		StripEdgeCrumbs(cleaned, o.Threshold, edgeCrumbFraction)
		box := Bounds(cleaned, o.Threshold)
		if box.Empty() {
			return nil, fmt.Errorf("frame %d is fully transparent", i+1)
		}
		art := image.NewRGBA(image.Rect(0, 0, box.Dx(), box.Dy()))
		draw.Draw(art, art.Bounds(), cleaned, box.Min, draw.Src)
		cx, w := baseRow(art, o.Threshold)
		frames[i] = registered{art: art, anchor: image.Pt(cx, art.Rect.Dy())}
		widths[i] = float64(w)
	}
	if o.Rest != nil && len(o.RestFrames) > 0 {
		rest := Clean(o.Rest, o.Threshold)
		box := Bounds(rest, o.Threshold)
		if box.Empty() {
			return nil, fmt.Errorf("rest art is fully transparent")
		}
		art := image.NewRGBA(image.Rect(0, 0, box.Dx(), box.Dy()))
		draw.Draw(art, art.Bounds(), rest, box.Min, draw.Src)
		cx, w := baseRow(art, o.Threshold)
		for _, i := range o.RestFrames {
			if i < 0 || i >= len(frames) {
				return nil, fmt.Errorf("rest frame %d is out of range", i+1)
			}
			// The real art at the generated cell's scale: same base width.
			s := widths[i] / float64(w)
			scaled := Resize(art, int(math.Round(float64(art.Rect.Dx())*s)), int(math.Round(float64(art.Rect.Dy())*s)))
			frames[i] = registered{art: scaled, anchor: image.Pt(int(math.Round(float64(cx)*s)), scaled.Rect.Dy())}
		}
	}

	// Normalise the drift in scale between cells against the first frame.
	scales := make([]float64, len(cells))
	for i := range scales {
		scales[i] = 1
		if o.Normalize && i > 0 && widths[0] > 0 {
			s := widths[0] / widths[i]
			if math.Abs(s-1) <= o.MaxDrift {
				scales[i] = s
			}
		}
	}

	// The frames' scale relative to the finished sticker, so the border
	// and the margin come out the same width on screen: the sticker fits
	// its art into the inner square; the first frame is that art.
	inner := float64(o.StickerSize) * (1 - 2*o.Margin - 2*o.Border)
	restMax := float64(max(frames[0].art.Rect.Dx(), frames[0].art.Rect.Dy()))
	toSticker := inner / restMax
	// Output scale: native, unless the sheet would exceed the cap.
	global := 1.0
	frameW, frameH := layout(frames, scales, o, toSticker, global)
	if o.MaxSheet > 0 {
		rows := (len(frames) + o.Columns - 1) / o.Columns
		if sw, sh := o.Columns*frameW, rows*frameH; sw > o.MaxSheet || sh > o.MaxSheet {
			global = math.Min(float64(o.MaxSheet)/float64(sw), float64(o.MaxSheet)/float64(sh))
			frameW, frameH = layout(frames, scales, o, toSticker, global)
			// Rounding can leave the sheet a pixel or two over; the frame's
			// margin is empty, so trimming it is harmless.
			frameW, frameH = min(frameW, o.MaxSheet/o.Columns), min(frameH, o.MaxSheet/rows)
		}
	}
	radius := int(math.Round(o.Border * float64(o.StickerSize) / toSticker * global))
	marginPx := int(math.Round(o.Margin * float64(o.StickerSize) / toSticker * global))
	left, top := extents(frames, scales, global)

	rows := (len(frames) + o.Columns - 1) / o.Columns
	sheet := image.NewRGBA(image.Rect(0, 0, o.Columns*frameW, rows*frameH))
	var rest image.Rectangle
	for i, f := range frames {
		s := scales[i] * global
		art := f.art
		if s != 1 {
			art = Resize(art, int(math.Round(float64(art.Rect.Dx())*s)), int(math.Round(float64(art.Rect.Dy())*s)))
		}
		// Anchor in frame px: the common left/top extents put every anchor
		// at the same spot.
		ax := marginPx + radius + int(math.Round(-left-float64(f.anchor.X)*s))
		ay := marginPx + radius + int(math.Round(-top-float64(f.anchor.Y)*s))
		frame := image.NewRGBA(image.Rect(0, 0, frameW, frameH))
		outlined := Outline(art, radius, stickerWhite)
		at := image.Pt(ax-radius, ay-radius)
		draw.Draw(frame, outlined.Bounds().Add(at), outlined, image.Point{}, draw.Over)
		ApplyFinish(frame, finish, radius)
		if i == 0 {
			rest = Bounds(frame, 0)
		}
		col, row := i%o.Columns, i/o.Columns
		draw.Draw(sheet, image.Rect(col*frameW, row*frameH, (col+1)*frameW, (row+1)*frameH), frame, image.Point{}, draw.Src)
	}
	return &AnimSheet{Image: sheet, Frame: image.Pt(frameW, frameH), Columns: o.Columns, Count: len(frames), Rest: rest, Scales: scales}, nil
}

// extents returns the common left and top extents of all frames' art
// relative to their anchors (both ≤ 0) at the given output scale; the
// right and bottom extents are what layout adds.
func extents(frames []registered, scales []float64, global float64) (left, top float64) {
	for i, f := range frames {
		s := scales[i] * global
		left = math.Min(left, -float64(f.anchor.X)*s)
		top = math.Min(top, -float64(f.anchor.Y)*s)
	}
	return left, top
}

// layout returns the frame size that holds every frame's art plus the
// border and the margin at the given output scale.
func layout(frames []registered, scales []float64, o AnimOptions, toSticker, global float64) (w, h int) {
	left, top := extents(frames, scales, global)
	var right, bottom float64
	for i, f := range frames {
		s := scales[i] * global
		right = math.Max(right, (float64(f.art.Rect.Dx())-float64(f.anchor.X))*s)
		bottom = math.Max(bottom, (float64(f.art.Rect.Dy())-float64(f.anchor.Y))*s)
	}
	pad := 2 * (o.Border + o.Margin) * float64(o.StickerSize) / toSticker * global
	return int(math.Ceil(right-left+pad)) + 1, int(math.Ceil(bottom-top+pad)) + 1
}

// baseRow finds the art's base: the widest row of alpha in the bottom 45 %
// of the image (a lily pad, a body on its feet). Returns the row's centre
// x and its width.
func baseRow(art *image.RGBA, threshold uint8) (cx, width int) {
	b := art.Bounds()
	from := b.Min.Y + int(float64(b.Dy())*0.55)
	bestW, bestC := -1, b.Dx()/2
	for y := from; y < b.Max.Y; y++ {
		minX, maxX := -1, -1
		for x := b.Min.X; x < b.Max.X; x++ {
			if art.Pix[art.PixOffset(x, y)+3] > threshold {
				if minX < 0 {
					minX = x
				}
				maxX = x
			}
		}
		if minX >= 0 && maxX-minX+1 > bestW {
			bestW = maxX - minX + 1
			bestC = (minX + maxX + 1) / 2
		}
	}
	if bestW < 0 {
		return b.Dx() / 2, b.Dx()
	}
	return bestC - b.Min.X, bestW
}

// StripEdgeCrumbs clears small connected blobs of alpha that touch the
// image edge: when a sheet is cut into cells, a neighbour's art that
// strayed over the grid line shows up as a sliver on the boundary. A blob
// is small when it holds less than maxFraction of the image's opaque
// pixels, so a character that fills its cell to the edge is kept.
func StripEdgeCrumbs(img *image.RGBA, threshold uint8, maxFraction float64) {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	opaque := func(x, y int) bool { return img.Pix[img.PixOffset(x+b.Min.X, y+b.Min.Y)+3] > threshold }
	total := 0
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if opaque(x, y) {
				total++
			}
		}
	}
	seen := make([]bool, w*h)
	var stack, blob []int
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if seen[y*w+x] || !opaque(x, y) {
				continue
			}
			stack, blob = append(stack[:0], y*w+x), blob[:0]
			seen[y*w+x] = true
			touches := false
			for len(stack) > 0 {
				i := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				blob = append(blob, i)
				px, py := i%w, i/w
				if px == 0 || py == 0 || px == w-1 || py == h-1 {
					touches = true
				}
				for _, d := range [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}} {
					nx, ny := px+d[0], py+d[1]
					if nx < 0 || ny < 0 || nx >= w || ny >= h || seen[ny*w+nx] || !opaque(nx, ny) {
						continue
					}
					seen[ny*w+nx] = true
					stack = append(stack, ny*w+nx)
				}
			}
			if touches && float64(len(blob)) < maxFraction*float64(total) {
				for _, i := range blob {
					o := img.PixOffset(i%w+b.Min.X, i/w+b.Min.Y)
					img.Pix[o], img.Pix[o+1], img.Pix[o+2], img.Pix[o+3] = 0, 0, 0, 0
				}
			}
		}
	}
}
