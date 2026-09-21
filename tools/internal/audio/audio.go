// Package audio is a small mono PCM toolkit for the story pipeline: decode
// 16-bit little-endian PCM, mix layers with gain, fades and ducking,
// normalise loudness, write WAV, and encode to AAC .m4a with macOS afconvert.
// No third-party dependencies.
package audio

import (
	"encoding/binary"
	"fmt"
	"math"
	"os"
	"os/exec"
)

// Clip is mono float samples in [-1, 1] at Rate Hz.
type Clip struct {
	Rate    int
	Samples []float32
}

// FromPCM16 decodes 16-bit little-endian mono PCM.
func FromPCM16(data []byte, rate int) *Clip {
	n := len(data) / 2
	s := make([]float32, n)
	for i := 0; i < n; i++ {
		s[i] = float32(int16(binary.LittleEndian.Uint16(data[2*i:]))) / 32768
	}
	return &Clip{Rate: rate, Samples: s}
}

// ToPCM16 encodes the clip as 16-bit little-endian mono PCM.
func (c *Clip) ToPCM16() []byte {
	out := make([]byte, 2*len(c.Samples))
	for i, v := range c.Samples {
		binary.LittleEndian.PutUint16(out[2*i:], uint16(int16(clamp(v)*32767)))
	}
	return out
}

// Duration in seconds.
func (c *Clip) Duration() float64 { return float64(len(c.Samples)) / float64(c.Rate) }

// Silence returns a clip of the given length.
func Silence(rate int, seconds float64) *Clip {
	return &Clip{Rate: rate, Samples: make([]float32, int(seconds*float64(rate)))}
}

// Clone copies the clip.
func (c *Clip) Clone() *Clip {
	return &Clip{Rate: c.Rate, Samples: append([]float32(nil), c.Samples...)}
}

// Peak returns the maximum absolute sample.
func (c *Clip) Peak() float32 {
	var p float32
	for _, v := range c.Samples {
		if a := abs(v); a > p {
			p = a
		}
	}
	return p
}

// RMS returns the root-mean-square level (0–1).
func (c *Clip) RMS() float64 {
	if len(c.Samples) == 0 {
		return 0
	}
	var sum float64
	for _, v := range c.Samples {
		sum += float64(v) * float64(v)
	}
	return math.Sqrt(sum / float64(len(c.Samples)))
}

// Gain multiplies every sample.
func (c *Clip) Gain(g float32) *Clip {
	for i := range c.Samples {
		c.Samples[i] *= g
	}
	return c
}

// DB converts decibels to a linear gain.
func DB(db float64) float32 { return float32(math.Pow(10, db/20)) }

// NormalizeRMS scales the clip so its RMS matches targetDB (dBFS) while the
// peak never exceeds maxPeak.
func (c *Clip) NormalizeRMS(targetDB float64, maxPeak float32) *Clip {
	rms := c.RMS()
	if rms == 0 {
		return c
	}
	g := float32(math.Pow(10, targetDB/20) / rms)
	if p := c.Peak() * g; p > maxPeak {
		g *= maxPeak / p
	}
	return c.Gain(g)
}

// Pad appends seconds of silence at the start and end.
func (c *Clip) Pad(head, tail float64) *Clip {
	h := make([]float32, int(head*float64(c.Rate)))
	t := make([]float32, int(tail*float64(c.Rate)))
	c.Samples = append(append(h, c.Samples...), t...)
	return c
}

// TrimSilence removes leading and trailing samples below threshold, keeping
// keep seconds of margin.
func (c *Clip) TrimSilence(threshold float32, keep float64) *Clip {
	start, end := 0, len(c.Samples)
	for start < end && abs(c.Samples[start]) < threshold {
		start++
	}
	for end > start && abs(c.Samples[end-1]) < threshold {
		end--
	}
	m := int(keep * float64(c.Rate))
	start = max(0, start-m)
	end = min(len(c.Samples), end+m)
	c.Samples = c.Samples[start:end]
	return c
}

// Cut shortens the clip to at most seconds, fading the last fade seconds
// so the cut is not a click. A shorter clip is left alone.
func (c *Clip) Cut(seconds, fade float64) *Clip {
	n := int(seconds * float64(c.Rate))
	if n <= 0 || n >= len(c.Samples) {
		return c
	}
	c.Samples = c.Samples[:n]
	return c.Fade(0, fade)
}

// Fade applies linear fade-in and fade-out of the given lengths.
func (c *Clip) Fade(in, out float64) *Clip {
	ni := min(len(c.Samples), int(in*float64(c.Rate)))
	for i := 0; i < ni; i++ {
		c.Samples[i] *= float32(i) / float32(ni)
	}
	no := min(len(c.Samples), int(out*float64(c.Rate)))
	for i := 0; i < no; i++ {
		c.Samples[len(c.Samples)-1-i] *= float32(i) / float32(no)
	}
	return c
}

