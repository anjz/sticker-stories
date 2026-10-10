package main

import (
	"fmt"
	"image"
	"os"
	"slices"
	"strings"
	"time"
	"unicode"

	"stickerstories/tools/internal/manifest"
	"stickerstories/tools/internal/openai"
	"stickerstories/tools/internal/stickerimg"
)

// A sheet drawn a frame at a time (-local, localimage's "frames"): a small
// model cannot keep twelve poses in order in one picture, but it redraws
// one character in one new pose well. Every frame is an edit of the
// sticker's rest art — the same character, size and place, in the frame's
// pose — with the frame before as a second reference so the motion carries
// on; the frames are then laid out as the sheet the hosted model would
// draw, one per cell on the exact grid, and assembled as usual.

// Frame scale for a sheet without a scaffold: how much of its cell the
// rest pose fills — a move leaves room for spread wings and stretched legs.
const (
	frameFillAction = 0.8
	frameFillMove   = 0.55
)

// framesVersion changes whenever drawing a frame changes (its prompt, its
// references), so sheets drawn the old way are redrawn.
const framesVersion = "4"

// frameSheet draws sheet i of a and returns it as one picture. rest is the
// scaffold's rest cell (nil without a scaffold), prevLast the frame the
// previous sheet ended on. Each frame is kept in out/anims as
// <key>.sheet<n>.f<k>.raw.png under the sheet's fingerprint, so a run that
// stops part way picks up where it was.
func (r *renderer) frameSheet(a animSpec, sh sheetSpec, i, first, total int, sheetFP string, rest, prevLast *image.RGBA) (*openai.Image, error) {
	var w, h int
	if _, err := fmt.Sscanf(sh.Size, "%dx%d", &w, &h); err != nil {
		return nil, fmt.Errorf("sheet size %q: %w", sh.Size, err)
	}
	cell := w / sh.Columns
	if h/sh.Rows != cell {
		return nil, fmt.Errorf("sheet size %s does not give square cells for %dx%d", sh.Size, sh.Columns, sh.Rows)
	}
	base, err := r.frameBase(a, rest, cell)
	if err != nil {
		return nil, err
	}
	basePNG, err := stickerimg.Encode(base)
	if err != nil {
		return nil, err
	}
	cells := make([]*image.RGBA, len(sh.Frames))
	var prev *image.RGBA
	if prevLast != nil {
		prev = stickerimg.Resize(prevLast, cell, cell)
	}
	for k, text := range sh.Frames {
		n := first + k
		switch {
		case slices.Contains(a.RestFrames, n):
			// The sticker's own pose: assembly lays its real art here anyway.
			cells[k] = base
		case k == 0 && prev != nil:
			// A later sheet starts on the pose the one before ended on.
			cells[k] = prev
		default:
			path := r.out(fmt.Sprintf("%s.sheet%d.f%d.raw.png", a.key(), i+1, n))
			prompt := framePrompt(r.c.art.Style, r.c.framesSticker(a.Sticker), a, sh, text, prev != nil)
			fp := hashOf(sheetFP, "frame", fmt.Sprint(k), prompt)
			if !r.upToDate(path, fp) {
				refs := [][]byte{basePNG}
				if prev != nil {
					p, err := stickerimg.Encode(prev)
					if err != nil {
						return nil, err
					}
					refs = append(refs, p)
				}
				started := time.Now()
				img, err := r.oa.Edit(r.ctx, openai.ImageRequest{
					Model: editModel, Prompt: prompt,
					Size: fmt.Sprintf("%dx%d", cell, cell), Quality: r.o.quality, Background: "transparent", References: refs,
					// The references are cell-sized: sending them larger only
					// costs time.
					Hints: map[string]any{"refMaxPixels": cell * cell},
				})
				if err != nil {
					return nil, fmt.Errorf("frame %d: %w", n, err)
				}
				if err := os.WriteFile(path, img.PNG, 0o644); err != nil {
					return nil, err
				}
				r.done(path, fp)
				r.say("  %s frame %d (%.0fs)", a.key(), n, time.Since(started).Seconds())
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return nil, err
			}
			img, err := stickerimg.Decode(data)
			if err != nil {
				return nil, fmt.Errorf("frame %d: %w", n, err)
			}
			// A second character now and then (a small model's habit) would
			// ride the chain into every later frame: only the drawing stays.
			keepMain(img)
			cells[k] = stickerimg.Resize(img, cell, cell)
		}
		prev = cells[k]
	}
	png, err := stickerimg.Encode(stickerimg.Scaffold(cells, sh.Columns, sh.Rows, cell))
	if err != nil {
		return nil, err
	}
	return &openai.Image{PNG: png}, nil
}

// frameBase is the rest pose every frame is redrawn from, cell-sized: the
// scaffold's rest cell (with the animation's room) when the pack has one,
// else the sticker's raw art scaled into the cell.
func (r *renderer) frameBase(a animSpec, rest *image.RGBA, cell int) (*image.RGBA, error) {
	if rest != nil {
		return stickerimg.Resize(roomy(rest, a.room()), cell, cell), nil
	}
	data, err := os.ReadFile(r.rawPath(a.Sticker))
	if err != nil {
		return nil, fmt.Errorf("%s: drawing a frame at a time needs stickerart's raw art: %w", a.Sticker, err)
	}
	src, err := stickerimg.Decode(data)
	if err != nil {
		return nil, err
	}
	fill := frameFillAction
	if a.kind() == manifest.KindMove {
		fill = frameFillMove
	}
	return stickerimg.PlaceArt(src, stickerimg.StickerOptions{Size: cell, Fill: fill, Threshold: 8})
}

