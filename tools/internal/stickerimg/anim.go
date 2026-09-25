package stickerimg

import (
	"fmt"
	"image"
	"image/draw"
	"math"
)

// splitSlack is how far from the nominal grid line SplitGrid may move a
// cut, as a fraction of the cell size, to find the emptiest line.
const splitSlack = 0.15

// SplitGrid cuts a generated sprite sheet into cols×rows cells, read left
// to right then top to bottom. The generator lays its grid out only
// roughly, so each cut goes where the sheet is emptiest near the nominal
// grid line (within splitSlack of the cell size) rather than exactly on
// it: a character whose feet sit a little past the line is kept whole.
func SplitGrid(sheet *image.RGBA, cols, rows int) []*image.RGBA {
	b := sheet.Bounds()
	xs := gridCuts(sheet, cols, true)
	ys := gridCuts(sheet, rows, false)
	cells := make([]*image.RGBA, 0, cols*rows)
	for r := 0; r < rows; r++ {
		for c := 0; c < cols; c++ {
			src := image.Rect(b.Min.X+xs[c], b.Min.Y+ys[r], b.Min.X+xs[c+1], b.Min.Y+ys[r+1])
			cell := image.NewRGBA(image.Rect(0, 0, src.Dx(), src.Dy()))
			draw.Draw(cell, cell.Bounds(), sheet, src.Min, draw.Src)
			cells = append(cells, cell)
		}
	}
	return cells
}

