// Command placeholdergen generates placeholder assets for a pack so the app
// can be developed before real art and narration exist. It is TEMPORARY
// tooling: real art replaces the PNGs, and the tts pipeline replaces the
// macOS `say` narration (see docs/roadmap.md).
//
// It reads <pack-dir>/manifest.json and writes, for every declared asset path:
//   - background/foreground scenery PNGs (Go stdlib drawing)
//   - one PNG per sticker (hand-drawn shape per known ID, generic blob otherwise)
//   - one .m4a per story, rendered with `say` + `afconvert` (macOS only)
//
// Usage:
//
//	placeholdergen -pack ../packs/forest [-audio=false]
package main

import (
	"flag"
	"hash/fnv"
	"image"
	"image/color"
	"image/png"
	"log"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"

	"stickerstories/tools/internal/manifest"
)

func main() {
	log.SetFlags(0)
	packDir := flag.String("pack", "", "pack directory containing manifest.json")
	audio := flag.Bool("audio", true, "render placeholder narration with `say` (macOS only)")
	flag.Parse()
	if *packDir == "" {
		log.Fatal("usage: placeholdergen -pack <pack-dir> [-audio=false]")
	}

	m, err := manifest.Load(*packDir)
	if err != nil {
		log.Fatal(err)
	}

	writePNG(filepath.Join(*packDir, m.Background), drawBackground(sceneW))
	writePNG(filepath.Join(*packDir, m.Foreground), drawForeground(sceneW))
	if m.BackgroundWide != "" {
		// Wide rendition for wide windows: same height, base scene centred,
		// extra scenery in the margins (docs/pack-format.md, "Art safe area").
		writePNG(filepath.Join(*packDir, m.BackgroundWide), drawBackground(sceneWideW))
		writePNG(filepath.Join(*packDir, m.ForegroundWide), drawForeground(sceneWideW))
	}
	for _, st := range m.Stickers {
		writePNG(filepath.Join(*packDir, st.Image), drawSticker(st.ID))
	}

	if *audio {
		if runtime.GOOS != "darwin" {
			log.Fatal("audio rendering needs macOS (`say`/`afconvert`); rerun with -audio=false")
		}
		for _, story := range m.Stories {
			for _, lang := range m.Languages {
				loc, ok := story.Localizations[lang]
				if !ok {
					log.Fatalf("story %q has no %q localization; fix the manifest first", story.ID, lang)
				}
				renderNarration(filepath.Join(*packDir, loc.Audio), loc.Text, lang)
			}
		}
	}
	log.Printf("placeholder assets written to %s", *packDir)
}

// narrationVoices maps a pack language to the `say` voice used for its
// placeholder narration. Extend when packs add languages.
var narrationVoices = map[string]string{
	"en-US": "Samantha",
	"es-ES": "Flo (Spanish (Spain))",
}

func writePNG(path string, img image.Image) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		log.Fatal(err)
	}
	f, err := os.Create(path)
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		log.Fatal(err)
	}
	log.Printf("  wrote %s", path)
}

// renderNarration renders text to an AAC .m4a via `say` (AIFF) + `afconvert`,
// using the language's configured voice.
func renderNarration(path, text, lang string) {
	voice, ok := narrationVoices[lang]
	if !ok {
		log.Fatalf("no placeholder voice configured for %q; add it to narrationVoices", lang)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		log.Fatal(err)
	}
	tmp := path + ".tmp.aiff"
	defer os.Remove(tmp)
	if out, err := exec.Command("say", "-v", voice, "-r", "170", "-o", tmp, text).CombinedOutput(); err != nil {
		log.Fatalf("say failed for %s (voice %q — is it installed?): %v\n%s", path, voice, err, out)
	}
	if out, err := exec.Command("afconvert", "-f", "m4af", "-d", "aac", "-b", "64000", tmp, path).CombinedOutput(); err != nil {
		log.Fatalf("afconvert failed for %s: %v\n%s", path, err, out)
	}
	log.Printf("  wrote %s", path)
}

// ---- tiny software rasteriser -----------------------------------------------
//
// canvas draws filled primitives with an optional uniform scale about the
// image centre and an optional colour override. Stickers are drawn twice:
// first scaled up ~12% in white (the baked-in sticker border), then at 1:1 in
// colour on top.

type canvas struct {
	img      *image.RGBA
	scale    float64
	override *color.RGBA
	cx, cy   float64
}

