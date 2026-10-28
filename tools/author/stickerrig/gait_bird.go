package main

import (
	"math"
	"sync"

	"stickerstories/tools/internal/manifest"
)

// Birds and insects: wings (wingL/wingR at the shoulder; in flight the
// rig's "open" attachments, shown through the gait's slots), two legs
// (footL/footR or legL/legR, one piece each from the hip or the root) or
// six (legL1–3, legR1–3), body, head, tail, antennae; root at the feet,
// or at the body's centre for a hoverer.
//
// Modelled on:
//   - Flapping flight: the downstroke is the power stroke, quicker than
//     the upstroke (~40/60 of a beat); the body rises through the
//     downstroke and sinks through the upstroke, a little after the
//     wings; legs tucked back; the head steadier than the body. Both
//     wings beat together (the far wing in phase with the near one, so
//     both stay in sight). Small birds beat fast; big ones (gull,
//     pelican) beat slowly and glide between beats; an owl beats softly
//     and slowly and glides; a woodpecker flies in bounds — a burst of
//     beats, then wings shut while it falls in an arc.
//   - A two-footed hop (small birds, gulls on rocks): both feet push off
//     together, the legs trail back in the air and swing forward to
//     land, the body squashing as it lands; the tail and head lag.
//   - A duck's waddle: short quick steps on wide-set legs, the body
//     rolling onto the planted foot each step, the head held level.
//   - A sandpiper's run: very quick little steps (it scurries), legs a
//     blur under a body and head held level, no bob (the legs give
//     under the body).
//   - Paddling (duckling, pelican on the water): the feet kick back in a
//     quick power stroke and come forward slowly, one after the other,
//     the body surging gently.
//   - Insects in flight: a quick small wingbeat (a blur, but calm for
//     children), the body bobbing slowly, legs dangling; a ladybug flies
//     with its wing cases held up and its body tipped up. A butterfly
//     beats slowly and big: its wings sweep open and down quickly, and
//     its body bobs up on that stroke.
//   - Six-legged walking: the tripod gait — front and back legs of one
//     side with the middle leg of the other side down together, the
//     other three swinging, then the other way round.

// birdWingDown is the turn's sign that sweeps a wing down: a wing whose
// tip (its shown attachment's middle) lies right of its shoulder goes
// down turning clockwise, one whose tip lies left anticlockwise.
func birdWingDown(g *gaitBody, role string) float64 {
	id := g.id(role)
	if id == "" {
		return 1
	}
	bone := g.p.bone[id]
	var best *manifest.PuppetAttachment
	for _, s := range g.p.rig.Slots {
		if s.Bone != id {
			continue
		}
		name := g.spec.Slots[s.ID]
		if name == "" {
			name = s.Default
		}
		if name == manifest.PuppetHidden {
			continue
		}
		if a, ok := s.Attachments[name]; ok {
			best = &a
			break
		}
	}
	if best == nil {
		return 1
	}
	if best.X+best.W/2 < bone.X {
		return -1
	}
	return 1
}

// birdLegs are a bird's two legs, by whichever names the rig has them.
func birdLegs(g *gaitBody) []string {
	var out []string
	for _, r := range []string{"footL", "footR", "legL", "legR"} {
		if g.has(r) {
			out = append(out, r)
		}
	}
	return out
}

// birdLegUpright is the turn that stands a one-piece leg straight under
// its hip, its ankle (a little above the foot's bottom) right below the
// joint: a bird drawn mid-step has one leg forward and one back, and
// the gait swings each leg about the upright.
func birdLegUpright(g *gaitBody, role string) float64 {
	id := g.id(role)
	if id == "" {
		return 0
	}
	key := legKey{g.p, id}
	birdUprightMu.Lock()
	defer birdUprightMu.Unlock()
	if v, ok := birdUpright[key]; ok {
		return v
	}
	gr := newGround(g.p, []string{id})
	hip := g.p.bone[id]
	ax, ay := gr.ankleRest[0][0], gr.ankleRest[0][1]
	// A turn of +r carries the lower end left: the slant to the right.
	v := math.Atan2(ax-hip.X, ay-hip.Y) * 180 / math.Pi
	birdUpright[key] = v
	return v
}

