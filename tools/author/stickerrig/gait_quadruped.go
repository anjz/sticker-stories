package main

import (
	"math"
	"strings"
	"sync"

	"stickerstories/tools/internal/manifest"
)

// Four-legged animals and hoppers. The four-legged rigs have one-piece
// legs (no knees) at the shoulders and hips: legFF/legBF the far front
// and back legs, legBN/legFN the near ones. Each leg's step (u from its
// touchdown) is a stance, when it sweeps back at an even pace under the
// body (so its foot keeps still on the ground while the app carries the
// animal along), then a swing, when it comes forward again lifted a
// little (a leg without a knee is raised at the shoulder, as a folding
// wrist or hock would lift the paw). The legs' footfalls follow the real
// gaits:
//
//   - walk: the lateral sequence of every walking quadruped (left hind,
//     left fore, right hind, right fore a quarter of a loop apart), each
//     foot down ~65 % of it, so three feet stand most of the time; an
//     ungulate nods its head down as each forefoot takes the weight.
//   - trot: diagonal pairs (near hind with far fore) half a loop apart,
//     each down about half of it; the back stays level, the head steady.
//   - scurry: a small animal's fast trot of short quick steps (shrews,
//     hedgehogs), its tiny feet sliding under the body.
//   - canter: the three-beat gait of a dog at an easy lope — trailing
//     hind, then the diagonal pair, then the leading fore, then a moment
//     in the air — the body rocking like a rocking horse.
//
// Hoppers: a rabbit's or squirrel's bound (both hind legs push together,
// the back stretching out in the air, the forepaws reach to land first,
// then the hind legs swing in under the body and it gathers) and a
// frog's jump (both hind legs kick out straight together, the arms reach
// to land). The app lifts a hop in its arc once per loop; the pose here
// is the hop drawn in place, crouched at t = 0 where it touches down.
//
// And the beach's two that crawl: a seal galumphing on its belly (the
// front flippers push together, the chest rises and the hind end is
// drawn up under it in an arch, then the chest lunges forward and down)
// and a sea turtle on sand (both front flippers pull together while the
// rear one pushes, the shell lifted and surging forward, then it rests
// on the sand while the flippers come forward again).

// quadGait is a four-legged gait.
type quadGait struct {
	about   string
	cycle   float64
	samples int
	duty    float64
	// phase is each leg's touchdown in the loop.
	phase map[string]float64
	// step is how far a foot goes back under the body while it stands,
	// in the legs' mean length; lift how high a swinging foot rises.
	step, lift float64
	// slide: tiny feet slide under the body instead of turning (a
	// hedgehog's paws).
	slide bool
	// flight lifts the body off the ground (leg lengths) at t; pitch tips
	// the body nose down, head nods it on top, tail and ears turn them
	// (forward/up, degrees); bob raises the body (leg lengths) on legs
	// that do not hang on it.
	flight, pitch, head, tail, ears, bob func(t float64) float64
}

var quadLegRoles = []string{"legFF", "legBF", "legBN", "legFN"}

// quadStep is a leg's place in its step at u (from its touchdown): pos
// +1 forward at touchdown to −1 back at lift-off (linearly: the foot
// keeps pace with the ground), then forward again; lift 0–1 in the swing,
// highest early in it, as a paw is picked up and then reaches.
func quadStep(u, duty float64) (pos, lift float64) {
	u -= math.Floor(u)
	if u < duty {
		return 1 - 2*u/duty, 0
	}
	s := (u - duty) / (1 - duty)
	return -math.Cos(math.Pi * s), math.Sin(math.Pi * s * (2 - s))
}

// legLengths are a puppet's legs, hip to the bottom of the foot at rest.
var (
	legLengthsMu sync.Mutex
	legLengths   = map[*puppet]map[string]float64{}
)

func (g *gaitBody) legLength(id string) float64 {
	legLengthsMu.Lock()
	defer legLengthsMu.Unlock()
	m := legLengths[g.p]
	if m == nil {
		m = map[string]float64{}
		legLengths[g.p] = m
	}
	if l, ok := m[id]; ok {
		return l
	}
	l := g.p.rig.Bones[0].Y - g.p.bone[id].Y
	if gr := newGround(g.p, []string{id}); len(gr.rest) == 1 && !math.IsInf(gr.rest[0], 0) {
		if v := gr.rest[0] - g.p.bone[id].Y; v > 10 {
			l = v
		}
	}
	m[id] = l
	return l
}