func newImage(w, h int) *image.RGBA {
	return image.NewRGBA(image.Rect(0, 0, w, h))
}

func (c *canvas) tx(x, y float64) (float64, float64) {
	return c.cx + (x-c.cx)*c.scale, c.cy + (y-c.cy)*c.scale
}

func (c *canvas) color(col color.RGBA) color.RGBA {
	if c.override != nil {
		return *c.override
	}
	return col
}

// blend paints col onto (x,y) with coverage a in [0,1] using source-over.
func blend(img *image.RGBA, x, y int, col color.RGBA, a float64) {
	if a <= 0 || !(image.Point{x, y}).In(img.Bounds()) {
		return
	}
	if a > 1 {
		a = 1
	}
	sa := float64(col.A) / 255 * a
	dst := img.RGBAAt(x, y)
	da := float64(dst.A) / 255
	outA := sa + da*(1-sa)
	if outA == 0 {
		return
	}
	mix := func(s, d uint8) uint8 {
		v := (float64(s)*sa + float64(d)*da*(1-sa)) / outA
		return uint8(math.Round(v))
	}
	img.SetRGBA(x, y, color.RGBA{mix(col.R, dst.R), mix(col.G, dst.G), mix(col.B, dst.B), uint8(math.Round(outA * 255))})
}

func (c *canvas) circle(x, y, r float64, col color.RGBA) {
	c.ellipse(x, y, r, r, col)
}

func (c *canvas) ellipse(x, y, rx, ry float64, col color.RGBA) {
	x, y = c.tx(x, y)
	rx *= c.scale
	ry *= c.scale
	col = c.color(col)
	feather := 1.5
	for py := int(y - ry - 2); py <= int(y+ry+2); py++ {
		for px := int(x - rx - 2); px <= int(x+rx+2); px++ {
			dx := (float64(px) + 0.5 - x) / rx
			dy := (float64(py) + 0.5 - y) / ry
			// distance from edge in ~pixels, positive inside
			d := (1 - math.Sqrt(dx*dx+dy*dy)) * math.Min(rx, ry)
			blend(c.img, px, py, col, d/feather+0.5)
		}
	}
}

func (c *canvas) rect(x, y, w, h float64, col color.RGBA) {
	x0, y0 := c.tx(x, y)
	x1, y1 := c.tx(x+w, y+h)
	col = c.color(col)
	for py := int(y0); py < int(y1); py++ {
		for px := int(x0); px < int(x1); px++ {
			blend(c.img, px, py, col, 1)
		}
	}
}

func (c *canvas) triangle(x1, y1, x2, y2, x3, y3 float64, col color.RGBA) {
	x1, y1 = c.tx(x1, y1)
	x2, y2 = c.tx(x2, y2)
	x3, y3 = c.tx(x3, y3)
	col = c.color(col)
	minX, maxX := int(math.Min(x1, math.Min(x2, x3))), int(math.Max(x1, math.Max(x2, x3)))
	minY, maxY := int(math.Min(y1, math.Min(y2, y3))), int(math.Max(y1, math.Max(y2, y3)))
	sign := func(ax, ay, bx, by, px, py float64) float64 {
		return (px-bx)*(ay-by) - (ax-bx)*(py-by)
	}
	for py := minY; py <= maxY; py++ {
		for px := minX; px <= maxX; px++ {
			fx, fy := float64(px)+0.5, float64(py)+0.5
			d1 := sign(x1, y1, x2, y2, fx, fy)
			d2 := sign(x2, y2, x3, y3, fx, fy)
			d3 := sign(x3, y3, x1, y1, fx, fy)
			neg := d1 < 0 || d2 < 0 || d3 < 0
			pos := d1 > 0 || d2 > 0 || d3 > 0
			if !(neg && pos) {
				blend(c.img, px, py, col, 1)
			}
		}
	}
}

// ---- palette ----------------------------------------------------------------

var (
	white  = color.RGBA{255, 255, 255, 255}
	dark   = color.RGBA{62, 47, 42, 255}
	cream  = color.RGBA{243, 228, 199, 255}
	red    = color.RGBA{224, 90, 78, 255}
	orange = color.RGBA{232, 133, 60, 255}
	grey   = color.RGBA{191, 195, 204, 255}
	pink   = color.RGBA{242, 166, 190, 255}
	yellow = color.RGBA{247, 201, 72, 255}
	blue   = color.RGBA{127, 178, 229, 255}
	blueLt = color.RGBA{165, 200, 240, 255}
	brown  = color.RGBA{139, 98, 57, 255}
	brownL = color.RGBA{150, 116, 76, 255}
	tan_   = color.RGBA{201, 160, 107, 255}
	shell  = color.RGBA{176, 106, 74, 255}
	shellL = color.RGBA{201, 138, 100, 255}
	green1 = color.RGBA{78, 155, 78, 255}
	green2 = color.RGBA{87, 168, 87, 255}
)

