package render

import (
	"strings"
	"testing"

	"stickerstories/tools/internal/elevenlabs"
	"stickerstories/tools/internal/story"
)

// fakeAlignment gives each rune 0.1 s.
func fakeAlignment(plain string) *elevenlabs.Alignment {
	var al elevenlabs.Alignment
	for i, r := range []rune(plain) {
		al.Characters = append(al.Characters, string(r))
		al.Starts = append(al.Starts, float64(i)*0.1)
		al.Ends = append(al.Ends, float64(i+1)*0.1)
	}
	return &al
}

func TestTriggersAndSounds(t *testing.T) {
	text := "{tree:float loop 0.4} Fox {fox:hop x2} jumped. Whoosh! Then {fox:tint #FFB3C6 hold} blushed, ¡ay! {fox:fade-out hold}"
	cues, plain, errs := story.ParseCues(text)
	if len(errs) > 0 {
		t.Fatal(errs)
	}
	tl, err := NewTimeline(plain, fakeAlignment(plain))
	if err != nil {
		t.Fatal(err)
	}
	tr := Triggers(cues, tl)
	if len(tr) != 4 {
		t.Fatalf("want 4 triggers, got %d", len(tr))
	}
	if tr[0].At != 0 || tr[0].Repeat != "loop" || tr[0].Intensity != 0.4 {
		t.Errorf("scenery loop wrong: %+v", tr[0])
	}
	// "jumped." starts at rune 4 → 0.4 s
	if tr[1].At != 0.4 || tr[1].Repeat != 2 || tr[1].Cue != "jumped" {
		t.Errorf("hop wrong: %+v", tr[1])
	}
	if tr[2].Color != "#FFB3C6" || !tr[2].Hold || tr[2].Cue != "blushed" {
		t.Errorf("tint wrong: %+v", tr[2])
	}
	if tr[3].Cue != "ay" || tr[3].At <= tr[2].At {
		t.Errorf("trailing cue should fire on last word: %+v", tr[3])
	}
	data, err := EncodeSidecar(tr, map[string]bool{"tree": true, "fox": true}, "outdoors")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"schema": 1`) {
		t.Errorf("sidecar missing schema: %s", data)
	}
	placed, missing := PlaceSounds([]story.SoundHint{{Cue: "whoosh"}, {Cue: "nope"}}, tl)
	if len(placed) != 1 || placed[0].At != 1.2 || len(missing) != 1 {
		t.Errorf("placement: %+v missing %v", placed, missing)
	}
}

func TestCanvasCuesBecomeStickerlessTriggers(t *testing.T) {
	text := "{canvas:fog 0.5} Plip, plop. {canvas:rain 0.7 14s} Here comes the {fox:hop} rain."
	cues, plain, errs := story.ParseCues(text)
	if len(errs) > 0 {
		t.Fatal(errs)
	}
	tl, err := NewTimeline(plain, fakeAlignment(plain))
	if err != nil {
		t.Fatal(err)
	}
	tr := Triggers(cues, tl)
	if len(tr) != 3 {
		t.Fatalf("want 3 triggers, got %d", len(tr))
	}
	if tr[0].At != 0 || tr[0].Effect != "fog" || tr[0].Sticker != "" || tr[0].Intensity != 0.5 {
		t.Errorf("fog wrong: %+v", tr[0])
	}
	if tr[1].Effect != "rain" || tr[1].Sticker != "" || tr[1].Duration != 14 || tr[1].Cue != "here" || tr[1].Repeat != nil {
		t.Errorf("rain wrong: %+v", tr[1])
	}
	data, err := EncodeSidecar(tr, map[string]bool{"fox": true}, "outdoors")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), `"sticker": ""`) {
		t.Errorf("canvas triggers must not carry a sticker key: %s", data)
	}
	if _, err := EncodeSidecar(tr, map[string]bool{"fox": true}, "indoors"); err == nil {
		t.Errorf("rain and fog must be rejected for an indoors pack")
	}
}

func TestTimelineScalesWhenAlignmentDiffers(t *testing.T) {
	plain := "one two three"
	al := fakeAlignment("one  two  three  ") // longer normalised text
	tl, err := NewTimeline(plain, al)
	if err != nil {
		t.Fatal(err)
	}
	if tl.At(0) != 0 || tl.At(2) <= tl.At(1) || tl.At(1) <= 0 {
		t.Errorf("monotonic timings expected: %v %v %v", tl.At(0), tl.At(1), tl.At(2))
	}
}
