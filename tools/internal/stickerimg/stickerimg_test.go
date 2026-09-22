package stickerimg

import (
	"image"
	"image/color"
	"os"
	"path/filepath"
	"testing"
)

func blob(w, h int, r image.Rectangle) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := r.Min.Y; y < r.Max.Y; y++ {
		for x := r.Min.X; x < r.Max.X; x++ {
			img.SetRGBA(x, y, color.RGBA{200, 50, 50, 255})
		}
	}
	return img
}

func TestSticker(t *testing.T) {
	src := blob(400, 400, image.Rect(100, 150, 200, 350)) // 100×200 red block off-centre
	out, err := Sticker(src, StickerOptions{Size: 256, Border: 0.04, Margin: 0.05})
	if err != nil {
		t.Fatal(err)
	}
	if out.Bounds().Dx() != 256 || out.Bounds().Dy() != 256 {
		t.Fatalf("size %v", out.Bounds())
	}
	box := Bounds(out, 0)
	// centred: symmetric margins within a pixel
	if d := box.Min.X - (256 - box.Max.X); d < -2 || d > 2 {
		t.Errorf("not centred horizontally: %v", box)
	}
	if d := box.Min.Y - (256 - box.Max.Y); d < -2 || d > 2 {
		t.Errorf("not centred vertically: %v", box)
	}
	// outline: the border is paper-white a little way in from the edge…
	c := out.RGBAAt(128, box.Min.Y+7)
	if c.R < 235 || c.G < 235 || c.B < 230 {
		t.Errorf("expected white border at top, got %v", c)
	}
	// …and shaded darker right at the cut edge (the vinyl rim).
	if edge := out.RGBAAt(128, box.Min.Y+1); edge.R >= c.R-8 {
		t.Errorf("rim should be darker than the border: edge %v inner %v", edge, c)
	}
	// centre still red
	if c := out.RGBAAt(128, 128); c.R < 150 || c.G > 90 {
		t.Errorf("centre should be red, got %v", c)
	}
	// top-lit: the red is a touch brighter near the top than near the bottom
	if top, bottom := out.RGBAAt(128, box.Min.Y+30), out.RGBAAt(128, box.Max.Y-30); top.R <= bottom.R {
		t.Errorf("expected the top to be lit brighter: top %v bottom %v", top, bottom)
	}
	// alpha untouched by the finish
	if out.RGBAAt(128, 128).A != 255 || out.RGBAAt(2, 2).A != 0 {
		t.Errorf("finish must not change alpha")
	}
	// a zero finish is flat white
	flat, err := Sticker(src, StickerOptions{Size: 256, Border: 0.04, Margin: 0.05, Finish: &Finish{}})
	if err != nil {
		t.Fatal(err)
	}
	if e, in := flat.RGBAAt(128, Bounds(flat, 0).Min.Y+1), flat.RGBAAt(128, Bounds(flat, 0).Min.Y+7); e.R != in.R {
		t.Errorf("flat finish should not shade the rim: %v %v", e, in)
	}
	if _, err := Sticker(image.NewRGBA(image.Rect(0, 0, 10, 10)), StickerOptions{Size: 64}); err == nil {
		t.Errorf("fully transparent should error")
	}
}

func TestCleanSolidifiesAndDefringes(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 8, 8))
	for y := 0; y < 8; y++ {
		for x := 0; x < 8; x++ {
			switch {
			case x >= 2 && x < 6:
				img.SetRGBA(x, y, color.RGBA{200, 50, 50, 250}) // nearly opaque red
			case x == 1 || x == 6:
				img.SetRGBA(x, y, color.RGBA{60, 80, 120, 120}) // bluish fringe from the model
			case x == 0 || x == 7:
				img.SetRGBA(x, y, color.RGBA{3, 3, 3, 5}) // noise
			}
		}
	}
	out := Clean(img, 8)
	if c := out.RGBAAt(3, 3); c.A != 255 || c.R < 203 {
		t.Errorf("near-opaque should become solid, got %v", c)
	}
	if c := out.RGBAAt(1, 3); c.A != 120 || c.B > c.R {
		t.Errorf("fringe should take the red neighbour's colour, got %v", c)
	}
	if c := out.RGBAAt(0, 3); c != (color.RGBA{}) {
		t.Errorf("noise should be cleared, got %v", c)
	}
}

func TestOutlineWritesValidPremultipliedPixels(t *testing.T) {
	src := image.NewRGBA(image.Rect(0, 0, 4, 4))
	src.SetRGBA(1, 1, color.RGBA{100, 0, 0, 200}) // premultiplied, not fully opaque
	out := Outline(src, 1, color.RGBA{255, 255, 255, 255})
	if c := out.RGBAAt(1, 2); c.A != 200 || c.R != 200 || c.G != 200 {
		t.Errorf("border pixel should be white premultiplied by its alpha, got %v", c)
	}
	if _, err := Encode(out); err != nil {
		t.Fatal(err)
	}
}