type legKey struct {
	p  *puppet
	id string
}

var (
	birdUpright   = map[legKey]float64{}
	birdUprightMu sync.Mutex
)

func smoothstep(x float64) float64 {
	x = math.Max(0, math.Min(1, x))
	return x * x * (3 - 2*x)
}

// flapper is how a flier beats its wings.
type flapper struct {
	beats      int     // wingbeats per loop
	beating    float64 // the share of the loop beating (the rest glides)
	down       float64 // the downstroke's share of a beat
	up, low    float64 // degrees the wing goes up, and down, from as drawn
	glide      float64 // the wing in the glide (degrees down; up < 0)
	bob        float64 // the body's rise and fall, px
	bound      bool    // a woodpecker's bounds: the body rises beating, falls gliding
	pitch      float64 // the body tipped forward, degrees
	tuck       [2]float64
	tuckY      float64 // legs drawn up, px
	head       float64 // the head turned back against the pitch, share
	off        float64 // where the loop starts: mid-downstroke, wings level
	wingsAlike bool    // insects' wings: no glide, legs dangle
}

// angle is the wing's sweep down (degrees) at u of the loop.
func (f *flapper) angle(u float64) float64 {
	u -= math.Floor(u)
	if u >= f.beating {
		// Glide: from the top of the beat to the glide and back.
		return -f.up + (f.glide+f.up)*bump(u, f.beating, 1)
	}
	b := u / f.beating * float64(f.beats)
	b -= math.Floor(b)
	if b < f.down {
		return -f.up + (f.up+f.low)*smoothstep(b/f.down)
	}
	return f.low - (f.up+f.low)*smoothstep((b-f.down)/(1-f.down))
}

// start is where the first downstroke passes level, so the loop starts
// (and the landing settles) with the wings as drawn.
func (f *flapper) start() float64 {
	lo, hi := 0.0, f.down
	for range 40 {
		m := (lo + hi) / 2
		if -f.up+(f.up+f.low)*smoothstep(m/f.down) < 0 {
			lo = m
		} else {
			hi = m
		}
	}
	return lo * f.beating / float64(f.beats)
}

func (f flapper) style(about string, cycle float64, samples int) gaitStyle {
	f.off = f.start()
	return gaitStyle{
		About:   about,
		Cycle:   cycle,
		Samples: samples,
		Flies:   true,
		Pose: func(g *gaitBody, t float64) gaitPose {
			u := t + f.off
			amp := g.arms()
			a := f.angle(u) * amp
			b := map[string]manifest.BonePose{}
			for _, w := range []string{"wingL", "wingR"} {
				if g.has(w) {
					b[w] = manifest.BonePose{R: birdWingDown(g, w) * a}
				}
			}
			// The body rises on the downstroke, a little behind it.
			span := (f.up + f.low) / 2
			var y float64
			if f.bound {
				// Up through the beats, falling in an arc with wings shut.
				y = -f.bob * math.Cos(2*math.Pi*(u-f.beating*0.8-f.off))
			} else {
				y = -f.bob * f.angle(u-0.12*f.beating/float64(f.beats)) / span
			}
			y *= g.lift()
			// The body pitches up a touch on the downstroke; the head
			// holds steadier.
			osc := 1.5 * f.angle(u-0.06) / span
			b["root"] = manifest.BonePose{Y: y}
			b["body"] = manifest.BonePose{R: g.lean(f.pitch - osc)}
			if g.has("head") {
				b["head"] = manifest.BonePose{R: g.lean(-f.head*f.pitch + 0.7*osc)}
			}
			if g.has("tail") {
				b["tail"] = manifest.BonePose{R: g.lean(-0.35*f.pitch + 2*osc)}
			}
			sw := g.swing()
			for i, l := range birdLegs(g) {
				b[l] = manifest.BonePose{R: g.fwd(f.tuck[i%2] * sw), Y: f.tuckY * sw}
			}
			return gaitPose{Bones: b}
		},
	}
}

