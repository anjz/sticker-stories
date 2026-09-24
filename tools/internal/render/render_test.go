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
	tl, err := NewPlainTimeline(plain, fakeAlignment(plain))
	if err != nil {
		t.Fatal(err)
	}
	tr, err := Triggers(cues, tl, story.Manifest{})
	if err != nil {
		t.Fatal(err)
	}
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
	data, err := EncodeSidecar(tr, map[string]bool{"tree": true, "fox": true}, nil, nil, "outdoors")
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
	tl, err := NewPlainTimeline(plain, fakeAlignment(plain))
	if err != nil {
		t.Fatal(err)
	}
	tr, err := Triggers(cues, tl, story.Manifest{})
	if err != nil {
		t.Fatal(err)
	}
	if len(tr) != 3 {
		t.Fatalf("want 3 triggers, got %d", len(tr))
	}
	if tr[0].At != 0 || tr[0].Effect != "fog" || tr[0].Sticker != "" || tr[0].Intensity != 0.5 {
		t.Errorf("fog wrong: %+v", tr[0])
	}
	if tr[1].Effect != "rain" || tr[1].Sticker != "" || tr[1].Duration != 14 || tr[1].Cue != "here" || tr[1].Repeat != nil {
		t.Errorf("rain wrong: %+v", tr[1])
	}
	data, err := EncodeSidecar(tr, map[string]bool{"fox": true}, nil, nil, "outdoors")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), `"sticker": ""`) {
		t.Errorf("canvas triggers must not carry a sticker key: %s", data)
	}
	if _, err := EncodeSidecar(tr, map[string]bool{"fox": true}, nil, nil, "indoors"); err == nil {
		t.Errorf("rain and fog must be rejected for an indoors pack")
	}
}

func TestLiveCuesNameTheirAnimation(t *testing.T) {
	text := "{owl:float loop 0.3} Bear {bear:live} yawned. Owl {owl:live blink} blinked."
	cues, plain, errs := story.ParseCues(text)
	if len(errs) > 0 {
		t.Fatal(errs)
	}
	tl, err := NewPlainTimeline(plain, fakeAlignment(plain))
	if err != nil {
		t.Fatal(err)
	}
	pack := story.Manifest{Animations: map[string][]story.Animation{
		"bear": {{ID: "yawn"}},
		"owl":  {{ID: "blink"}, {ID: "hoot"}},
	}}
	tr, err := Triggers(cues, tl, pack)
	if err != nil {
		t.Fatal(err)
	}
	if len(tr) != 3 || tr[1].Animation != "yawn" || tr[1].Effect != "" || tr[1].Cue != "yawned" || tr[2].Animation != "blink" {
		t.Fatalf("live triggers wrong: %+v", tr)
	}
	anims := map[string][]string{"bear": {"yawn"}, "owl": {"blink", "hoot"}}
	data, err := EncodeSidecar(tr, map[string]bool{"bear": true, "owl": true}, anims, nil, "outdoors")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), `"effect": ""`) || !strings.Contains(string(data), `"animation": "yawn"`) {
		t.Errorf("live trigger encoding: %s", data)
	}
	// An ambiguous or unknown animation is an error, not a silent pick.
	if _, err := Triggers([]story.Cue{{Sticker: "owl", Effect: "live", Raw: "{owl:live}"}}, tl, pack); err == nil {
		t.Errorf("owl has two animations; {owl:live} must name one")
	}
}