// LoopTo repeats the clip (with a short crossfade at each seam) until it is
// at least seconds long, then trims to exactly that length.
func (c *Clip) LoopTo(seconds float64, crossfade float64) *Clip {
	want := int(seconds * float64(c.Rate))
	if len(c.Samples) == 0 || want <= 0 {
		return &Clip{Rate: c.Rate}
	}
	xf := min(int(crossfade*float64(c.Rate)), len(c.Samples)/2)
	out := append([]float32(nil), c.Samples...)
	for len(out) < want {
		seam := len(out) - xf
		for i := 0; i < xf; i++ {
			t := float32(i) / float32(xf)
			out[seam+i] = out[seam+i]*(1-t) + c.Samples[i]*t
		}
		out = append(out, c.Samples[xf:]...)
	}
	return &Clip{Rate: c.Rate, Samples: out[:want]}
}

// MixAt adds src into c starting at seconds, scaled by gain, extending c if
// needed.
func (c *Clip) MixAt(src *Clip, seconds float64, gain float32) *Clip {
	off := int(seconds * float64(c.Rate))
	if off < 0 {
		off = 0
	}
	if need := off + len(src.Samples); need > len(c.Samples) {
		c.Samples = append(c.Samples, make([]float32, need-len(c.Samples))...)
	}
	for i, v := range src.Samples {
		c.Samples[off+i] += v * gain
	}
	return c
}

// Duck lowers c wherever the control signal is loud: gain drops towards
// floor (0–1) with the given attack/release times. Used to keep music under
// narration.
func (c *Clip) Duck(control *Clip, threshold float64, floor float32, attack, release float64) *Clip {
	win := c.Rate / 20 // 50 ms
	env := make([]float32, len(c.Samples))
	for i := range env {
		lo, hi := max(0, i-win/2), min(len(control.Samples), i+win/2)
		var sum float64
		for j := lo; j < hi; j++ {
			sum += float64(control.Samples[j]) * float64(control.Samples[j])
		}
		if hi > lo && math.Sqrt(sum/float64(hi-lo)) > threshold {
			env[i] = floor
		} else {
			env[i] = 1
		}
	}
	// Smooth: attack when going down, release when coming up.
	ca := float32(math.Exp(-1 / (attack * float64(c.Rate))))
	cr := float32(math.Exp(-1 / (release * float64(c.Rate))))
	g := float32(1)
	for i := range c.Samples {
		target := env[i]
		if target < g {
			g = ca*g + (1-ca)*target
		} else {
			g = cr*g + (1-cr)*target
		}
		c.Samples[i] *= g
	}
	return c
}

// Ramp multiplies samples before startSec by from, after endSec by to, and
// ramps linearly between. Used for a music intro that settles under the
// narrator.
func (c *Clip) Ramp(from, to float32, startSec, endSec float64) *Clip {
	a := int(startSec * float64(c.Rate))
	b := int(endSec * float64(c.Rate))
	for i := range c.Samples {
		switch {
		case i < a:
			c.Samples[i] *= from
		case i >= b || b <= a:
			c.Samples[i] *= to
		default:
			t := float32(i-a) / float32(b-a)
			c.Samples[i] *= from*(1-t) + to*t
		}
	}
	return c
}

// Limit soft-clips anything above ceiling so the encoder never sees peaks.
func (c *Clip) Limit(ceiling float32) *Clip {
	for i, v := range c.Samples {
		if a := abs(v); a > ceiling {
			c.Samples[i] = float32(math.Copysign(float64(ceiling), float64(v)))
		}
	}
	return c
}

// WriteWAV writes a 16-bit mono PCM WAV file.
func (c *Clip) WriteWAV(path string) error {
	pcm := c.ToPCM16()
	hdr := make([]byte, 44)
	copy(hdr[0:], "RIFF")
	binary.LittleEndian.PutUint32(hdr[4:], uint32(36+len(pcm)))
	copy(hdr[8:], "WAVE")
	copy(hdr[12:], "fmt ")
	binary.LittleEndian.PutUint32(hdr[16:], 16)
	binary.LittleEndian.PutUint16(hdr[20:], 1)
	binary.LittleEndian.PutUint16(hdr[22:], 1)
	binary.LittleEndian.PutUint32(hdr[24:], uint32(c.Rate))
	binary.LittleEndian.PutUint32(hdr[28:], uint32(c.Rate*2))
	binary.LittleEndian.PutUint16(hdr[32:], 2)
	binary.LittleEndian.PutUint16(hdr[34:], 16)
	copy(hdr[36:], "data")
	binary.LittleEndian.PutUint32(hdr[40:], uint32(len(pcm)))
	return os.WriteFile(path, append(hdr, pcm...), 0o644)
}

// EncodeM4A converts a WAV to AAC in an .m4a container using macOS afconvert.
func EncodeM4A(wavPath, m4aPath string, bitrate int) error {
	if bitrate <= 0 {
		bitrate = 96000
	}
	cmd := exec.Command("afconvert", "-f", "m4af", "-d", "aac", "-b", fmt.Sprint(bitrate), "-q", "127", "-s", "3", wavPath, m4aPath)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("afconvert: %w: %s", err, out)
	}
	return nil
}

func clamp(v float32) float32 {
	if v > 1 {
		return 1
	}
	if v < -1 {
		return -1
	}
	return v
}

func abs(v float32) float32 {
	if v < 0 {
		return -v
	}
	return v
}