func (q quadGait) style() gaitStyle {
	var feet []gaitFoot
	for _, r := range quadLegRoles {
		feet = append(feet, gaitFoot{r, q.phase[r]})
	}
	return gaitStyle{
		About: q.about, Cycle: q.cycle, Samples: q.samples, Duty: q.duty, Feet: feet,
		Pose: func(g *gaitBody, t float64) gaitPose { return q.pose(g, t) },
	}
}

func (q quadGait) pose(g *gaitBody, t float64) gaitPose {
	b := map[string]manifest.BonePose{}
	var mean float64
	var n int
	for _, r := range quadLegRoles {
		if id := g.id(r); id != "" {
			mean += g.legLength(id)
			n++
		}
	}
	if n > 0 {
		mean /= float64(n)
	}
	for _, r := range quadLegRoles {
		id := g.id(r)
		if id == "" {
			continue
		}
		sc := g.swing()
		if r == "legFF" || r == "legFN" {
			sc = g.arms()
		}
		pos, lift := quadStep(t-q.phase[r], q.duty)
		half := q.step * mean / 2 * sc
		if q.slide {
			b[r] = manifest.BonePose{X: g.ahead(pos * half), Y: -lift * q.lift * mean * sc}
			continue
		}
		l := g.legLength(id)
		turn := math.Asin(math.Max(-1, math.Min(1, half/l))) * 180 / math.Pi
		b[r] = manifest.BonePose{R: g.fwd(pos * turn), Y: -lift * q.lift * l * sc}
	}
	at := func(f func(float64) float64) float64 {
		if f == nil {
			return 0
		}
		return f(t)
	}
	body := manifest.BonePose{R: g.lean(at(q.pitch))}
	if q.bob != nil {
		body.Y = -q.bob(t) * mean
	}
	b["body"] = body
	b["head"] = manifest.BonePose{R: g.lean(at(q.head))}
	if q.tail != nil {
		b["tail"] = manifest.BonePose{R: g.lean(q.tail(t))}
	}
	if q.ears != nil {
		e := g.lean(q.ears(t))
		b["earL"] = manifest.BonePose{R: e}
		b["earR"] = manifest.BonePose{R: e}
	}
	q.clear(g, t, b)
	return gaitPose{Bones: b, Lift: at(q.flight)}
}

// quadGrounds are each puppet's feet on the ground, as the engine finds
// them.
var quadGrounds = map[*puppet]*ground{}

// clear lifts each swinging foot a little more where it would still go
// under its ground line once the body stands on the planted feet: a
// one-piece leg turned back tips its toe down, and the engine would
// otherwise swing the whole leg forward to clear it.
func (q quadGait) clear(g *gaitBody, t float64, b map[string]manifest.BonePose) {
	var roles, ids []string
	var down []bool
	near, nearest := -1, 2.0
	for _, r := range quadLegRoles {
		id := g.id(r)
		if id == "" || containsStr(g.spec.Still, id) {
			continue
		}
		u := t - q.phase[r] - math.Floor(t-q.phase[r])
		on := u < q.duty
		if on {
			near = -2
		} else if d := math.Min(u-q.duty, 1-u); near != -2 && d < nearest {
			near, nearest = len(roles), d
		}
		roles, ids, down = append(roles, r), append(ids, id), append(down, on)
	}
	if len(ids) == 0 || g.spec.Ground != nil && !*g.spec.Ground {
		return
	}
	if near >= 0 {
		down[near] = true
	}
	legLengthsMu.Lock()
	gr := quadGrounds[g.p]
	if gr == nil {
		gr = newGround(g.p, ids)
		quadGrounds[g.p] = gr
	}
	legLengthsMu.Unlock()
	if len(gr.feet) != len(ids) {
		return
	}
	root := g.p.rig.Bones[0].ID
	for range 4 {
		poses := map[string]manifest.BonePose{}
		for role, v := range b {
			if id := g.id(role); id != "" && !containsStr(g.spec.Still, id) {
				poses[id] = v
			}
		}
		for id, v := range g.spec.Pose {
			o := poses[id]
			o.R, o.X, o.Y = o.R+v.R, o.X+v.X, o.Y+v.Y
			poses[id] = o
		}
		dy, _ := gr.stand(g.p.world(poses), down)
		rp := poses[root]
		rp.Y -= dy
		poses[root] = rp
		w := g.p.world(poses)
		moved := false
		for li, r := range roles {
			if down[li] {
				continue
			}
			if below := gr.bottom(li, w).y - gr.rest[li]; below > -4 {
				v := b[r]
				v.Y -= below + 5
				b[r] = v
				moved = true
			}
		}
		if !moved {
			return
		}
	}
}

