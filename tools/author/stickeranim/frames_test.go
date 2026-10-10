package main

import (
	"encoding/json"
	"image"
	"image/color"
	"testing"
)

func TestFramesStickerDropsPropClauses(t *testing.T) {
	c := &ctxt{art: &artConfig{}}
	json.Unmarshal([]byte(`{"stickers": [{"id": "owl", "prompt": "A round tawny owl with big eyes, feathery ear tufts, perched on a short branch, calm and sleepy.", "prop": {"remove": "the short branch with its leaves under the owl"}}]}`), c.art)
	if got, want := c.framesSticker("owl"), "A round tawny owl with big eyes, feathery ear tufts, calm and sleepy."; got != want {
		t.Errorf("framesSticker = %q, want %q", got, want)
	}
}

func TestKeepMainDropsASecondCharacter(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 100, 100))
	fill := func(x0, y0, x1, y1 int) {
		for y := y0; y < y1; y++ {
			for x := x0; x < x1; x++ {
				img.SetRGBA(x, y, color.RGBA{A: 255})
			}
		}
	}
	fill(10, 10, 40, 60) // the character's body
	fill(10, 10, 90, 14) // its spread wing
	fill(85, 20, 88, 24) // a wing tip apart from it, inside its box
	fill(95, 95, 97, 97) // a speck
	fill(60, 30, 85, 75) // a second character, under the wing
	keepMain(img)
	for _, c := range []struct {
		x, y int
		kept bool
		what string
	}{{20, 20, true, "the body"}, {50, 12, true, "the wing"}, {86, 21, true, "the wing tip"}, {96, 96, true, "the speck"}, {70, 70, false, "the second character"}} {
		if kept := img.RGBAAt(c.x, c.y).A != 0; kept != c.kept {
			t.Errorf("%s: kept %v, want %v", c.what, kept, c.kept)
		}
	}
}
