package main

import (
	"image"
	"image/color"
	"image/draw"
	"slices"
)

// A piece is one separate drawing on a sheet: what stays together once
// pixels a few apart are joined (an ear tuft's wisp, a speckle by the
// edge).
type piece struct {
	box    image.Rectangle
	inside image.Point // an opaque pixel of it, to name it by in rig.json
	area   int
	label  int32
}

// Pieces closer than this many pixels are one piece.
const pieceGap = 4

// pieceAlpha is the alpha above which a pixel belongs to a piece.
const pieceAlpha = 24

// minPieceArea drops crumbs: a piece has at least this many pixels.
const minPieceArea = 300

// findPieces labels the sheet's pieces, in reading order (rows top to
// bottom, then left to right), with their pixels in labels.
func findPieces(img *image.RGBA) []piece {
	pieces, _ := labelPieces(img)
	return pieces
}

func labelPieces(img *image.RGBA) ([]piece, []int32) {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	opaque := make([]bool, w*h)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			opaque[y*w+x] = img.Pix[img.PixOffset(x+b.Min.X, y+b.Min.Y)+3] > pieceAlpha
		}
	}
	// Joined: opaque grown by the gap (a square, cheap and enough).
	joined := make([]bool, w*h)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if !opaque[y*w+x] {
				continue
			}
			for dy := -pieceGap; dy <= pieceGap; dy++ {
				for dx := -pieceGap; dx <= pieceGap; dx++ {
					nx, ny := x+dx, y+dy
					if nx >= 0 && ny >= 0 && nx < w && ny < h {
						joined[ny*w+nx] = true
					}
				}
			}
		}
	}
	labels := make([]int32, w*h)
	var pieces []piece
	var stack []int
	for start := range joined {
		if !joined[start] || labels[start] != 0 {
			continue
		}
		id := int32(len(pieces) + 1)
		p := piece{label: id, box: image.Rect(start%w, start/w, start%w+1, start/w+1), inside: image.Pt(-1, -1)}
		labels[start] = id
		stack = append(stack[:0], start)
		for len(stack) > 0 {
			i := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			x, y := i%w, i/w
			if opaque[i] {
				p.area++
				p.box = p.box.Union(image.Rect(x, y, x+1, y+1))
				if p.inside.X < 0 {
					p.inside = image.Pt(x, y)
				}
			}
			for _, d := range [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}} {
				nx, ny := x+d[0], y+d[1]
				if nx < 0 || ny < 0 || nx >= w || ny >= h {
					continue
				}
				n := ny*w + nx
				if joined[n] && labels[n] == 0 {
					labels[n] = id
					stack = append(stack, n)
				}
			}
		}
		pieces = append(pieces, p)
	}
	// The grown margin is not the piece's: only opaque-ish pixels keep a
	// label (the faint antialiasing round a piece included).
	for i := range labels {
		if labels[i] != 0 && img.Pix[img.PixOffset(i%w+b.Min.X, i/w+b.Min.Y)+3] == 0 {
			labels[i] = 0
		}
	}
	kept := pieces[:0]
	for _, p := range pieces {
		if p.area >= minPieceArea {
			// The box with the faint edge pixels too.
			p.box = p.box.Inset(-2).Intersect(image.Rect(0, 0, w, h))
			// A point well inside: the opaque pixel nearest the box's centre.
			p.inside = nearestOpaque(img, labels, p)
			kept = append(kept, p)
		}
	}
	// Reading order: a row is pieces whose vertical middles overlap.
	slices.SortFunc(kept, func(a, b piece) int {
		am, bm := (a.box.Min.Y+a.box.Max.Y)/2, (b.box.Min.Y+b.box.Max.Y)/2
		sameRow := am >= b.box.Min.Y && am < b.box.Max.Y || bm >= a.box.Min.Y && bm < a.box.Max.Y
		if !sameRow {
			return am - bm
		}
		return a.box.Min.X - b.box.Min.X
	})
	return kept, labels
}

func nearestOpaque(img *image.RGBA, labels []int32, p piece) image.Point {
	b := img.Bounds()
	w := b.Dx()
	c := image.Pt((p.box.Min.X+p.box.Max.X)/2, (p.box.Min.Y+p.box.Max.Y)/2)
	best, bestD := p.inside, 1<<62
	for y := p.box.Min.Y; y < p.box.Max.Y; y++ {
		for x := p.box.Min.X; x < p.box.Max.X; x++ {
			if labels[y*w+x] != p.label || img.Pix[img.PixOffset(x+b.Min.X, y+b.Min.Y)+3] < 200 {
				continue
			}
			if d := (x-c.X)*(x-c.X) + (y-c.Y)*(y-c.Y); d < bestD {
				best, bestD = image.Pt(x, y), d
			}
		}
	}
	return best
}