// insectLegs are a six-legged body's legs: the near and far legs, front
// to back.
var insectLegs = []string{"legL1", "legL2", "legL3", "legR1", "legR2", "legR3"}

// tripod is the leg set a leg walks with: front and back of one side with
// the middle of the other.
func tripod(leg string) float64 {
	switch leg {
	case "legL1", "legL3", "legR2":
		return 0
	}
	return 0.5
}

// hoverer is an insect in flight: quick wingbeats, a slow bob.
type hoverer struct {
	beats    int
	up, low  float64
	bob      float64
	pitch    float64
	legs     [3]float64 // front, middle, back legs turned forward, degrees
	legsY    float64
	shell    float64 // a ladybug's wing cases lifted, degrees
	antennae float64
}

func (h hoverer) style(about string, cycle float64, samples int) gaitStyle {
	f := flapper{beats: h.beats, beating: 1, down: 0.4, up: h.up, low: h.low}
	off := f.start()
	return gaitStyle{
		About:   about,
		Cycle:   cycle,
		Samples: samples,
		Flies:   true,
		Pose: func(g *gaitBody, t float64) gaitPose {
			u := t + off
			b := map[string]manifest.BonePose{}
			a := f.angle(u) * g.arms()
			for _, w := range []string{"wingL", "wingR"} {
				if g.has(w) {
					b[w] = manifest.BonePose{R: birdWingDown(g, w) * a}
				}
			}
			// One slow bob a loop, started level so it settles level.
			y := -h.bob * math.Sin(2*math.Pi*t) * g.lift()
			b["root"] = manifest.BonePose{Y: y}
			b["body"] = manifest.BonePose{R: g.lean(h.pitch + 1.2*math.Sin(2*math.Pi*t))}
			sw := g.swing()
			for _, l := range insectLegs {
				if !g.has(l) {
					continue
				}
				k := int(l[len(l)-1]-'1') % 3
				// Dangling legs trail a little behind the bob.
				b[l] = manifest.BonePose{R: g.fwd(h.legs[k]*sw + 2*math.Sin(2*math.Pi*(t-0.15))), Y: h.legsY * sw}
			}
			for _, an := range []string{"antennaL", "antennaR"} {
				if g.has(an) {
					b[an] = manifest.BonePose{R: g.fwd(-h.antennae + 3*math.Sin(2*math.Pi*(t-0.2)))}
				}
			}
			if h.shell != 0 && g.has("shell") {
				b["shell"] = manifest.BonePose{R: g.lean(h.shell), Y: -4}
			}
			return gaitPose{Bones: b}
		},
	}
}

func fp(v float64) *float64 { return &v }