// twice is a sine twice a loop, amp at t = at (and half a loop later).
func twice(t, at, amp float64) float64 { return amp * math.Cos(4*math.Pi*(t-at)) }

// smooth is 0 before a, 1 after b, eased between.
func smooth(t, a, b float64) float64 {
	s := math.Max(0, math.Min(1, (t-a)/(b-a)))
	return s * s * (3 - 2*s)
}

// noDip raises each of the limbs (roles) where its bottom would go
// below where it rests on the ground, in a style without feet that
// lifts the body by lift (leg lengths): a flipper turned forward hangs
// lower and would dig into the sand.
func noDip(g *gaitBody, b map[string]manifest.BonePose, lift float64, roles ...string) {
	var ids, rs []string
	for _, r := range roles {
		if id := g.id(r); id != "" && !containsStr(g.spec.Still, id) {
			ids, rs = append(ids, id), append(rs, r)
		}
	}
	if len(ids) == 0 {
		return
	}
	legLengthsMu.Lock()
	key := &quadDipKey{g.p, strings.Join(ids, ",")}
	gr := quadDips[*key]
	if gr == nil {
		gr = newGround(g.p, ids)
		quadDips[*key] = gr
	}
	legLengthsMu.Unlock()
	root := g.p.rig.Bones[0].ID
	for range 4 {
		poses := map[string]manifest.BonePose{}
		for role, v := range b {
			if id := g.id(role); id != "" && !containsStr(g.spec.Still, id) {
				poses[id] = v
			}
		}
		for id, v := range g.spec.Pose {
			o := poses[id]
			o.R, o.X, o.Y = o.R+v.R, o.X+v.X, o.Y+v.Y
			poses[id] = o
		}
		rp := poses[root]
		rp.Y -= lift * g.leg * g.lift()
		poses[root] = rp
		w := g.p.world(poses)
		moved := false
		for li, r := range rs {
			if below := gr.bottom(li, w).y - gr.rest[li]; below > 0.5 {
				v := b[r]
				v.Y -= below + 1
				b[r] = v
				moved = true
			}
		}
		if !moved {
			return
		}
	}
}

type quadDipKey struct {
	p   *puppet
	ids string
}

var quadDips = map[quadDipKey]*ground{}

// ---------- hoppers ----------

// bound is a rabbit's or squirrel's hop drawn in place: crouched at 0,
// both hind legs (legL, legR) push back together, the body stretches and
// tips forward in the air, the forepaws (armL, armR) reach forward to
// land first, the hind legs swing in under it and it gathers. kick is
// the hind legs' push (degrees back), reach the forepaws' (forward),
// lean the body's tip forward at most, up its own rise (leg lengths) on
// top of the app's arc.
func bound(g *gaitBody, t, kick, reach, lean, up float64) gaitPose {
	b := map[string]manifest.BonePose{}
	sw, ar := g.swing(), g.arms()
	hind := curve{{0, 2}, {0.12, -0.6 * kick}, {0.28, -kick}, {0.5, -0.7 * kick}, {0.68, 0.1 * kick}, {0.84, 0.35 * kick}, {0.95, 0.15 * kick}}.at(t) * sw
	b["legL"] = manifest.BonePose{R: g.fwd(hind)}
	b["legR"] = manifest.BonePose{R: g.fwd(hind)}
	fore := curve{{0, 0}, {0.15, -0.35 * reach}, {0.35, 0.2 * reach}, {0.6, 0.9 * reach}, {0.78, reach}, {0.92, 0.35 * reach}}.at(t) * ar
	b["armL"] = manifest.BonePose{R: g.fwd(fore)}
	b["armR"] = manifest.BonePose{R: g.fwd(fore)}
	tip := curve{{0, 0.3 * lean}, {0.15, 0.75 * lean}, {0.35, lean}, {0.6, 0.85 * lean}, {0.8, 0.55 * lean}, {0.93, 0.35 * lean}}.at(t)
	b["body"] = manifest.BonePose{R: g.lean(tip)}
	// The head keeps its eyes on where it goes: it turns back against
	// most of the body's tip.
	b["head"] = manifest.BonePose{R: g.lean(-0.55 * tip)}
	// Squashed as it lands and pushes off, stretched long in the air.
	sq := 1 - 0.07*(bump(t, 0.88, 1.12)) + 0.05*bump(t, 0.15, 0.6)
	sx := 1 + 0.04*bump(t, 0.88, 1.12) - 0.02*bump(t, 0.15, 0.6)
	b["belly"] = manifest.BonePose{SY: &sq, SX: &sx}
	// Ears and tail lag: blown back as it rises, flopping forward as it
	// comes down.
	lag := -math.Sin(2 * math.Pi * (t - 0.05))
	b["earL"] = manifest.BonePose{R: g.lean(9 * lag)}
	b["earR"] = manifest.BonePose{R: g.lean(7 * lag)}
	b["tail"] = manifest.BonePose{R: g.lean(-8 * lag)}
	return gaitPose{Bones: b, Lift: up * bump(t, 0.04, 0.92)}
}

