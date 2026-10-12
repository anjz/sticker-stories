package manifest

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// validRig writes the fox's rig (and its atlas) under dir.
func validRig(t *testing.T, dir string, mutate func(r *PuppetRig)) {
	t.Helper()
	r := PuppetRig{
		Sticker: "fox", Atlas: "anims/fox.rig.webp", Size: 768,
		Parts: map[string]PuppetPart{"body": {Rect: [4]int{0, 0, 10, 10}, Border: [4]int{12, 0, 14, 14}, Pad: 2},
			"eye": {Rect: [4]int{0, 20, 4, 4}, Border: [4]int{6, 20, 8, 8}, Pad: 2}},
		Bones: []PuppetBone{{ID: "root", X: 380, Y: 700}, {ID: "head", Parent: "root", X: 380, Y: 360}},
		Slots: []PuppetSlot{
			{ID: "body", Bone: "root", Default: "body", Attachments: map[string]PuppetAttachment{"body": {Part: "body", W: 400, H: 400}}},
			{ID: "eye", Bone: "head", Default: "open", Attachments: map[string]PuppetAttachment{"open": {Part: "eye", W: 60, H: 60}, "shut": {Part: "eye", W: 60, H: 20}}},
		},
		Faces: map[string]map[string]string{"sleeping": {"eye": "shut"}},
		Idle:  &PuppetIdle{Breathe: "root", Blink: map[string]string{"eye": "shut"}},
	}
	if mutate != nil {
		mutate(&r)
	}
	os.MkdirAll(filepath.Join(dir, "anims"), 0o755)
	os.WriteFile(filepath.Join(dir, "anims", "fox.rig.webp"), []byte("x"), 0o644)
	data, _ := json.Marshal(r)
	os.WriteFile(filepath.Join(dir, "anims", "fox.rig.json"), data, 0o644)
}

func puppetFor(keys int) *AnimationPuppet {
	p := &AnimationPuppet{Rig: "anims/fox.rig.json"}
	for i := 0; i < keys; i++ {
		p.Keys = append(p.Keys, PuppetKey{Hold: 0.3})
	}
	return p
}