// ---- stickers (512×512, transparent) ------------------------------------------

const stickerSize = 512

var stickerDrawers = map[string]func(*canvas){
	"mushroom": func(c *canvas) {
		c.ellipse(256, 330, 70, 115, cream)
		c.ellipse(256, 215, 150, 100, red)
		c.circle(200, 195, 24, white)
		c.circle(300, 185, 18, white)
		c.circle(258, 245, 16, white)
	},
	"fox": func(c *canvas) {
		c.triangle(150, 115, 215, 225, 115, 235, orange)
		c.triangle(362, 115, 297, 225, 397, 235, orange)
		c.circle(256, 265, 130, orange)
		c.ellipse(256, 325, 72, 52, white)
		c.circle(256, 332, 16, dark)
		c.circle(208, 240, 13, dark)
		c.circle(304, 240, 13, dark)
	},
	"rabbit": func(c *canvas) {
		c.ellipse(205, 145, 38, 110, grey)
		c.ellipse(307, 145, 38, 110, grey)
		c.ellipse(205, 150, 17, 75, pink)
		c.ellipse(307, 150, 17, 75, pink)
		c.circle(256, 305, 118, grey)
		c.circle(214, 285, 12, dark)
		c.circle(298, 285, 12, dark)
		c.triangle(242, 318, 270, 318, 256, 338, pink)
	},
	"tree": func(c *canvas) {
		c.rect(228, 290, 56, 165, brown)
		c.circle(182, 262, 82, green2)
		c.circle(330, 262, 82, green2)
		c.circle(256, 205, 118, green1)
	},
	"flower": func(c *canvas) {
		c.rect(248, 285, 16, 145, green2)
		c.ellipse(302, 380, 42, 20, green2)
		for i := 0; i < 6; i++ {
			a := float64(i) * math.Pi / 3
			c.circle(256+85*math.Cos(a), 235+85*math.Sin(a), 55, pink)
		}
		c.circle(256, 235, 55, yellow)
	},
	"butterfly": func(c *canvas) {
		c.circle(188, 210, 82, blue)
		c.circle(324, 210, 82, blue)
		c.circle(202, 310, 56, blueLt)
		c.circle(310, 310, 56, blueLt)
		c.ellipse(256, 255, 18, 92, dark)
		c.circle(230, 145, 9, dark)
		c.circle(282, 145, 9, dark)
	},
	"hedgehog": func(c *canvas) {
		c.triangle(120, 265, 200, 265, 148, 135, brown)
		c.triangle(185, 255, 275, 255, 228, 105, brown)
		c.triangle(260, 255, 345, 260, 310, 120, brown)
		c.triangle(330, 270, 400, 290, 385, 175, brown)
		c.ellipse(256, 315, 160, 105, brownL)
		c.circle(372, 330, 56, cream)
		c.circle(415, 340, 14, dark)
		c.circle(352, 305, 10, dark)
	},
	"owl": func(c *canvas) {
		c.triangle(155, 145, 205, 195, 160, 225, brown)
		c.triangle(357, 145, 307, 195, 352, 225, brown)
		c.ellipse(256, 285, 128, 148, brown)
		c.ellipse(256, 350, 70, 62, tan_)
		c.circle(210, 240, 46, white)
		c.circle(302, 240, 46, white)
		c.circle(216, 244, 19, dark)
		c.circle(296, 244, 19, dark)
		c.triangle(238, 278, 274, 278, 256, 305, yellow)
	},
	"snail": func(c *canvas) {
		c.rect(388, 235, 10, 75, cream)
		c.rect(420, 250, 10, 60, cream)
		c.circle(393, 228, 12, dark)
		c.circle(425, 243, 12, dark)
		c.ellipse(280, 365, 150, 48, cream)
		c.circle(385, 340, 44, cream)
		c.circle(215, 280, 108, shell)
		c.circle(215, 280, 78, shellL)
		c.circle(215, 280, 48, shell)
		c.circle(215, 280, 22, shellL)
	},
	"squirrel": func(c *canvas) {
		c.ellipse(350, 195, 95, 140, orange)
		c.triangle(165, 190, 205, 190, 178, 150, orange)
		c.triangle(215, 185, 255, 185, 235, 145, orange)
		c.circle(220, 290, 120, orange)
		c.ellipse(210, 335, 60, 42, cream)
		c.circle(190, 275, 11, dark)
		c.circle(240, 275, 11, dark)
		c.circle(212, 305, 8, dark)
	},
	"deer": func(c *canvas) {
		c.triangle(190, 175, 165, 70, 215, 165, brown)
		c.triangle(322, 175, 347, 70, 297, 165, brown)
		c.ellipse(256, 300, 130, 150, tan_)
		c.ellipse(256, 350, 68, 55, cream)
		c.circle(212, 255, 13, dark)
		c.circle(300, 255, 13, dark)
		c.circle(256, 300, 9, dark)
	},
	"bird": func(c *canvas) {
		c.circle(246, 280, 125, blue)
		c.ellipse(200, 310, 55, 70, blueLt)
		c.ellipse(300, 335, 58, 40, orange)
		c.triangle(355, 250, 405, 262, 357, 282, yellow)
		c.circle(300, 222, 13, dark)
	},
	"frog": func(c *canvas) {
		c.ellipse(256, 320, 140, 95, green1)
		c.circle(200, 235, 42, green2)
		c.circle(312, 235, 42, green2)
		c.circle(200, 230, 16, dark)
		c.circle(312, 230, 16, dark)
		c.rect(206, 355, 100, 10, dark)
	},
	"bee": func(c *canvas) {
		c.ellipse(160, 250, 78, 58, blueLt)
		c.ellipse(352, 250, 78, 58, blueLt)
		c.ellipse(256, 300, 130, 100, yellow)
		c.rect(136, 260, 240, 30, dark)
		c.rect(136, 320, 240, 30, dark)
		c.circle(226, 275, 12, dark)
		c.circle(286, 275, 12, dark)
	},
	"ladybug": func(c *canvas) {
		c.circle(256, 300, 130, red)
		c.rect(250, 175, 12, 125, dark)
		c.circle(200, 260, 18, dark)
		c.circle(310, 260, 18, dark)
		c.circle(210, 340, 16, dark)
		c.circle(300, 340, 16, dark)
		c.circle(256, 190, 60, dark)
	},
	"acorn": func(c *canvas) {
		c.ellipse(256, 230, 105, 70, brown)
		c.rect(246, 160, 20, 45, brownL)
		c.ellipse(256, 340, 90, 110, tan_)
	},
	"raccoon": func(c *canvas) {
		c.ellipse(350, 250, 70, 120, grey)
		c.rect(310, 200, 70, 24, dark)
		c.rect(310, 260, 70, 24, dark)
		c.rect(310, 320, 70, 24, dark)
		c.circle(210, 290, 120, grey)
		c.ellipse(210, 340, 55, 40, cream)
		c.ellipse(178, 275, 32, 20, dark)
		c.ellipse(248, 275, 32, 20, dark)
		c.circle(178, 275, 8, white)
		c.circle(248, 275, 8, white)
	},
	"mouse": func(c *canvas) {
		c.circle(190, 195, 45, grey)
		c.circle(300, 195, 45, grey)
		c.circle(190, 195, 24, pink)
		c.circle(300, 195, 24, pink)
		c.circle(256, 300, 115, grey)
		c.circle(256, 320, 12, pink)
		c.circle(220, 280, 10, dark)
		c.circle(292, 280, 10, dark)
	},
	"pinecone": func(c *canvas) {
		c.ellipse(256, 290, 95, 145, brown)
		c.circle(220, 190, 28, tan_)
		c.circle(292, 190, 28, tan_)
		c.circle(256, 226, 30, tan_)
		c.circle(220, 262, 30, tan_)
		c.circle(292, 262, 30, tan_)
		c.circle(256, 298, 32, tan_)
		c.circle(220, 334, 30, tan_)
		c.circle(292, 334, 30, tan_)
		c.circle(256, 370, 28, tan_)
	},
}

