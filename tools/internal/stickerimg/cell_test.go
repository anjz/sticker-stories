package stickerimg

import (
	"image"
	"image/color"
	"math"
	"strings"
	"testing"
)

func cellBlob(w, h, bw, bh int) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	x0, y0 := (w-bw)/2, (h-bh)/2
	for y := y0; y < y0+bh; y++ {
		for x := x0; x < x0+bw; x++ {
			img.Set(x, y, color.RGBA{180, 60, 60, 255})
		}
	}
	return img
}

func TestPlaceArtSitsWhereTheStickerDoes(t *testing.T) {
	src := cellBlob(300, 600, 100, 300)
	o := StickerOptions{Size: 400, Border: 0.025, Fill: 0.72, Threshold: 8}
	placed, err := PlaceArt(src, o)
	if err != nil {
		t.Fatal(err)
	}
	sticker, err := Sticker(src, o)
	if err != nil {
		t.Fatal(err)
	}
	pb, sb := Bounds(placed, 8), Bounds(sticker, 8)
	radius := int(math.Round(o.Border * float64(o.Size)))
	// The sticker is the placed art plus its border all round.
	if d := pb.Inset(-radius).Sub(sb.Min); abs(d.Min.X) > 1 || abs(d.Min.Y) > 1 || abs(pb.Inset(-radius).Max.X-sb.Max.X) > 1 || abs(pb.Inset(-radius).Max.Y-sb.Max.Y) > 1 {
		t.Errorf("placed art %v + border %d does not match the sticker %v", pb, radius, sb)
	}
}

func TestMeasureFramesFlagsSizePlaceAndCuts(t *testing.T) {
	size := 200
	frames := []*image.RGBA{cellBlob(size, size, 60, 120), cellBlob(size, size, 60, 120), cellBlob(size, size, 40, 80), cellBlob(size, size, 200, 120)}
	sheet := &AnimSheet{Image: Scaffold(frames, 4, 1, size), Frame: image.Pt(size, size), Columns: 4, Count: 4}
	qa := MeasureFrames(sheet, 8, false, false)
	if len(qa[1].Problems) != 0 {
		t.Errorf("an unchanged frame was flagged: %v", qa[1].Problems)
	}
	if qa[2].Height > 0.7 || len(qa[2].Problems) == 0 {
		t.Errorf("the shrunk frame was not flagged: %+v", qa[2])
	}
	if !qa[3].Edge {
		t.Errorf("the cut frame was not flagged: %+v", qa[3])
	}
	for _, p := range MeasureFrames(sheet, 8, true, false)[2].Problems {
		if strings.HasPrefix(p, "size") || strings.HasPrefix(p, "shrunk") {
			t.Errorf("a growing animation's small frame was flagged for its size: %v", p)
		}
	}
}