func init() {
	gaitStyles["bird.fly"] = flapper{
		beats: 1, beating: 1, down: 0.4, up: 46, low: 28,
		bob: 6, pitch: 8, tuck: [2]float64{-35, -35}, tuckY: -28, head: 0.4,
	}.style("a small bird flying: quick beats, the downstroke quicker than the upstroke, the body rising on it, legs tucked back", 0.46, 12)

	gaitStyles["bird.flyquick"] = flapper{
		beats: 1, beating: 1, down: 0.4, up: 22, low: 16,
		bob: 5, pitch: 6, tuck: [2]float64{-35, -35}, tuckY: -24, head: 0.6,
	}.style("a little wader flying: quick shallow beats low over the sand, legs trailing tucked", 0.4, 10)

	gaitStyles["bird.soar"] = flapper{
		beats: 1, beating: 0.66, down: 0.4, up: 26, low: 26, glide: 16,
		bob: 7, pitch: 6, tuck: [2]float64{-35, -35}, tuckY: -24, head: 0.6,
	}.style("a big seabird flying: a slow deep beat, then a glide on held wings", 1.0, 16)

	gaitStyles["bird.soarslow"] = flapper{
		beats: 1, beating: 0.6, down: 0.42, up: 28, low: 28, glide: 16,
		bob: 7, pitch: 6, tuck: [2]float64{-35, -35}, tuckY: -26, head: 0.8,
	}.style("a heavy bird (pelican) flying: one slow, heavy beat, then a long glide", 1.2, 18)

	gaitStyles["owl.fly"] = flapper{
		beats: 1, beating: 0.75, down: 0.42, up: 34, low: 30, glide: 12,
		bob: 7, pitch: 6, tuck: [2]float64{-12, 12}, tuckY: -30, head: 0.5,
	}.style("an owl flying: soft, slow, deep beats and a short silent glide, feet drawn up", 0.92, 16)

	gaitStyles["woodpecker.fly"] = flapper{
		beats: 2, beating: 0.55, down: 0.4, up: 16, low: 52, glide: 58,
		bob: 9, bound: true, pitch: 26, tuck: [2]float64{-50, -50}, tuckY: -6, head: 0.45,
	}.style("a woodpecker flying in bounds: a burst of beats rising, then wings shut, falling in an arc", 0.9, 22)

	gaitStyles["bird.hop"] = gaitStyle{
		About:   "a small bird hopping on both feet together: crouch, push off, legs trailing back, swinging forward to land, the body squashing as it lands",
		Cycle:   0.56,
		Samples: 12,
		Hops:    true,
		Pose: func(g *gaitBody, t float64) gaitPose {
			// t 0 is the touch-down and push-off (the app's arc is on
			// the ground there), the top of the hop at 0.5.
			crouch := bump(t, 0.86, 0.14)
			trail := bump(t, 0.1, 0.55)
			reach := bump(t, 0.55, 0.95)
			sw := g.swing()
			b := map[string]manifest.BonePose{}
			for _, l := range birdLegs(g) {
				b[l] = manifest.BonePose{R: g.fwd((-16*trail + 4*reach) * sw), Y: -6 * trail * sw}
			}
			b["body"] = manifest.BonePose{Y: 6 * crouch, R: g.lean(3*trail - 2*reach)}
			if g.has("belly") {
				b["belly"] = manifest.BonePose{SX: fp(1 + 0.05*crouch - 0.02*trail), SY: fp(1 - 0.06*crouch + 0.03*trail)}
			}
			if g.has("head") {
				b["head"] = manifest.BonePose{Y: 5*crouch - 2*trail, R: g.lean(-2*trail + 1.5*reach)}
			}
			if g.has("tail") {
				b["tail"] = manifest.BonePose{R: g.lean(-5*crouch + 6*trail)}
			}
			// A flick of the folded wing as it springs.
			for _, w := range []string{"wingL"} {
				if g.has(w) {
					b[w] = manifest.BonePose{R: -birdWingDown(g, w) * 6 * bump(t, 0.05, 0.45)}
				}
			}
			return gaitPose{Bones: b}
		},
	}

	gaitStyles["duck.waddle"] = gaitStyle{
		About:   "a duckling waddling: short quick steps, the body rolling onto the planted foot each step, wings out a little for balance, head level",
		Cycle:   0.56,
		Duty:    0.6,
		Samples: 14,
		Feet:    []gaitFoot{{"footL", 0}, {"footR", 0.5}},
		Pose: func(g *gaitBody, t float64) gaitPose {
			sw := g.swing()
			b := map[string]manifest.BonePose{}
			for _, s := range []struct {
				foot string
				ph   float64
			}{{"footL", 0}, {"footR", 0.5}} {
				u := t + s.ph
				u -= math.Floor(u)
				// Planted from 0 to 0.6, the foot going back under the
				// body; then lifted and brought forward.
				var k float64 // +1 forward, −1 back
				if u < 0.6 {
					k = 1 - 2*u/0.6
				} else {
					k = -1 + 2*smoothstep((u-0.6)/0.4)
				}
				lift := bump(u, 0.6, 1)
				b[s.foot] = manifest.BonePose{X: g.ahead(22 * k * sw), Y: -12 * lift * sw, R: g.fwd((8*k - 10*lift) * sw)}
			}
			// Rolling onto each planted foot in turn (one sway a step pair).
			roll := 4 * math.Sin(2*math.Pi*(t-0.05))
			b["body"] = manifest.BonePose{R: roll}
			if g.has("head") {
				b["head"] = manifest.BonePose{R: -0.7 * roll}
			}
			flare := 5 * (bump(t, 0.1, 0.4) + bump(t, 0.6, 0.9))
			if g.has("wingL") {
				b["wingL"] = manifest.BonePose{R: -birdWingDown(g, "wingL") * flare}
			}
			if g.has("wingR") {
				b["wingR"] = manifest.BonePose{R: -birdWingDown(g, "wingR") * flare}
			}
			return gaitPose{Bones: b}
		},
	}

	gaitStyles["wader.run"] = gaitStyle{
		About:   "a sandpiper scurrying: very quick little steps, legs a blur under a level body and a level head",
		Cycle:   0.4,
		Duty:    0.5,
		Samples: 10,
		Feet:    []gaitFoot{{"legL", 0}, {"legR", 0.5}},
		Pose: func(g *gaitBody, t float64) gaitPose {
			sw := g.swing()
			b := map[string]manifest.BonePose{}
			for _, s := range []struct {
				leg string
				ph  float64
			}{{"legL", 0}, {"legR", 0.5}} {
				u := t + s.ph
				u -= math.Floor(u)
				var th float64
				if u < 0.5 {
					th = 24 - 48*u/0.5
				} else {
					th = -24 + 48*smoothstep((u-0.5)/0.5)
				}
				// The planted leg gives at the ankle under the body (a
				// bird's legs are springy), so the body runs level: the
				// one-piece leg draws up by as much as it would lift it.
				give := 0.0
				if u < 0.5 {
					give = g.leg * (math.Cos(th*sw*math.Pi/180) - math.Cos(24*sw*math.Pi/180))
				}
				b[s.leg] = manifest.BonePose{R: birdLegUpright(g, s.leg) + g.fwd(th*sw), Y: -give - 16*bump(u, 0.5, 1)*sw}
			}
			b["body"] = manifest.BonePose{R: g.lean(4)}
			if g.has("head") {
				b["head"] = manifest.BonePose{R: g.lean(-3)}
			}
			return gaitPose{Bones: b}
		},
	}

	gaitStyles["bird.paddle"] = gaitStyle{
		About:   "a water bird paddling: each foot kicks back quickly and comes forward slowly, one after the other, the body surging gently",
		Cycle:   0.8,
		Samples: 12,
		Pose: func(g *gaitBody, t float64) gaitPose {
			sw := g.swing()
			b := map[string]manifest.BonePose{}
			legs := birdLegs(g)
			for i, l := range legs {
				u := t + 0.5*float64(i%2) + 0.2
				u -= math.Floor(u)
				var th float64
				if u < 0.4 {
					th = 18 - 38*smoothstep(u/0.4) // the kick back
				} else {
					th = -20 + 38*smoothstep((u-0.4)/0.6)
				}
				b[l] = manifest.BonePose{R: g.fwd(th * sw)}
			}
			// A surge after each kick: the body bobs and tips a touch.
			s := math.Cos(4 * math.Pi * (t - 0.25))
			b["root"] = manifest.BonePose{Y: 1.5 + 1.5*s}
			b["body"] = manifest.BonePose{R: g.lean(1 + 0.8*s)}
			return gaitPose{Bones: b}
		},
	}

	// ---------- insects ----------

	gaitStyles["bee.fly"] = hoverer{
		beats: 4, up: 15, low: 11, bob: 6, pitch: 4,
		legs: [3]float64{4, 0, -6}, antennae: 5,
	}.style("a bee flying: wings a quick small blur, the body bobbing slowly, legs dangling", 0.64, 16)

	gaitStyles["firefly.fly"] = hoverer{
		beats: 4, up: 14, low: 10, bob: 6, pitch: 4,
		legs: [3]float64{16, 8, -11}, legsY: -7, antennae: 5,
	}.style("a firefly flying: quick small wingbeats, legs drawn up, a slow bob", 0.72, 16)

	gaitStyles["ladybug.fly"] = hoverer{
		beats: 4, up: 12, low: 8, bob: 6, pitch: -5,
		legs: [3]float64{14, 8, -10}, legsY: -9, shell: 24, antennae: 6,
	}.style("a ladybug flying: wing cases held up, thin wings beating quickly beneath, body tipped up, a slow bob", 0.72, 16)

	gaitStyles["butterfly.flutter"] = gaitStyle{
		About:   "a butterfly fluttering: slow big beats, the wings sweeping open and down quickly and closing up slowly, the body bobbing up on the downstroke",
		Cycle:   0.7,
		Samples: 14,
		Flies:   true,
		Pose: func(g *gaitBody, t float64) gaitPose {
			// t 0: the wings just open, at the end of the downstroke.
			// The upstroke closes them (0–0.6), the downstroke opens
			// them again (0.6–1), quicker.
			var c float64
			if t < 0.6 {
				c = smoothstep(t / 0.6)
			} else {
				c = 1 - smoothstep((t-0.6)/0.4)
			}
			c *= g.arms()
			b := map[string]manifest.BonePose{}
			b["wingL"] = manifest.BonePose{R: -4 + 18*c, SX: fp(1 - 0.62*c)}
			b["wingR"] = manifest.BonePose{R: 4 - 18*c, SX: fp(1 - 0.62*c)}
			b["wingL2"] = manifest.BonePose{SY: fp(1 - 0.46*c)}
			b["wingR2"] = manifest.BonePose{SY: fp(1 - 0.46*c)}
			// Up on the downstroke (highest just after it), sinking as
			// the wings close.
			h := 1 - smoothstep(t/0.6)
			if t >= 0.6 {
				h = smoothstep((t - 0.6) / 0.4)
			}
			b["root"] = manifest.BonePose{Y: (7 - 14*h) * g.lift()}
			b["body"] = manifest.BonePose{R: g.lean(2 + 2*c)}
			for _, an := range []string{"antennaL", "antennaR"} {
				b[an] = manifest.BonePose{R: 6 * c}
			}
			return gaitPose{Bones: b}
		},
	}

	insectWalk := func(about string, cycle float64, swingDeg, reach float64) gaitStyle {
		var feet []gaitFoot
		for _, l := range insectLegs {
			feet = append(feet, gaitFoot{l, tripod(l)})
		}
		return gaitStyle{
			About:   about,
			Cycle:   cycle,
			Duty:    0.55,
			Samples: 12,
			Feet:    feet,
			Pose: func(g *gaitBody, t float64) gaitPose {
				sw := g.swing()
				b := map[string]manifest.BonePose{}
				for _, l := range insectLegs {
					if !g.has(l) {
						continue
					}
					u := t + tripod(l)
					u -= math.Floor(u)
					var s float64 // +1 reached forward, −1 back
					if u < 0.55 {
						s = 1 - 2*u/0.55
					} else {
						s = -1 + 2*smoothstep((u-0.55)/0.45)
					}
					b[l] = manifest.BonePose{R: g.fwd(swingDeg * s * sw), X: g.ahead(reach * s * sw), Y: -11 * bump(u, 0.55, 1) * sw}
				}
				// Each tripod's push lifts the body a touch and rocks it.
				b["body"] = manifest.BonePose{Y: -1.5 * (1 - math.Cos(4*math.Pi*t)), R: 0.8 * math.Sin(2*math.Pi*t)}
				if g.has("head") {
					b["head"] = manifest.BonePose{R: -0.8 * math.Sin(2*math.Pi*t)}
				}
				for _, an := range []string{"antennaL", "antennaR"} {
					if g.has(an) {
						b[an] = manifest.BonePose{R: 3 * math.Sin(2*math.Pi*(t-0.15))}
					}
				}
				return gaitPose{Bones: b}
			},
		}
	}
	gaitStyles["insect.walk"] = insectWalk("an insect walking on six legs in the tripod gait: front and back legs of one side with the middle leg of the other down together, then the other three", 0.6, 12, 12)
}
