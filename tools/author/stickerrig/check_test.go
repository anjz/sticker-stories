package main

import (
	"image"
	"image/color"
	"strings"
	"testing"

	"stickerstories/tools/internal/manifest"
)

var (
	light = color.RGBA{230, 210, 180, 255}
	dark  = color.RGBA{60, 40, 20, 255}
)

// paintOutlined fills a mask light with a dark 3 px outline round its edge.
func paintOutlined(img *image.RGBA, off image.Point, w, h int, in func(x, y int) bool) {
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if !in(x, y) {
				continue
			}
			c := light
			for dy := -3; dy <= 3 && c == light; dy++ {
				for dx := -3; dx <= 3; dx++ {
					if !in(x+dx, y+dy) {
						c = dark
						break
					}
				}
			}
			img.SetRGBA(off.X+x, off.Y+y, c)
		}
	}
}

// eyeArt is an eye looking left: a white disc, its pupil at the left.
func eyeArt(img *image.RGBA, off image.Point, flip bool) {
	for y := 0; y < 20; y++ {
		for x := 0; x < 20; x++ {
			dx, dy := float64(x)-9.5, float64(y)-9.5
			if dx*dx+dy*dy > 90 {
				continue
			}
			c := color.RGBA{250, 250, 250, 255}
			px := x
			if flip {
				px = 19 - x
			}
			if px < 8 && dy*dy < 16 {
				c = color.RGBA{20, 20, 20, 255}
			}
			img.SetRGBA(off.X+x, off.Y+y, c)
		}
	}
}

func disc120(x, y int) bool {
	dx, dy := float64(x)-59.5, float64(y)-59.5
	return x >= 0 && y >= 0 && x < 120 && y < 120 && dx*dx+dy*dy <= 60*60
}

func rect30x80(x, y int) bool { return x >= 0 && y >= 0 && x < 30 && y < 80 }

// testPuppet is a disc of a body (centre 100, 90) with a limb hanging
// from its bottom (a 30×80 box from y 120, its bone at armY) and two eyes
// on a face bone, eyeR mirrored; the sticker has the same body and limb
// outlined as one shape, both eyes looking left. limbBehind draws the limb
// before the body.
func testPuppet(limbBehind bool, armY float64) *puppet {
	atlas := image.NewRGBA(image.Rect(0, 0, 220, 130))
	paintOutlined(atlas, image.Pt(0, 0), 120, 120, disc120)
	paintOutlined(atlas, image.Pt(130, 0), 30, 80, rect30x80)
	eyeArt(atlas, image.Pt(170, 0), false)
	sticker := image.NewRGBA(image.Rect(0, 0, 200, 200))
	paintOutlined(sticker, image.Pt(0, 0), 200, 200, func(x, y int) bool {
		return disc120(x-40, y-30) || rect30x80(x-85, y-120)
	})
	eyeArt(sticker, image.Pt(70, 70), false)
	eyeArt(sticker, image.Pt(110, 70), false)
	body := manifest.PuppetSlot{ID: "body", Bone: "body", Default: "body", Attachments: map[string]manifest.PuppetAttachment{
		"body": {Part: "body", X: 40, Y: 30, W: 120, H: 120}}}
	arm := manifest.PuppetSlot{ID: "arm", Bone: "arm", Default: "arm", Attachments: map[string]manifest.PuppetAttachment{
		"arm": {Part: "limb", X: 85, Y: 120, W: 30, H: 80}}}
	slots := []manifest.PuppetSlot{body, arm}
	if limbBehind {
		slots = []manifest.PuppetSlot{arm, body}
	}
	slots = append(slots,
		manifest.PuppetSlot{ID: "eyeL", Bone: "face", Default: "calm", Attachments: map[string]manifest.PuppetAttachment{
			"calm": {Part: "eye", X: 70, Y: 70, W: 20, H: 20}}},
		manifest.PuppetSlot{ID: "eyeR", Bone: "face", Default: "calm", Attachments: map[string]manifest.PuppetAttachment{
			"calm": {Part: "eye", X: 110, Y: 70, W: 20, H: 20, Flip: true}}})
	rig := &manifest.PuppetRig{
		Sticker: "blob", Size: 200,
		Parts: map[string]manifest.PuppetPart{
			"body": {Rect: [4]int{0, 0, 120, 120}}, "limb": {Rect: [4]int{130, 0, 30, 80}}, "eye": {Rect: [4]int{170, 0, 20, 20}},
		},
		Bones: []manifest.PuppetBone{
			{ID: "root", X: 100, Y: 195}, {ID: "body", Parent: "root", X: 100, Y: 150},
			{ID: "arm", Parent: "body", X: 100, Y: armY}, {ID: "face", Parent: "body", X: 100, Y: 80},
		},
		Slots: slots,
	}
	return newPuppet(rig, atlas, sticker)
}

func rules(found []finding) string {
	var out []string
	for _, f := range found {
		out = append(out, f.Rule+":"+f.Msg)
	}
	return strings.Join(out, "\n")
}

func has(found []finding, rule, about string) bool {
	for _, f := range found {
		if f.Rule == rule && strings.HasPrefix(f.Msg, about) {
			return true
		}
	}
	return false
}

func TestCheckFindsAJointEndDrawnOverTheBody(t *testing.T) {
	o := defaultCheckOptions()
	over := testPuppet(false, 128).check("blob", nil, o)
	if !has(over, "seam", "arm") {
		t.Fatalf("a limb over the body shows its joint end's outline:\n%s", rules(over))
	}
	behind := testPuppet(true, 128).check("blob", nil, o)
	if has(behind, "seam", "arm") {
		t.Fatalf("a limb tucked behind the body has no seam:\n%s", rules(behind))
	}
	if has(behind, "bone", "arm") {
		t.Fatalf("the bone is inside the joint end:\n%s", rules(behind))
	}
}

func TestCheckFindsABoneOutsideItsPiece(t *testing.T) {
	found := testPuppet(true, 100).check("blob", nil, defaultCheckOptions())
	if !has(found, "bone", "arm") {
		t.Fatalf("the arm's bone is 20 px above its piece:\n%s", rules(found))
	}
}

func TestCheckFindsMirroredEyes(t *testing.T) {
	found := testPuppet(true, 128).check("blob", nil, defaultCheckOptions())
	if !has(found, "eyes", "eyeL and eyeR") {
		t.Fatalf("eyeR is eyeL mirrored: they look opposite ways:\n%s", rules(found))
	}
	if !has(found, "mirror", "eyeR") || has(found, "mirror", "eyeL") {
		t.Fatalf("the sticker's eyes both look left: eyeR (flipped) is the wrong way round:\n%s", rules(found))
	}
}

func TestCheckFindsTheFaceSlidingOffTheHead(t *testing.T) {
	look := func(x float64) *manifest.StickerAnimation {
		return &manifest.StickerAnimation{ID: "look", Puppet: &manifest.AnimationPuppet{Keys: []manifest.PuppetKey{
			{Hold: 0.5}, {Hold: 0.5, Bones: map[string]manifest.BonePose{"face": {X: x}}}, {Hold: 0.5},
		}}}
	}
	o := defaultCheckOptions()
	if found := testPuppet(true, 128).check("blob", []*manifest.StickerAnimation{look(55)}, o); !has(found, "face", "the face slides") {
		t.Fatalf("a face shifted 55 px puts an eye off the body:\n%s", rules(found))
	}
	if found := testPuppet(true, 128).check("blob", []*manifest.StickerAnimation{look(5)}, o); has(found, "face", "") {
		t.Fatalf("a small shift keeps the eyes on:\n%s", rules(found))
	}
}
