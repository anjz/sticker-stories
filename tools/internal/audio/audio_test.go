package audio

import (
	"math"
	"testing"
)

func tone(rate int, seconds, amp float64) *Clip {
	c := Silence(rate, seconds)
	for i := range c.Samples {
		c.Samples[i] = float32(amp * math.Sin(2*math.Pi*440*float64(i)/float64(rate)))
	}
	return c
}

func TestPCMRoundTrip(t *testing.T) {
	c := tone(8000, 0.1, 0.5)
	back := FromPCM16(c.ToPCM16(), 8000)
	if len(back.Samples) != len(c.Samples) {
		t.Fatalf("length %d != %d", len(back.Samples), len(c.Samples))
	}
	for i := range c.Samples {
		if d := math.Abs(float64(c.Samples[i] - back.Samples[i])); d > 1e-3 {
			t.Fatalf("sample %d differs by %f", i, d)
		}
	}
}

func TestNormalizeRMS(t *testing.T) {
	c := tone(8000, 1, 0.1)
	c.NormalizeRMS(-20, 0.95)
	if got := 20 * math.Log10(c.RMS()); math.Abs(got+20) > 0.5 {
		t.Errorf("rms = %.2f dB, want -20", got)
	}
	loud := tone(8000, 1, 0.9)
	loud.NormalizeRMS(0, 0.95)
	if p := loud.Peak(); p > 0.951 {
		t.Errorf("peak %f exceeds ceiling", p)
	}
}

func TestMixLoopDuck(t *testing.T) {
	base := Silence(8000, 1)
	base.MixAt(tone(8000, 0.5, 0.5), 0.75, 1)
	if base.Duration() < 1.25-1e-6 {
		t.Errorf("mix should extend: %f", base.Duration())
	}
	looped := tone(8000, 0.3, 0.5).LoopTo(2, 0.05)
	if math.Abs(looped.Duration()-2) > 1e-6 {
		t.Errorf("loop length %f", looped.Duration())
	}
	music := tone(8000, 2, 0.5)
	voice := Silence(8000, 2)
	voice.MixAt(tone(8000, 1, 0.5), 0, 1) // voice in first second only
	music.Duck(voice, 0.05, 0.25, 0.01, 0.05)
	first := (&Clip{Rate: 8000, Samples: music.Samples[2000:6000]}).RMS()
	second := (&Clip{Rate: 8000, Samples: music.Samples[12000:16000]}).RMS()
	if first > second*0.5 {
		t.Errorf("ducked %f should be well under undducked %f", first, second)
	}
}

func TestFadeAndTrim(t *testing.T) {
	c := tone(8000, 1, 0.5).Fade(0.1, 0.1)
	if c.Samples[0] != 0 || abs(c.Samples[len(c.Samples)-1]) > 1e-3 {
		t.Errorf("fade edges not zero")
	}
	p := Silence(8000, 0.5)
	p.MixAt(tone(8000, 0.5, 0.5), 0.5, 1)
	p.Pad(0, 0.5).TrimSilence(0.01, 0.05)
	if d := p.Duration(); d < 0.5 || d > 0.62 {
		t.Errorf("trimmed duration %f", d)
	}
}

func TestRamp(t *testing.T) {
	c := Silence(1000, 3)
	for i := range c.Samples {
		c.Samples[i] = 1
	}
	c.Ramp(0.5, 0.1, 1, 2)
	if c.Samples[500] != 0.5 || c.Samples[2500] != 0.1 {
		t.Errorf("flat parts wrong: %f %f", c.Samples[500], c.Samples[2500])
	}
	if mid := c.Samples[1500]; mid < 0.28 || mid > 0.32 {
		t.Errorf("midpoint %f, want ~0.3", mid)
	}
}

func TestCut(t *testing.T) {
	c := Silence(100, 3)
	for i := range c.Samples {
		c.Samples[i] = 0.5
	}
	c.Cut(1, 0.1)
	if len(c.Samples) != 100 || c.Samples[50] != 0.5 || c.Samples[99] != 0 {
		t.Errorf("cut to 1 s with a fade: len %d, mid %v, last %v", len(c.Samples), c.Samples[50], c.Samples[99])
	}
	if got := len(Silence(100, 0.5).Cut(1, 0.1).Samples); got != 50 {
		t.Errorf("a shorter clip should be left alone, got %d", got)
	}
}
