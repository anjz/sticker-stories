package main

import (
	"math"
	"strings"
	"testing"

	"stickerstories/tools/internal/audio"
	"stickerstories/tools/internal/elevenlabs"
)

// fakeTake builds a take for text at 1000 Hz where every character lasts
// 10 ms and sounds (amplitude 0.5), except spaces in quiet, which are
// silent: the shape of a narrator pausing between sentences.
func fakeTake(text string, quiet map[int]bool) (*audio.Clip, *elevenlabs.Alignment) {
	const rate, per = 1000, 0.01
	runes := []rune(text)
	c := audio.Silence(rate, float64(len(runes))*per)
	al := &elevenlabs.Alignment{}
	for i, r := range runes {
		al.Characters = append(al.Characters, string(r))
		al.Starts = append(al.Starts, float64(i)*per)
		al.Ends = append(al.Ends, float64(i+1)*per)
		if quiet[i] {
			continue
		}
		for j := i * 10; j < (i+1)*10; j++ {
			c.Samples[j] = 0.5
		}
	}
	return c, al
}

func TestSplitTakeCutsInThePause(t *testing.T) {
	pieces := []piece{{text: "One two."}, {text: ""}, {text: "Three."}}
	take := takeText(pieces)
	if take != "One two. Three." {
		t.Fatalf("takeText = %q", take)
	}
	// A long pause (the joining space and a run of silence) before "Three".
	text := "One two." + strings.Repeat(" ", 1) + "Three."
	quiet := map[int]bool{3: true, 8: true}
	clip, al := fakeTake(text, quiet)
	// Stretch the pause: make the "." of "two." silent too, so the
	// quietest stretch spans 7–9 (70–90 ms).
	for j := 70; j < 80; j++ {
		clip.Samples[j] = 0
	}
	got, err := splitTake(pieces, clip, al)
	if err != nil {
		t.Fatal(err)
	}
	if got[1].clip != nil {
		t.Errorf("empty piece got a stretch")
	}
	first, second := got[0], got[2]
	if n := len(first.alignment.Characters); n != len([]rune("One two.")) {
		t.Errorf("first stretch has %d characters", n)
	}
	if strings.Join(second.alignment.Characters, "") != "Three." {
		t.Errorf("second stretch = %q", strings.Join(second.alignment.Characters, ""))
	}
	cut := first.clip.Duration()
	if cut < 0.07 || cut > 0.09 {
		t.Errorf("cut at %.3f s, want inside the pause (0.07–0.09)", cut)
	}
	if math.Abs(first.clip.Duration()+second.clip.Duration()-clip.Duration()) > 0.002 {
		t.Errorf("stretches %.3f + %.3f s do not add up to the take's %.3f s", first.clip.Duration(), second.clip.Duration(), clip.Duration())
	}
	// "Three" is re-timed from the cut: its T starts 90 ms into the take.
	if want := 0.09 - cut; math.Abs(second.alignment.Starts[0]-want) > 1e-9 {
		t.Errorf("second stretch starts at %.3f, want %.3f", second.alignment.Starts[0], want)
	}
}

func TestSplitTakeRejectsMismatchedAlignment(t *testing.T) {
	clip, al := fakeTake("Hello there", nil)
	if _, err := splitTake([]piece{{text: "Hello"}}, clip, al); err == nil {
		t.Error("want an error when the alignment does not match the take text")
	}
}

func TestParseStability(t *testing.T) {
	for in, want := range map[string]float64{"natural": 0.5, "creative": 0, "robust": 1, "0.35": 0.35} {
		if got, err := parseStability(in); err != nil || got != want {
			t.Errorf("parseStability(%q) = %v, %v; want %v", in, got, err, want)
		}
	}
	for _, in := range []string{"1.2", "-0.1", "loud"} {
		if _, err := parseStability(in); err == nil {
			t.Errorf("parseStability(%q): want an error", in)
		}
	}
}