// ---------- the styles ----------

func init() {
	// A fawn's walk: lateral sequence, near hind first; ~1 s a stride
	// at an easy walk.
	gaitStyles["quadruped.walk"] = quadGait{
		about:   "an animal on four legs walking: lateral sequence (hind, fore on the same side, then the other side a half loop on), three feet down most of the time, the head nodding as each forefoot lands",
		cycle:   1.1,
		samples: 16,
		duty:    0.66,
		phase:   map[string]float64{"legBN": 0, "legFN": 0.25, "legBF": 0.5, "legFF": 0.75},
		step:    0.6,
		lift:    0.07,
		pitch:   func(t float64) float64 { return twice(t, 0.3, 0.7) },
		head:    func(t float64) float64 { return twice(t, 0.33, 2.2) },
		tail:    func(t float64) float64 { return twice(t, 0.45, 4) },
		ears:    func(t float64) float64 { return twice(t, 0.42, -2) },
	}.style()

	// A fox's or badger's trot: diagonal pairs, a hair over half the
	// loop down each (no time in the air at an easy trot).
	gaitStyles["quadruped.trot"] = quadGait{
		about:   "an animal on four legs trotting: diagonal pairs (near hind with far fore) half a loop apart, the back level, the head steady, the tail streaming",
		cycle:   0.72,
		samples: 14,
		duty:    0.54,
		phase:   map[string]float64{"legBN": 0, "legFF": 0, "legBF": 0.5, "legFN": 0.5},
		step:    0.46,
		lift:    0.09,
		pitch:   func(t float64) float64 { return twice(t, 0.2, 0.6) },
		head:    func(t float64) float64 { return twice(t, 0.3, -0.8) },
		tail:    func(t float64) float64 { return twice(t, 0.38, 3) },
		ears:    func(t float64) float64 { return twice(t, 0.36, -2.5) },
	}.style()

	// A hedgehog's scurry: a quick trot of short steps, its tiny feet
	// sliding under the spines, the body bobbing a little at each pair.
	gaitStyles["quadruped.scurry"] = quadGait{
		about:   "a small animal scurrying: a quick trot of short steps (diagonal pairs), tiny feet pattering under the body, which bobs at each step",
		cycle:   0.44,
		samples: 12,
		duty:    0.56,
		phase:   map[string]float64{"legBN": 0, "legFF": 0, "legBF": 0.5, "legFN": 0.5},
		step:    0.9,
		lift:    0.14,
		slide:   true,
		pitch:   func(t float64) float64 { return twice(t, 0.15, 1) },
		head:    func(t float64) float64 { return twice(t, 0.25, -0.8) },
		bob:     func(t float64) float64 { return 0.05 * math.Pow(math.Cos(2*math.Pi*(t-0.27)), 2) },
	}.style()

	// A dog's easy canter (a right lead: trailing hind, then the
	// diagonal, then the leading fore, then a moment in the air), the
	// body rocking: up at the front as the hind legs push, down onto the
	// leading fore.
	gaitStyles["quadruped.canter"] = quadGait{
		about:   "a dog cantering: three beats (trailing hind, the diagonal pair, the leading fore) and a moment in the air, rocking front up as the hind legs push and down onto the leading fore, ears and tail bouncing",
		cycle:   0.66,
		samples: 14,
		duty:    0.42,
		phase:   map[string]float64{"legBF": 0, "legBN": 0.2, "legFF": 0.2, "legFN": 0.42},
		step:    0.75,
		lift:    0.1,
		flight:  func(t float64) float64 { return 0.05 * bump(t, 0.82, 1.02) },
		pitch:   func(t float64) float64 { return 3.5 * math.Cos(2*math.Pi*(t-0.62)) },
		head:    func(t float64) float64 { return -2.5 * math.Cos(2*math.Pi*(t-0.66)) },
		tail:    func(t float64) float64 { return 6 * math.Cos(2*math.Pi*(t-0.75)) },
		ears:    func(t float64) float64 { return -7 * math.Cos(2*math.Pi*(t-0.75)) },
	}.style()

	// A dog's trot (the easy alternative to the canter).
	gaitStyles["quadruped.dogtrot"] = quadGait{
		about:   "a dog trotting briskly: diagonal pairs with a moment in the air between them, ears and tail bouncing",
		cycle:   0.6,
		samples: 12,
		duty:    0.46,
		phase:   map[string]float64{"legBN": 0, "legFF": 0, "legBF": 0.5, "legFN": 0.5},
		step:    0.52,
		lift:    0.1,
		flight:  func(t float64) float64 { return 0.025 * (bump(t, 0.42, 0.54) + bump(t, 0.92, 1.04)) },
		pitch:   func(t float64) float64 { return twice(t, 0.2, 0.8) },
		head:    func(t float64) float64 { return twice(t, 0.3, -1) },
		tail:    func(t float64) float64 { return twice(t, 0.38, 4) },
		ears:    func(t float64) float64 { return twice(t, 0.36, -6) },
	}.style()

	gaitStyles["hopper.bound"] = gaitStyle{
		About:   "a rabbit or squirrel bounding: both hind legs push together, the back stretches out in the air, the forepaws reach to land first, the hind legs swing in under it and it gathers; ears and tail lag",
		Cycle:   0.78,
		Samples: 14,
		Hops:    true,
		Pose: func(g *gaitBody, t float64) gaitPose {
			return bound(g, t, 30, 22, 16, 0.18)
		},
	}

	// A frog's jump: both hind legs kick out straight together as it
	// leaves, stay out in the air, fold back up to land; the arms swing
	// back along the body then reach down to land first.
	gaitStyles["hopper.frog"] = gaitStyle{
		About:   "a frog jumping: both hind legs kick out straight together, the body tipped towards where it goes, the arms reaching down to land first",
		Cycle:   0.8,
		Samples: 14,
		Hops:    true,
		Pose: func(g *gaitBody, t float64) gaitPose {
			b := map[string]manifest.BonePose{}
			sw, ar := g.swing(), g.arms()
			kick := curve{{0, 0}, {0.08, 0.35}, {0.2, 1}, {0.45, 1}, {0.62, 0.7}, {0.8, 0.15}, {0.92, 0}}.at(t) * sw
			// In a front view the kicked legs hang long below the body,
			// a little inward, trailing.
			b["legL"] = manifest.BonePose{R: -6*kick + g.fwd(-6*kick), Y: 30 * kick}
			b["legR"] = manifest.BonePose{R: 6*kick + g.fwd(-6*kick), Y: 30 * kick}
			arm := curve{{0, -0.2}, {0.15, 0.6}, {0.4, 1}, {0.6, 0.6}, {0.78, -0.3}, {0.9, -0.5}}.at(t) * ar
			b["armL"] = manifest.BonePose{R: 12 * arm, Y: 8 * math.Max(0, arm)}
			b["armR"] = manifest.BonePose{R: -12 * arm, Y: 8 * math.Max(0, arm)}
			tip := curve{{0, 1}, {0.15, 5}, {0.4, 6}, {0.65, 3}, {0.85, -1}, {0.95, 0}}.at(t)
			b["body"] = manifest.BonePose{R: g.lean(tip)}
			sq := 1 - 0.08*bump(t, 0.88, 1.1) + 0.06*bump(t, 0.12, 0.6)
			sx := 1 + 0.05*bump(t, 0.88, 1.1) - 0.04*bump(t, 0.12, 0.6)
			b["belly"] = manifest.BonePose{SY: &sq, SX: &sx}
			b["face"] = manifest.BonePose{Y: 6 * bump(t, 0.88, 1.1)}
			return gaitPose{Bones: b, Lift: 0.45 * bump(t, 0.04, 0.94)}
		},
	}

	// A seal galumphing (after harbour seals hauled out): the front
	// flippers push together, the chest rises and the hind end is drawn
	// up under it (the back arched), then the chest lunges forward and
	// down onto the belly and the hind end stretches out behind; a pause
	// on the belly before the next. The body surges forward in the lunge
	// and hangs back in the gather.
	gaitStyles["seal.galumph"] = gaitStyle{
		About:   "a seal galumphing on land: front flippers push together, the chest lifts and the back arches drawing the hind end up, then it lunges forward onto its belly",
		Cycle:   0.9,
		Samples: 14,
		Pose: func(g *gaitBody, t float64) gaitPose {
			b := map[string]manifest.BonePose{}
			ar := g.arms()
			gather := bump(t, 0.0, 0.5)
			lunge := bump(t, 0.4, 0.85)
			// Nose up as the chest rises, down into the lunge.
			pitch := -4.5*gather + 3.5*lunge
			b["body"] = manifest.BonePose{R: g.lean(pitch)}
			b["head"] = manifest.BonePose{R: g.lean(-0.7*pitch + 1.5*bump(t, 0.6, 0.95))}
			sx := 1 - 0.05*gather + 0.05*lunge
			sy := 1 + 0.06*gather - 0.05*lunge
			b["belly"] = manifest.BonePose{SX: &sx, SY: &sy}
			fl := curve{{0, 4}, {0.25, -12}, {0.42, -14}, {0.62, 10}, {0.78, 14}, {0.92, 8}}
			b["armR"] = manifest.BonePose{R: g.fwd(fl.at(t) * ar)}
			b["armL"] = manifest.BonePose{R: g.fwd(fl.at(t-0.04) * ar * 0.8)}
			// The hind flippers tip forward as the hind end is drawn up,
			// back as it stretches out.
			b["tail"] = manifest.BonePose{R: g.lean(14*gather - 10*lunge)}
			// Hang back in the gather, surge in the lunge (rig pixels).
			p := smooth(t, 0.38, 0.85)
			surge := 0.05 * g.p.rig.Size * (p - t)
			b["root"] = manifest.BonePose{X: g.ahead(surge)}
			noDip(g, b, 0.06*gather, "armL", "armR")
			return gaitPose{Bones: b, Lift: 0.06 * gather}
		},
	}

	// A sea turtle on sand (green turtles and leatherbacks crawl so):
	// both front flippers reach forward, dig in and pull back together
	// while the rear flipper pushes, the shell lifted off the sand and
	// surging forward; then it rests on the sand as the flippers come
	// forward again, slow and steady.
	gaitStyles["turtle.crawl"] = gaitStyle{
		About:   "a sea turtle crawling on sand: both front flippers pull back together with the rear one pushing, the shell lifted and surging forward, then a rest on the sand as they reach forward again",
		Cycle:   1.25,
		Samples: 16,
		Pose: func(g *gaitBody, t float64) gaitPose {
			b := map[string]manifest.BonePose{}
			sw, ar := g.swing(), g.arms()
			pull := curve{{0, 9}, {0.12, 8}, {0.3, -3}, {0.48, -16}, {0.58, -17}, {0.75, -6}, {0.9, 5}}
			lift := bump(t, 0.58, 0.95)
			b["armL"] = manifest.BonePose{R: g.fwd(pull.at(t) * ar), Y: -8 * lift}
			b["armR"] = manifest.BonePose{R: g.fwd(pull.at(t-0.03) * ar), Y: -8 * lift}
			push := curve{{0, 6}, {0.2, 4}, {0.45, -10}, {0.6, -11}, {0.8, 0}}
			b["legB"] = manifest.BonePose{R: g.fwd(push.at(t) * sw)}
			up := bump(t, 0.1, 0.6)
			b["body"] = manifest.BonePose{R: g.lean(-1.5*up + 0.8*bump(t, 0.55, 0.85))}
			b["head"] = manifest.BonePose{R: g.lean(1.5*up - 1.5*bump(t, 0.6, 0.95))}
			sq := 1 - 0.02*bump(t, 0.55, 0.8)
			b["belly"] = manifest.BonePose{SY: &sq}
			p := smooth(t, 0.12, 0.6)
			surge := 0.035 * g.p.rig.Size * (p - t)
			b["root"] = manifest.BonePose{X: g.ahead(surge)}
			noDip(g, b, 0.04*up, "armL", "armR", "legB")
			return gaitPose{Bones: b, Lift: 0.04 * up}
		},
	}
}