// pieceAt cuts out the piece at (or nearest to) a point of the sheet:
// its pixels only, cropped to its box.
func pieceAt(img *image.RGBA, at image.Point) (*image.RGBA, bool) {
	pieces, labels := labelPieces(img)
	if len(pieces) == 0 {
		return nil, false
	}
	b := img.Bounds()
	w := b.Dx()
	best, bestD := pieces[0], 1<<62
	for _, p := range pieces {
		if at.In(p.box) && labels[at.Y*w+at.X] == p.label {
			best, bestD = p, 0
			break
		}
		// Distance from the point to the box.
		dx := max(p.box.Min.X-at.X, 0, at.X-p.box.Max.X+1)
		dy := max(p.box.Min.Y-at.Y, 0, at.Y-p.box.Max.Y+1)
		if d := dx*dx + dy*dy; d < bestD {
			best, bestD = p, d
		}
	}
	if bestD > 40*40 {
		return nil, false
	}
	out := image.NewRGBA(image.Rect(0, 0, best.box.Dx(), best.box.Dy()))
	for y := best.box.Min.Y; y < best.box.Max.Y; y++ {
		for x := best.box.Min.X; x < best.box.Max.X; x++ {
			if labels[y*w+x] != best.label {
				continue
			}
			s := img.PixOffset(x+b.Min.X, y+b.Min.Y)
			d := out.PixOffset(x-best.box.Min.X, y-best.box.Min.Y)
			copy(out.Pix[d:d+4], img.Pix[s:s+4])
		}
	}
	return out, true
}

// piecesOverview is the sheet on grey with every piece boxed in red and
// numbered as parts lists them.
func piecesOverview(img *image.RGBA, pieces []piece) *image.RGBA {
	b := img.Bounds()
	out := image.NewRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
	draw.Draw(out, out.Bounds(), image.NewUniform(color.RGBA{150, 165, 150, 255}), image.Point{}, draw.Src)
	draw.Draw(out, out.Bounds(), img, b.Min, draw.Over)
	red := color.RGBA{220, 20, 20, 255}
	for i, p := range pieces {
		r := p.box
		for x := r.Min.X; x < r.Max.X; x++ {
			for t := 0; t < 3; t++ {
				out.Set(x, r.Min.Y+t, red)
				out.Set(x, r.Max.Y-1-t, red)
			}
		}
		for y := r.Min.Y; y < r.Max.Y; y++ {
			for t := 0; t < 3; t++ {
				out.Set(r.Min.X+t, y, red)
				out.Set(r.Max.X-1-t, y, red)
			}
		}
		drawNumber(out, i+1, r.Min.X+6, r.Min.Y+6, 6, red)
	}
	return out
}

// digits is a 3×5 bitmap font, row by row, for the overview's numbers.
var digits = [10][5]string{
	{"###", "#.#", "#.#", "#.#", "###"}, {".#.", "##.", ".#.", ".#.", "###"},
	{"###", "..#", "###", "#..", "###"}, {"###", "..#", "###", "..#", "###"},
	{"#.#", "#.#", "###", "..#", "..#"}, {"###", "#..", "###", "..#", "###"},
	{"###", "#..", "###", "#.#", "###"}, {"###", "..#", "..#", "..#", "..#"},
	{"###", "#.#", "###", "#.#", "###"}, {"###", "#.#", "###", "..#", "###"},
}

func drawNumber(img *image.RGBA, n, x, y, scale int, c color.RGBA) {
	text := []byte(fmtInt(n))
	for i, ch := range text {
		glyph := digits[ch-'0']
		for row, line := range glyph {
			for col, px := range line {
				if px != '#' {
					continue
				}
				for dy := 0; dy < scale; dy++ {
					for dx := 0; dx < scale; dx++ {
						img.Set(x+i*4*scale+col*scale+dx, y+row*scale+dy, c)
					}
				}
			}
		}
	}
}

func fmtInt(n int) string {
	if n < 10 {
		return string(rune('0' + n))
	}
	return fmtInt(n/10) + string(rune('0'+n%10))
}