func TestSegmentsWithTagsAssembleOnOneClock(t *testing.T) {
	text := "[softly] Night came. {sfx:owl solo} [whispers] Who is {fox:hop} there? {sfx:owl} The end."
	nar, errs := story.Parse(text)
	if len(errs) > 0 {
		t.Fatal(errs)
	}
	segs := nar.Segments()
	if len(segs) != 2 {
		t.Fatalf("want 2 segments, got %+v", segs)
	}
	var parts []*Timeline
	offset := 0.0
	for _, seg := range segs {
		if seg.Solo >= 0 {
			offset += 2.5 // the solo sound and its breaths
		}
		spoken, starts := nar.Spoken(seg.From, seg.To)
		tl, err := NewTimeline(spoken, starts, fakeAlignment(spoken))
		if err != nil {
			t.Fatal(err)
		}
		// A tag's characters are in the alignment but are not words.
		if len(tl.Words) != seg.To-seg.From {
			t.Errorf("segment %+v: %d words from %q", seg, len(tl.Words), spoken)
		}
		parts = append(parts, tl.Shifted(offset))
		offset += tl.Length
	}
	tl := Assemble(parts...)
	if len(tl.Words) != len(nar.Words) || tl.Words[2].Text != "Who" {
		t.Fatalf("assembled words wrong: %+v", tl.Words)
	}
	// "Who" is preceded by "[whispers] " (11 runes at 0.1 s each) in a
	// segment that starts after the first segment (2.0 s) and the solo (2.5 s).
	if got := tl.At(2); got < 4.5+1.0 || got > 4.5+1.2 {
		t.Errorf("Who at %.2f, want ≈5.6", got)
	}
	// Sound cues are not sidecar triggers.
	tr, err := Triggers(nar.Cues, tl, story.Manifest{})
	if err != nil {
		t.Fatal(err)
	}
	if len(tr) != 1 || tr[0].Effect != "hop" || tr[0].Sticker != "fox" {
		t.Errorf("triggers: %+v", tr)
	}
	if tr[0].At <= tl.At(2) {
		t.Errorf("hop should fire after Who: %+v", tr[0])
	}
}

func TestTimelineScalesWhenAlignmentDiffers(t *testing.T) {
	plain := "one two three"
	al := fakeAlignment("one  two  three  ") // longer normalised text
	tl, err := NewPlainTimeline(plain, al)
	if err != nil {
		t.Fatal(err)
	}
	if tl.At(0) != 0 || tl.At(2) <= tl.At(1) || tl.At(1) <= 0 {
		t.Errorf("monotonic timings expected: %v %v %v", tl.At(0), tl.At(1), tl.At(2))
	}
}

func TestFaceAndAllCues(t *testing.T) {
	text := "{all:face happy} Everyone smiled. Then {all:hop} they all jumped, and {bear:face sleeping} Bear fell asleep."
	cues, plain, errs := story.ParseCues(text)
	if len(errs) > 0 {
		t.Fatal(errs)
	}
	tl, err := NewPlainTimeline(plain, fakeAlignment(plain))
	if err != nil {
		t.Fatal(err)
	}
	tr, err := Triggers(cues, tl, story.Manifest{})
	if err != nil {
		t.Fatal(err)
	}
	if len(tr) != 3 || tr[0].Sticker != "all" || tr[0].Expression != "happy" || tr[0].Effect != "" ||
		tr[1].Sticker != "all" || tr[1].Effect != "hop" || tr[2].Expression != "sleeping" || tr[2].Cue != "bear" {
		t.Fatalf("face/all triggers wrong: %+v", tr)
	}
	faces := map[string][]string{"bear": {"happy", "sleeping"}}
	if _, err := EncodeSidecar(tr, map[string]bool{"bear": true}, nil, faces, "outdoors"); err != nil {
		t.Fatal(err)
	}
}

func TestEnterCues(t *testing.T) {
	text := "{fox:enter} {fox:hop} Fox ran in. Later {owl:enter} Owl woke."
	cues, plain, errs := story.ParseCues(text)
	if len(errs) > 0 {
		t.Fatal(errs)
	}
	tl, err := NewPlainTimeline(plain, fakeAlignment(plain))
	if err != nil {
		t.Fatal(err)
	}
	tr, err := Triggers(cues, tl, story.Manifest{})
	if err != nil {
		t.Fatal(err)
	}
	if len(tr) != 3 || !tr[0].Enter || tr[0].At != 0 || tr[0].Effect != "" || tr[1].Effect != "hop" ||
		!tr[2].Enter || tr[2].Sticker != "owl" || tr[2].Cue != "owl" || tr[2].At <= 0 {
		t.Fatalf("enter triggers wrong: %+v", tr)
	}
	data, err := EncodeSidecar(tr, map[string]bool{"fox": true, "owl": true}, nil, nil, "outdoors")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"enter": true`) {
		t.Errorf("sidecar lost the entrance: %s", data)
	}
}