func TestPuppetsValidate(t *testing.T) {
	one := 1.2
	cases := []struct {
		name   string
		rig    func(r *PuppetRig)
		anim   func(a *StickerAnimation)
		expect string
	}{
		{"valid", nil, nil, ""},
		{"bone before its parent", func(r *PuppetRig) { r.Bones[0], r.Bones[1] = r.Bones[1], r.Bones[0] }, nil, "parent"},
		{"slot on no bone", func(r *PuppetRig) { r.Slots[0].Bone = "tail" }, nil, `bone "tail"`},
		{"attachment of no part", func(r *PuppetRig) { r.Slots[1].Attachments["open"] = PuppetAttachment{Part: "nose", W: 1, H: 1} }, nil, `part "nose"`},
		{"default hidden", func(r *PuppetRig) { r.Slots[1].Default = PuppetHidden }, nil, ""},
		{"face of no attachment", func(r *PuppetRig) { r.Faces["happy"] = map[string]string{"eye": "wink"} }, nil, `"wink"`},
		{"blink of no attachment", func(r *PuppetRig) { r.Idle.Blink = map[string]string{"eye": "wink"} }, nil, "blink"},
		{"missing atlas", func(r *PuppetRig) { r.Atlas = "anims/none.webp" }, nil, "not found"},
		{"one key", nil, func(a *StickerAnimation) { a.Puppet = puppetFor(1) }, "two keys"},
		{"key of no bone", nil, func(a *StickerAnimation) { a.Puppet.Keys[1].Bones = map[string]BonePose{"tail": {R: 10}} }, `bone "tail"`},
		{"squashed flat", nil, func(a *StickerAnimation) {
			zero := 0.0
			a.Puppet.Keys[1].Bones = map[string]BonePose{"head": {SY: &zero}}
		}, "stretch"},
		{"turned round", nil, func(a *StickerAnimation) {
			back := -1.0
			a.Puppet.Keys[2].Bones = map[string]BonePose{"root": {SX: &back}}
		}, ""},
		{"key of no attachment", nil, func(a *StickerAnimation) { a.Puppet.Keys[2].Slots = map[string]string{"eye": "wink"} }, `"wink"`},
		{"unknown ease", nil, func(a *StickerAnimation) { a.Puppet.Keys[0].Ease = "bounce" }, "ease"},
		{"pause without the sheet's", nil, func(a *StickerAnimation) { p := 2; a.Puppet.Pause = &p }, "pause"},
		{"loop on an action", nil, func(a *StickerAnimation) { a.Puppet.Loop = &FrameRange{From: 1, To: 2} }, "belong to a move"},
		{"a move's loop", nil, func(a *StickerAnimation) {
			a.Kind, a.Loop, a.Facing, a.Stride = KindMove, &FrameRange{From: 1, To: 6}, "right", 0.5
			a.Puppet.Loop, a.Puppet.Stride = &FrameRange{From: 1, To: 3}, one
		}, ""},
		{"a move's loop without stride", nil, func(a *StickerAnimation) {
			a.Kind, a.Loop, a.Facing, a.Stride = KindMove, &FrameRange{From: 1, To: 6}, "right", 0.5
			a.Puppet.Loop = &FrameRange{From: 1, To: 3}
		}, "stride"},
		{"rig not json", nil, func(a *StickerAnimation) { a.Puppet.Rig = "anims/fox.rig.webp" }, ".json"},
		// Without a sheet the keys are the frames.
		{"puppet only", nil, sheetless(nil), ""},
		{"puppet only, paused on a key", nil, sheetless(func(a *StickerAnimation) { a.Pause = &AnimationPause{Frame: 3, Shows: "asleep"} }), ""},
		{"puppet only, paused past the keys", nil, sheetless(func(a *StickerAnimation) { a.Pause = &AnimationPause{Frame: 4, Shows: "asleep"} }), "middle frame (1–3)"},
		{"puppet only, its own pause", nil, sheetless(func(a *StickerAnimation) { p := 2; a.Puppet.Pause = &p }), "sidecar's own"},
		{"puppet only with frames", nil, sheetless(func(a *StickerAnimation) { a.Hold = []float64{0.3} }), "belong to a sheet"},
		{"puppet only, a move", nil, sheetless(func(a *StickerAnimation) {
			a.Kind, a.Loop, a.Facing, a.Stride = KindMove, &FrameRange{From: 1, To: 3}, "right", 0.5
		}), ""},
		{"puppet only, a loop from rest", nil, sheetless(func(a *StickerAnimation) {
			a.Kind, a.Loop, a.Facing, a.Stride = KindMove, &FrameRange{From: 0, To: 3}, "right", 0.5
		}), "after key 0"},
		{"puppet only, a particle past the keys", nil, sheetless(func(a *StickerAnimation) {
			a.Particles = []AnimationParticle{{Frame: 5, Effect: "dust-puff", X: 0.5, Y: 0.9}}
		}), "not one of the 5 frames"},
		{"neither sheet nor puppet", nil, func(a *StickerAnimation) { a.Sheet, a.Puppet = "", nil }, "sheet must not be empty"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			validRig(t, dir, tc.rig)
			rel := validAnimation(t, dir, func(a *StickerAnimation) {
				a.Puppet = puppetFor(5)
				if tc.anim != nil {
					tc.anim(a)
				}
			})
			a, err := LoadStickerAnimation(filepath.Join(dir, rel))
			if err != nil {
				t.Fatal(err)
			}
			errs := a.Validate(dir, "fox")
			if tc.expect == "" {
				if len(errs) > 0 {
					t.Fatalf("want valid, got %v", errs)
				}
				return
			}
			for _, e := range errs {
				if strings.Contains(e.Error(), tc.expect) {
					return
				}
			}
			t.Fatalf("want an error with %q, got %v", tc.expect, errs)
		})
	}
}

// sheetless makes the animation its puppet's alone: no sheet, no frames.
func sheetless(mutate func(a *StickerAnimation)) func(a *StickerAnimation) {
	return func(a *StickerAnimation) {
		a.Sheet, a.Columns, a.Count, a.Hold, a.Rest = "", 0, 0, nil, UnitBox{}
		a.Frame.Width, a.Frame.Height = 0, 0
		if mutate != nil {
			mutate(a)
		}
	}
}

func TestPuppetOnlyTiming(t *testing.T) {
	a := StickerAnimation{Puppet: &AnimationPuppet{Keys: []PuppetKey{{Hold: 0.25}, {Hold: 0.5}, {Hold: 1}, {Hold: 0.25}}}, Pause: &AnimationPause{Frame: 2}}
	if !a.PuppetOnly() || a.Frames() != 4 || a.Duration() != 2 {
		t.Fatalf("puppet only %v, frames %d, duration %g", a.PuppetOnly(), a.Frames(), a.Duration())
	}
	if to, from := a.PlaySeconds(); to != 0.75 || from != 0.25 {
		t.Fatalf("play seconds %g, %g; want 0.75, 0.25", to, from)
	}
	data, _ := json.Marshal(a)
	for _, field := range []string{`"frame":{`, `"rest"`, `"hold":[`, `"columns"`, `"sheet"`} {
		if strings.Contains(string(data), field) {
			t.Fatalf("a puppet's sidecar writes %s: %s", field, data)
		}
	}
}