func TestEdgeDistance(t *testing.T) {
	img := blob(20, 20, image.Rect(5, 5, 15, 15))
	d := edgeDistance(img)
	if d[5*20+5] != 1 || d[10*20+10] < 4.9 || d[10*20+10] > 6.1 || d[2*20+2] != 0 {
		t.Errorf("distances wrong: corner %v centre %v outside %v", d[5*20+5], d[10*20+10], d[2*20+2])
	}
}

func TestWideCanvasAndCentre(t *testing.T) {
	base := blob(40, 30, image.Rect(0, 0, 40, 30))
	canvas, mask, err := WideCanvas(base, 60)
	if err != nil {
		t.Fatal(err)
	}
	if canvas.Bounds().Dx() != 60 || mask.RGBAAt(5, 5).A != 0 || mask.RGBAAt(30, 5).A != 255 {
		t.Errorf("mask wrong: side %v centre %v", mask.RGBAAt(5, 5), mask.RGBAAt(30, 5))
	}
	if c := canvas.RGBAAt(30, 15); c.R != 200 {
		t.Errorf("base not centred: %v", c)
	}
	back := Centre(canvas, 40)
	if back.Bounds().Dx() != 40 || back.RGBAAt(0, 0).R != 200 {
		t.Errorf("centre crop wrong")
	}
}

func TestResizeKeepsAlphaEdges(t *testing.T) {
	src := blob(100, 100, image.Rect(0, 0, 50, 100))
	out := Resize(src, 10, 10)
	if out.RGBAAt(1, 5).A != 255 || out.RGBAAt(8, 5).A != 0 {
		t.Errorf("alpha not preserved: %v %v", out.RGBAAt(1, 5), out.RGBAAt(8, 5))
	}
	if c := out.RGBAAt(1, 5); c.R != 200 {
		t.Errorf("colour bled: %v", c)
	}
	// The edge pixel straddling opaque and transparent stays valid
	// premultiplied colour: no channel above alpha, and proportional.
	for x := 0; x < 10; x++ {
		c := out.RGBAAt(x, 5)
		if c.R > c.A || c.G > c.A || c.B > c.A {
			t.Fatalf("invalid premultiplied pixel at %d: %v", x, c)
		}
		if c.A > 0 && c.A < 255 && (c.R < c.A*3/4-2) {
			t.Errorf("edge pixel lost its colour: %v", c)
		}
	}
}

func TestWebPRoundTrip(t *testing.T) {
	src := blob(64, 64, image.Rect(8, 8, 56, 40))
	src.SetRGBA(60, 60, color.RGBA{0, 0, 0, 0})
	data, err := EncodeWebP(src)
	if err != nil {
		t.Fatal(err)
	}
	if !isWebP(data) {
		t.Fatalf("not a WebP: %q", data[:12])
	}
	back, err := Decode(data)
	if err != nil {
		t.Fatal(err)
	}
	if back.Bounds() != src.Bounds() {
		t.Fatalf("bounds %v", back.Bounds())
	}
	// Alpha is lossless; colour is close.
	for _, p := range []image.Point{{8, 8}, {30, 20}, {55, 39}, {60, 60}, {2, 2}} {
		a, b := src.RGBAAt(p.X, p.Y), back.RGBAAt(p.X, p.Y)
		if a.A != b.A {
			t.Errorf("alpha at %v: %d vs %d", p, a.A, b.A)
		}
		if a.A == 255 && (absDiff(a.R, b.R) > 12 || absDiff(a.G, b.G) > 12 || absDiff(a.B, b.B) > 12) {
			t.Errorf("colour at %v: %v vs %v", p, a, b)
		}
	}
	// PNG still decodes through the same door.
	pngData, _ := Encode(src)
	if _, err := Decode(pngData); err != nil {
		t.Errorf("png: %v", err)
	}
}

func absDiff(a, b uint8) int {
	if a > b {
		return int(a - b)
	}
	return int(b - a)
}

func TestInstallWebPCaches(t *testing.T) {
	dir := t.TempDir()
	src, dst := filepath.Join(dir, "a.png"), filepath.Join(dir, "pack", "a.webp")
	data, _ := Encode(blob(32, 32, image.Rect(4, 4, 28, 28)))
	os.WriteFile(src, data, 0o644)
	cache := map[string]string{}
	if did, err := InstallWebP(src, dst, cache); err != nil || !did {
		t.Fatalf("first install: did %v err %v", did, err)
	}
	out, err := os.ReadFile(dst)
	if err != nil || !isWebP(out) {
		t.Fatalf("no WebP written: %v", err)
	}
	if did, _ := InstallWebP(src, dst, cache); did {
		t.Errorf("unchanged source should be cached")
	}
	os.Remove(dst)
	if did, _ := InstallWebP(src, dst, cache); !did {
		t.Errorf("a missing pack file is re-encoded even when cached")
	}
	data2, _ := Encode(blob(32, 32, image.Rect(2, 2, 30, 30)))
	os.WriteFile(src, data2, 0o644)
	if did, _ := InstallWebP(src, dst, cache); !did {
		t.Errorf("a changed source is re-encoded")
	}
}