func drawSticker(id string) image.Image {
	img := newImage(stickerSize, stickerSize)
	draw := stickerDrawers[id]
	if draw == nil {
		draw = genericBlob(id)
	}
	// Border pass: same shapes, scaled up, all white — the baked-in sticker edge.
	draw(&canvas{img: img, scale: 1.13, override: &white, cx: 256, cy: 256})
	draw(&canvas{img: img, scale: 1.0, cx: 256, cy: 256})
	return img
}

// genericBlob gives unknown sticker IDs a deterministic, distinct placeholder.
func genericBlob(id string) func(*canvas) {
	h := fnv.New32a()
	h.Write([]byte(id))
	v := h.Sum32()
	col := color.RGBA{100 + uint8(v%140), 100 + uint8((v>>8)%140), 100 + uint8((v>>16)%140), 255}
	return func(c *canvas) {
		c.circle(256, 256, 150, col)
		c.circle(200, 230, 20, dark)
		c.circle(312, 230, 20, dark)
		c.ellipse(256, 310, 50, 25, dark)
	}
}

// ---- scenery (2048×1536, wide 3072×1536) ------------------------------------

const sceneW, sceneH = 2048, 1536

// sceneWideW is the 2:1 rendition: the base scene sits centred in it.
const sceneWideW = 3072