// framePrompt asks for one frame: the character in image 1, redrawn in
// this frame's pose, carrying on from the frame before (image 2). The
// sticker's description keeps its colours from drifting along the chain
// toward the style's palette. The picture is never called a frame or an
// animation's nth: a small model then draws a sprite sheet.
func framePrompt(style, sticker string, a animSpec, sh sheetSpec, frame string, hasPrev bool) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n\n", style)
	fmt.Fprintf(&b, "Image 1 shows a sticker character: %s Redraw this exact character — the same design, colours, proportions, features and line, at the same size and in the same place in the picture, with %s exactly where they are in image 1 — in this pose: %s",
		strings.TrimSpace(sticker), a.Base, strings.TrimSpace(frame))
	fmt.Fprintf(&b, "\n\nWhat is happening: %s", strings.TrimSpace(a.Description))
	if hasPrev {
		b.WriteString(" Image 2 shows the character a moment before: this pose is a small step on from it.")
	}
	if a.kind() == manifest.KindMove {
		b.WriteString(" The character moves in place, as if on a treadmill: it does not travel across the picture.")
	}
	if h := strings.TrimSpace(sh.Hint); h != "" {
		fmt.Fprintf(&b, " %s", h)
	}
	b.WriteString("\n\nOne single character, drawn once, whole and well inside the picture, nothing cut off. Nothing under its feet, no ground, no shadow, no text, no background — fully transparent background.")
	return b.String()
}

// framesSticker describes the sticker for a frame: its prompt, without the
// clauses about a prop stickerart removed ("perched on a short branch" —
// told the prop is gone, a small model still draws what the words name).
// A clause goes when it has a word of the prop's (Remove, four letters or
// more) that is not the sticker's own name.
func (c *ctxt) framesSticker(id string) string {
	for _, s := range c.art.Stickers {
		if s.ID != id {
			continue
		}
		if s.Prop == nil {
			return s.Prompt
		}
		words := map[string]bool{}
		for _, w := range strings.FieldsFunc(strings.ToLower(s.Prop.Remove), func(r rune) bool { return !unicode.IsLetter(r) }) {
			if len(w) >= 4 && !strings.Contains(strings.ToLower(id), w) && !propStopWords[w] {
				words[w] = true
			}
		}
		var kept []string
		for _, clause := range strings.FieldsFunc(s.Prompt, func(r rune) bool { return r == ',' || r == ';' || r == '.' }) {
			drop := false
			for _, w := range strings.FieldsFunc(strings.ToLower(clause), func(r rune) bool { return !unicode.IsLetter(r) }) {
				drop = drop || words[w]
			}
			if !drop && strings.TrimSpace(clause) != "" {
				kept = append(kept, strings.TrimSpace(clause))
			}
		}
		return strings.Join(kept, ", ") + "."
	}
	return ""
}

var propStopWords = map[string]bool{"with": true, "under": true, "from": true, "that": true, "this": true, "into": true, "onto": true, "over": true, "their": true}

// keepMain clears every blob of a frame but the largest, specks (a
// feather apart from the body) and those lying mostly inside the largest's
// bounding box (a wing tip): a second character drawn beside it goes, even
// one tucked under a spread wing.
func keepMain(img *image.RGBA) {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	label := make([]int32, w*h)
	alpha := func(i int) uint8 { return img.Pix[img.PixOffset(i%w+b.Min.X, i/w+b.Min.Y)+3] }
	var boxes []image.Rectangle
	var areas []int
	for i := range label {
		if label[i] != 0 || alpha(i) <= 8 {
			continue
		}
		id := int32(len(boxes) + 1)
		box := image.Rect(i%w, i/w, i%w+1, i/w+1)
		area := 0
		stack := []int{i}
		label[i] = id
		for len(stack) > 0 {
			p := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			area++
			box = box.Union(image.Rect(p%w, p/w, p%w+1, p/w+1))
			for dy := -1; dy <= 1; dy++ {
				for dx := -1; dx <= 1; dx++ {
					x, y := p%w+dx, p/w+dy
					if x < 0 || y < 0 || x >= w || y >= h {
						continue
					}
					q := y*w + x
					if label[q] == 0 && alpha(q) > 8 {
						label[q] = id
						stack = append(stack, q)
					}
				}
			}
		}
		boxes = append(boxes, box)
		areas = append(areas, area)
	}
	if len(boxes) < 2 {
		return
	}
	main := 0
	for i := range areas {
		if areas[i] > areas[main] {
			main = i
		}
	}
	keep := make([]bool, len(boxes))
	for i, bx := range boxes {
		inside := bx.Intersect(boxes[main])
		keep[i] = i == main || areas[i] < areas[main]/50 || inside.Dx()*inside.Dy()*5 >= bx.Dx()*bx.Dy()*4
	}
	for i := range label {
		if label[i] != 0 && !keep[label[i]-1] {
			o := img.PixOffset(i%w+b.Min.X, i/w+b.Min.Y)
			copy(img.Pix[o:o+4], []uint8{0, 0, 0, 0})
		}
	}
}