// gridCuts returns n+1 cut positions along one axis (0 and the full
// extent included): each internal cut is the line with the fewest opaque
// pixels within splitSlack of its nominal position, ties going to the
// nearest.
func gridCuts(sheet *image.RGBA, n int, vertical bool) []int {
	b := sheet.Bounds()
	extent, across := b.Dy(), b.Dx()
	if vertical {
		extent, across = b.Dx(), b.Dy()
	}
	cuts := []int{0}
	cell := extent / n
	slack := int(float64(cell) * splitSlack)
	for k := 1; k < n; k++ {
		nominal := k * cell
		best, bestCount := nominal, -1
		for pos := nominal - slack; pos <= nominal+slack; pos++ {
			count := 0
			for i := 0; i < across; i++ {
				x, y := pos, i
				if !vertical {
					x, y = i, pos
				}
				if sheet.Pix[sheet.PixOffset(b.Min.X+x, b.Min.Y+y)+3] > 8 {
					count++
				}
			}
			if bestCount < 0 || count < bestCount || (count == bestCount && abs(pos-nominal) < abs(best-nominal)) {
				best, bestCount = pos, count
			}
		}
		cuts = append(cuts, best)
	}
	return append(cuts, extent)
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
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
	// Resolution, when set, draws the frames at the scale of a sticker
	// this many px square (the first frame's art fills its inner area) —
	// smaller than the generated cells when those are bigger than a
	// sticker on screen needs. Never upscales. 0 = the cells' own size.
	Resolution int
	// MaxSheet caps either dimension of the output sheet in px; the frames
	// are downscaled uniformly to fit. 0 = no cap.
	MaxSheet int
	// Normalize rescales each frame so its base (the widest row in the
	// bottom part of the art) is the same width as the first frame's,
	// hiding the generator's small scale drift between cells. Only for a
	// base object that keeps its shape and is the widest thing down there
	// in every pose (a lily pad, a perch): feet, a curling body or spread
	// wings make the measure jump. A frame whose base measures more than
	// MaxDrift away from the first (fraction; 0 = 0.25) is left alone.
	Normalize bool
	MaxDrift  float64
	// Rest is the sticker's own raw art (no border) and RestFrames the
	// indices of the cells that show the rest pose: those frames take the
	// real art, so an animation starts and ends on exactly the sticker
	// instead of a redrawing of it.
	Rest       *image.RGBA
	RestFrames []int
	// Register is how frames are put on top of each other: RegisterBase
	// (the default) anchors each on its base row (a lily pad, feet
	// planted); RegisterBody puts each where it best matches the frame
	// before it (a flight: the wings move, the body stays);
	// RegisterFeet does that sideways and keeps the art's bottom on one
	// line (a walk: the feet move, the ground stays).
	Register string
	// Loop is the run of frames (0-based, both included) a move repeats:
	// the chain of matches is closed round it, so the last frame leads
	// back into the first without a jump. Zero value: none.
	Loop [2]int
	// SheetsContinue says every sheet after the first starts with the pose
	// the sheet before it ends with (the way stickeranim's sheets are
	// written): each sheet is then scaled as a whole so that pair matches
	// (Align, shape and all), which is far steadier than comparing rest
	// cells' areas — a snail whose body is in its shell has no rest cell
	// in that sheet to compare. Off: SheetSizes' rest-area method.
	SheetsContinue bool
	// SheetSizes is how many cells came from each generated sheet, in
	// order (nil: one sheet). The generator draws each sheet at its own
	// scale — sheets of one animation came out 10 % apart — while the
	// cells within a sheet agree to a percent or two. So every sheet that
	// holds a rest frame is scaled as a whole to match the first one, by
	// comparing their rest-pose cells' areas (the same pose, so the area
	// is a fair measure, unlike one row of pixels), and the rest art is
	// scaled the same way: the whole animation lives at one size.
	SheetSizes []int
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

// A blob on a cell's edge is a neighbour's stray sliver (StripEdgeCrumbs)
// when it is small — under edgeCrumbFraction of the cell's opaque pixels
// (a fly is a few percent, a sliver far less) — or thin: reaching in from
// that edge less than edgeCrumbDepth of the cell's size (a character that
// really touches an edge reaches far into its cell; a pair of feet cut
// off by the grid line does not).
const (
	edgeCrumbFraction = 0.02
	edgeCrumbDepth    = 0.12
)

// Registration modes (AnimOptions.Register).
const (
	RegisterBase = "base"
	RegisterBody = "body"
	RegisterFeet = "feet"
)

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

	// Trim every cell and measure its base and its area.
	frames := make([]registered, len(cells))
	widths := make([]float64, len(cells))
	areas := make([]float64, len(cells))
	for i, cell := range cells {
		cleaned := Clean(cell, o.Threshold)
		StripEdgeCrumbs(cleaned, o.Threshold, edgeCrumbFraction, edgeCrumbDepth)
		box := Bounds(cleaned, o.Threshold)
		if box.Empty() {
			return nil, fmt.Errorf("frame %d is fully transparent", i+1)
		}
		art := image.NewRGBA(image.Rect(0, 0, box.Dx(), box.Dy()))
		draw.Draw(art, art.Bounds(), cleaned, box.Min, draw.Src)
		cx, w := baseRow(art, o.Threshold)
		frames[i] = registered{art: art, anchor: image.Pt(cx, art.Rect.Dy())}
		widths[i] = float64(w)
		areas[i] = float64(opaqueCount(art, o.Threshold))
	}

	// One scale per sheet, against the first sheet's rest-pose cell — or,
	// when sheets continue each other, against the frame before each.
	scales := sheetScales(len(cells), o.SheetSizes, o.RestFrames, areas, o.MaxDrift)
	if o.SheetsContinue && len(o.SheetSizes) > 1 {
		scales = continuedScales(frames, o.SheetSizes)
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
		// The real art at the size of the first rest-pose cell, by area;
		// every rest frame is then the very same image at the same size.
		first := o.RestFrames[0]
		if first < 0 || first >= len(frames) {
			return nil, fmt.Errorf("rest frame %d is out of range", first+1)
		}
		s := math.Sqrt(areas[first] / float64(opaqueCount(art, o.Threshold)))
		if o.SheetsContinue {
			// Same pose, so a match of shape and size is fairer than areas
			// (the generator's drawing is often a little rounder).
			s = 1 / sameScale(frames[first].art, Resize(art, int(math.Round(float64(art.Rect.Dx())*s)), int(math.Round(float64(art.Rect.Dy())*s)))) * s
		}
		scaled := Resize(art, int(math.Round(float64(art.Rect.Dx())*s)), int(math.Round(float64(art.Rect.Dy())*s)))
		if o.SheetsContinue {
			// A sheet that ends on the rest pose may have drifted in size on
			// the way: its generated rest cell says by how much, and the
			// frames since the sheet began are brought back gradually.
			start := 0
			for _, size := range o.SheetSizes {
				end := min(start+size, len(frames))
				for _, r := range o.RestFrames {
					if r > start && r == end-1 && r != first {
						drift := scales[r] * sameScale(scaled, frames[r].art)
						for j := start; j <= r; j++ {
							k := float64(j-start) / float64(r-start)
							scales[j] *= math.Pow(drift/scales[r], k)
						}
					}
				}
				start = end
			}
		}
		for _, i := range o.RestFrames {
			if i < 0 || i >= len(frames) {
				return nil, fmt.Errorf("rest frame %d is out of range", i+1)
			}
			frames[i] = registered{art: scaled, anchor: image.Pt(int(math.Round(float64(cx)*s)), scaled.Rect.Dy())}
			widths[i] = float64(w) * s
			scales[i] = 1 // already at the first sheet's size
		}
	}

	// Frames whose base moves are matched one on the other instead.
	if o.Register == RegisterBody || o.Register == RegisterFeet {
		for i := range frames {
			if scales[i] != 1 {
				f := frames[i]
				w, h := int(math.Round(float64(f.art.Rect.Dx())*scales[i])), int(math.Round(float64(f.art.Rect.Dy())*scales[i]))
				frames[i] = registered{art: Resize(f.art, w, h), anchor: image.Pt(int(math.Round(float64(f.anchor.X)*scales[i])), h)}
				scales[i] = 1
			}
		}
		matchFrames(frames, o.Register == RegisterFeet, o.Loop, o.RestFrames)
	}

	// Optionally, also even out the drift between single cells against the
	// first frame, by base width (see Normalize).
	if o.Normalize && widths[0] > 0 {
		for i := 1; i < len(scales); i++ {
			s := widths[0] / (widths[i] * scales[i])
			if math.Abs(s-1) <= o.MaxDrift {
				scales[i] *= s
			}
		}
	}

	// The frames' scale relative to the finished sticker, so the border
	// and the margin come out the same width on screen: the sticker fits
	// its art into the inner square; the first frame is that art.
	inner := float64(o.StickerSize) * (1 - 2*o.Margin - 2*o.Border)
	restMax := float64(max(frames[0].art.Rect.Dx(), frames[0].art.Rect.Dy()))
	toSticker := inner / restMax
	// Output scale: native (or Resolution's, if smaller), unless the sheet
	// would exceed the cap.
	global := 1.0
	if o.Resolution > 0 {
		global = math.Min(1, float64(o.Resolution)*(1-2*o.Margin-2*o.Border)/restMax)
	}
	frameW, frameH := layout(frames, scales, o, toSticker, global)
	if o.MaxSheet > 0 {
		rows := (len(frames) + o.Columns - 1) / o.Columns
		if sw, sh := o.Columns*frameW, rows*frameH; sw > o.MaxSheet || sh > o.MaxSheet {
			global *= math.Min(float64(o.MaxSheet)/float64(sw), float64(o.MaxSheet)/float64(sh))
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

// matchFrames re-anchors (and slightly rescales) frames 1… so each sits
// where it best matches the one before it (Align: a shift and a scale
// within matchScaleStep), frame 0 keeping its place. With feet, the
// art's bottom stays on frame 0's line. A loop's chain is closed (the
// shift from its last frame back into its first is spread over the
// loop), and every later rest frame — the sticker's own art again, which
// must land exactly where frame 0 is — pulls the frames since the last
// fixed one along with it, so the model's slow drift in size and place
// never shows as a pop at the end.
func matchFrames(frames []registered, feet bool, loop [2]int, rests []int) {
	if len(frames) < 2 {
		return
	}
	type place struct{ s, x, y float64 } // art pixel p → common s·p + (x, y)
	at := make([]place, len(frames))
	at[0] = place{1, -float64(frames[0].anchor.X), -float64(frames[0].anchor.Y)}
	// match finds where frame i goes when it follows frame prev (placed).
	match := func(prev, i int) place {
		pp := at[prev]
		ref := frames[prev].art
		if pp.s != 1 {
			ref = Resize(ref, int(math.Round(float64(ref.Rect.Dx())*pp.s)), int(math.Round(float64(ref.Rect.Dy())*pp.s)))
		}
		f := frames[i].art
		pad := max(ref.Rect.Dx(), ref.Rect.Dy(), f.Rect.Dx(), f.Rect.Dy()) / 2
		canvas := image.NewRGBA(image.Rect(0, 0, ref.Rect.Dx()+2*pad, ref.Rect.Dy()+2*pad))
		draw.Draw(canvas, ref.Rect.Add(image.Pt(pad, pad)), ref, image.Point{}, draw.Src)
		// Start from the two bottoms and centres coinciding.
		guess := Placement{S: pp.s,
			Tx: float64(pad) + (float64(ref.Rect.Dx())-float64(f.Rect.Dx())*pp.s)/2,
			Ty: float64(pad) + float64(ref.Rect.Dy()) - float64(f.Rect.Dy())*pp.s}
		fit := Align(canvas, f, AlignOptions{
			MinScale: pp.s * (1 - matchScaleStep), MaxScale: pp.s * (1 + matchScaleStep), MaxShift: 0.12, Start: guess})
		return place{fit.S, pp.x + fit.Tx - float64(pad), pp.y + fit.Ty - float64(pad)}
	}
	for i := 1; i < len(frames); i++ {
		at[i] = match(i-1, i)
	}
	if from, to := loop[0], loop[1]; to > from && from >= 1 && to < len(frames) {
		again := match(to, from)
		dx, dy := again.x-at[from].x, again.y-at[from].y
		n := float64(to - from + 1)
		for i := from; i < len(frames); i++ {
			k := math.Min(float64(i-from), float64(to-from)) / n
			at[i].x -= dx * k
			at[i].y -= dy * k
		}
	}
	// Rest frames are fixed points: a correction (scale about the common
	// origin, frame 0's anchor, then a shift) grows from nothing at the
	// last fixed frame to exactly what puts this one on frame 0.
	fixed := 0
	for _, r := range rests {
		if r <= fixed || r >= len(frames) || frames[r].art != frames[0].art {
			continue
		}
		a := at[0].s / at[r].s
		bx, by := at[0].x-a*at[r].x, at[0].y-a*at[r].y
		for i := fixed + 1; i < len(frames); i++ {
			k := math.Min(float64(i-fixed)/float64(r-fixed), 1)
			ak := math.Pow(a, k)
			at[i] = place{at[i].s * ak, at[i].x*ak + bx*k, at[i].y*ak + by*k}
		}
		fixed = r
	}
	ground := at[0].y + float64(frames[0].art.Rect.Dy())
	for i, p := range at {
		art := frames[i].art
		if math.Abs(p.s-1) > 1e-4 {
			art = Resize(art, int(math.Round(float64(art.Rect.Dx())*p.s)), int(math.Round(float64(art.Rect.Dy())*p.s)))
		}
		if feet {
			p.y = ground - float64(art.Rect.Dy())
		}
		frames[i] = registered{art: art, anchor: image.Pt(int(math.Round(-p.x)), int(math.Round(-p.y)))}
	}
}

// matchScaleStep is how much a frame may differ in size from the one
// before it when matching. 0: shift only — a match of changing poses
// favours the bigger frame (it covers where the last one reached), so
// sizes come from same-pose pairs instead (continuedScales, and a
// sheet's last frame against the rest art in Animation).
const matchScaleStep = 0

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

// sameScale is the scale that makes img the size of ref, for two drawings
// of the same pose (Align, 0.7–1.4, shift free).
func sameScale(ref, img *image.RGBA) float64 {
	pad := max(ref.Rect.Dx(), ref.Rect.Dy(), img.Rect.Dx(), img.Rect.Dy()) / 2
	canvas := image.NewRGBA(image.Rect(0, 0, ref.Rect.Dx()+2*pad, ref.Rect.Dy()+2*pad))
	draw.Draw(canvas, ref.Rect.Add(image.Pt(pad, pad)), ref, image.Point{}, draw.Src)
	guess := Placement{S: 1,
		Tx: float64(pad) + float64(ref.Rect.Dx()-img.Rect.Dx())/2,
		Ty: float64(pad) + float64(ref.Rect.Dy()-img.Rect.Dy())}
	return Align(canvas, img, AlignOptions{MinScale: 0.7, MaxScale: 1.4, MaxShift: 0.2, Start: guess}).S
}

// continuedScales gives every cell its sheet's scale when each sheet
// starts with the pose the one before it ends with: the first sheet is 1,
// and each next one is scaled so its first frame matches the last frame
// before it (Align, 0.8–1.25).
func continuedScales(frames []registered, sizes []int) []float64 {
	scales := make([]float64, len(frames))
	current := 1.0
	start := 0
	for k, size := range sizes {
		end := min(start+size, len(frames))
		if k > 0 && start > 0 && start < len(frames) {
			prev, next := frames[start-1].art, frames[start].art
			if current != 1 {
				prev = Resize(prev, int(math.Round(float64(prev.Rect.Dx())*current)), int(math.Round(float64(prev.Rect.Dy())*current)))
			}
			pad := max(prev.Rect.Dx(), prev.Rect.Dy(), next.Rect.Dx(), next.Rect.Dy()) / 2
			canvas := image.NewRGBA(image.Rect(0, 0, prev.Rect.Dx()+2*pad, prev.Rect.Dy()+2*pad))
			draw.Draw(canvas, prev.Rect.Add(image.Pt(pad, pad)), prev, image.Point{}, draw.Src)
			guess := Placement{S: 1,
				Tx: float64(pad) + float64(prev.Rect.Dx()-next.Rect.Dx())/2,
				Ty: float64(pad) + float64(prev.Rect.Dy()-next.Rect.Dy())}
			fit := Align(canvas, next, AlignOptions{MinScale: 0.8, MaxScale: 1.25, MaxShift: 0.2, Start: guess})
			current = fit.S
		}
		for i := start; i < end; i++ {
			scales[i] = current
		}
		start = end
	}
	return scales
}

// sheetScales gives every cell its sheet's scale: 1 for the first sheet
// with a rest frame, and for each other sheet with one, the factor that
// brings its rest-pose cell to the same area (square-rooted into a linear
// scale). A sheet without a rest frame takes the scale of the sheet before
// it (the generator carries on from the previous sheet); a factor further
// than maxDrift from 1 means the cells don't show the same pose, and is
// ignored.
func sheetScales(n int, sizes []int, restFrames []int, areas []float64, maxDrift float64) []float64 {
	scales := make([]float64, n)
	for i := range scales {
		scales[i] = 1
	}
	if len(sizes) == 0 {
		sizes = []int{n}
	}
	isRest := map[int]bool{}
	for _, i := range restFrames {
		isRest[i] = true
	}
	reference := -1.0 // the first rest-pose cell's area
	current := 1.0
	start := 0
	for _, size := range sizes {
		end := min(start+size, n)
		for i := start; i < end; i++ {
			if !isRest[i] || areas[i] <= 0 {
				continue
			}
			if reference < 0 {
				reference = areas[i]
			} else if s := math.Sqrt(reference / areas[i]); math.Abs(s-1) <= maxDrift {
				current = s
			}
			break
		}
		for i := start; i < end; i++ {
			scales[i] = current
		}
		start = end
	}
	return scales
}

// opaqueCount is the number of pixels with alpha above threshold.
func opaqueCount(art *image.RGBA, threshold uint8) int {
	n := 0
	for i := 3; i < len(art.Pix); i += 4 {
		if art.Pix[i] > threshold {
			n++
		}
	}
	return n
}

// baseRow finds the art's base: the widest row of alpha in the bottom 45 %
// of the image (a lily pad, a body on its feet). Returns the row's centre
// x and its width. The very bottom rows are not used: a pad's underside
// or a set of paws is drawn a little differently in every cell, while
// the widest row of the base is stable.
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

// StripEdgeCrumbs clears connected blobs of alpha that touch the image
// edge and are either small (less than maxFraction of the image's opaque
// pixels) or thin (reaching in from an edge they touch less than maxDepth
// of the image's size): when a sheet is cut into cells, a neighbour's art
// that strayed over the grid line shows up as a sliver on the boundary,
// while a character that fills its cell to the edge reaches deep into it
// and is kept.
func StripEdgeCrumbs(img *image.RGBA, threshold uint8, maxFraction, maxDepth float64) {
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
			minX, minY, maxX, maxY := w, h, -1, -1
			for len(stack) > 0 {
				i := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				blob = append(blob, i)
				px, py := i%w, i/w
				if px == 0 || py == 0 || px == w-1 || py == h-1 {
					touches = true
				}
				minX, minY, maxX, maxY = min(minX, px), min(minY, py), max(maxX, px), max(maxY, py)
				for _, d := range [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}} {
					nx, ny := px+d[0], py+d[1]
					if nx < 0 || ny < 0 || nx >= w || ny >= h || seen[ny*w+nx] || !opaque(nx, ny) {
						continue
					}
					seen[ny*w+nx] = true
					stack = append(stack, ny*w+nx)
				}
			}
			if !touches {
				continue
			}
			small := float64(len(blob)) < maxFraction*float64(total)
			// Thin: on every edge it touches, it reaches in less than maxDepth.
			thin := true
			if minY == 0 && float64(maxY+1) >= maxDepth*float64(h) {
				thin = false
			}
			if maxY == h-1 && float64(h-minY) >= maxDepth*float64(h) {
				thin = false
			}
			if minX == 0 && float64(maxX+1) >= maxDepth*float64(w) {
				thin = false
			}
			if maxX == w-1 && float64(w-minX) >= maxDepth*float64(w) {
				thin = false
			}
			if small || thin {
				for _, i := range blob {
					o := img.PixOffset(i%w+b.Min.X, i/w+b.Min.Y)
					img.Pix[o], img.Pix[o+1], img.Pix[o+2], img.Pix[o+3] = 0, 0, 0, 0
				}
			}
		}
	}
}