// drawBackground renders the sky, sun, clouds and hills at width w. The
// base composition is centred; a wider canvas just gets more sky, hills
// and an extra cloud per side.
func drawBackground(w int) image.Image {
	img := newImage(w, sceneH)
	off := float64(w-sceneW) / 2
	// Sky gradient.
	top := color.RGBA{126, 200, 232, 255}
	bottom := color.RGBA{234, 246, 255, 255}
	for y := 0; y < sceneH; y++ {
		t := float64(y) / sceneH
		row := color.RGBA{
			uint8(float64(top.R) + t*float64(int(bottom.R)-int(top.R))),
			uint8(float64(top.G) + t*float64(int(bottom.G)-int(top.G))),
			uint8(float64(top.B) + t*float64(int(bottom.B)-int(top.B))),
			255,
		}
		for x := 0; x < w; x++ {
			img.SetRGBA(x, y, row)
		}
	}
	c := &canvas{img: img, scale: 1, cx: float64(w) / 2, cy: sceneH / 2}
	// Sun.
	c.circle(off+1720, 260, 150, color.RGBA{255, 233, 168, 255})
	c.circle(off+1720, 260, 105, color.RGBA{255, 246, 208, 255})
	// Clouds (plus one per margin on the wide rendition).
	clouds := [][3]float64{{380, 300, 1}, {980, 190, 0.8}, {1450, 420, 0.7}}
	if off > 0 {
		clouds = append(clouds, [3]float64{-off / 2, 360, 0.75}, [3]float64{sceneW + off/2, 240, 0.85})
	}
	for _, cl := range clouds {
		x, y, s := off+cl[0], cl[1], cl[2]
		c.ellipse(x, y, 150*s, 60*s, white)
		c.ellipse(x-95*s, y+18*s, 100*s, 45*s, white)
		c.ellipse(x+105*s, y+22*s, 110*s, 48*s, white)
	}
	// Hills, back to front; the outer two are stretched to span any width.
	c.ellipse(off+500, 1500, 1350+off, 600, color.RGBA{168, 216, 160, 255})
	c.ellipse(off+1650, 1580, 1400+off, 640, color.RGBA{143, 204, 138, 255})
	c.ellipse(off+1024, 1780, 1650+off, 700, color.RGBA{122, 191, 116, 255})
	return img
}

// drawForeground renders the grass band, the big tree and the bush at
// width w. The tree and bush hug the canvas edges whatever the width, so the
// wide rendition's margins get them and the base composition stays clear.
func drawForeground(w int) image.Image {
	img := newImage(w, sceneH) // transparent
	c := &canvas{img: img, scale: 1, cx: float64(w) / 2, cy: sceneH / 2}
	fw := float64(w)
	grass := color.RGBA{95, 175, 90, 255}
	grassDk := color.RGBA{82, 156, 78, 255}
	// Grass band along the bottom with a scalloped top edge.
	c.rect(0, 1400, fw, 136, grass)
	for x := 0.0; x < fw; x += 128 {
		c.ellipse(x+64, 1408, 78, 26, grass)
	}
	c.rect(0, 1472, fw, 64, grassDk)
	// Big tree on the left edge.
	c.rect(120, 880, 110, 560, brown)
	c.circle(175, 780, 210, green1)
	c.circle(40, 900, 150, green2)
	c.circle(330, 890, 160, green2)
	// Bush on the right edge.
	c.circle(fw-68, 1370, 150, green2)
	c.circle(fw-198, 1400, 120, green1)
	c.circle(fw+12, 1430, 130, green1)
	return img
}
