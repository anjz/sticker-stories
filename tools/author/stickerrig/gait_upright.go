package main

import (
	"math"
	"sync"

	"stickerstories/tools/internal/manifest"
)

// Upright walkers: animals (and toy characters) walking on two short
// hind legs, each leg one piece (thigh, shin and foot drawn together:
// no knee, no ankle), arms armL/armR on the body, a tail on the body or
// the root, head at the neck; root at the feet.
//
// Modelled on how bears, raccoons and beavers really walk when they get
// up on their hind legs (and on cartoon walk cycles of short-legged
// characters): legs that cannot fold at the knee swing from the hip in
// short steps, the swinging foot is drawn up by hiking its hip; the feet
// are set wide, so the body rolls over the planted foot much more than
// a person's does (a waddle), the head stays nearly level against the
// roll, the arms hang and swing a little against the legs. A bear cub
// (plantigrade, heavy) steps slowly and rolls; a raccoon walks hunched
// forward; a beaver rolls most, on very short legs, with its arms held
// on what it carries; a mouse scurries in quick little steps.
//
// Each leg's t starts as its foot comes down in front; the planted foot
// goes back under the body at an even speed (no slide) and the swinging
// one comes forward, eased, hip drawn up. The other leg is half a loop
// behind.

// uprightGait is one upright walker's manner.
type uprightGait struct {
	// Each leg's step forward and back: slid (in leg lengths) and swung
	// (degrees). A leg with its foot drawn on it tips the foot as it
	// swings, toes or heel into the ground, so it mostly slides under the
	// body (the hip moves in the round of the belly) and swings a little;
	// in the air it swings forward by tilt more.
	slide, step, tilt float64
	hike              float64 // the swinging leg drawn up into the hip, in leg lengths
	roll              float64 // degrees the body rocks over the planted foot
	lean              float64 // degrees the body tips forward
	nod               float64 // head nod per step, degrees
	arm               float64 // arms' swing against the legs, degrees
	tail              float64 // tail sway, degrees
}

// uprightLeg is where a leg is in its loop at u (0 = its foot coming
// down in front): forward (+1) to back (−1), and how far it is drawn up
// (0–1, only in the swing).
func uprightLeg(u, duty float64) (fwd, up float64) {
	u -= math.Floor(u)
	if u < duty {
		return 1 - 2*u/duty, 0
	}
	s := (u - duty) / (1 - duty)
	// The foot clears the ground as it leaves, is reached out in front
	// before the end and comes down onto it (a leg without a knee or an
	// ankle would otherwise land heel first, under the ground).
	r := math.Min(s/0.82, 1)
	return -1 + 2*r*r*(3-2*r), math.Pow(math.Sin(math.Pi*s), 0.7)
}

// uprightWeight is +1 when the body is over the left foot (its middle of
// standing), −1 over the right.
func uprightWeight(t, duty float64) float64 {
	return math.Cos(2 * math.Pi * (t - duty/2))
}

// screenSide is −1 when a role's bone is on the left of the sticker
// (smaller x) than the other's, +1 otherwise.
func screenSide(g *gaitBody, role, other string) float64 {
	a, b := g.id(role), g.id(other)
	if a == "" || b == "" || g.p.bone[a].X < g.p.bone[b].X {
		return -1
	}
	return 1
}

func (m uprightGait) pose(g *gaitBody, t, duty float64) map[string]manifest.BonePose {
	b := map[string]manifest.BonePose{}
	sw, as := g.swing(), g.arms()
	fL, upL := uprightLeg(t, duty)
	fR, upR := uprightLeg(t+0.5, duty)
	for _, l := range []struct {
		role    string
		fwd, up float64
	}{{"legL", fL, upL}, {"legR", fR, upR}} {
		b[l.role] = manifest.BonePose{
			X: g.ahead(m.slide * sw * g.leg * l.fwd),
			Y: -m.hike * sw * g.leg * l.up,
			R: g.fwd((m.step*l.fwd + m.tilt*l.up) * sw),
		}
	}

	// The body rolls its top over the planted foot's side, a little
	// after the weight comes onto it.
	w := uprightWeight(t-0.04, duty)
	roll := m.roll * sw * w * screenSide(g, "legL", "legR")
	b["body"] = manifest.BonePose{R: roll + g.lean(m.lean)}
	// The head keeps nearly level against the roll and nods down as
	// each foot takes the weight.
	nod := m.nod * wave(2*t, duty/2-0.02, 1)
	b["head"] = manifest.BonePose{R: -0.65*roll + g.lean(-0.5*m.lean+nod)}
	// The arms swing against the legs, hanging back against the roll.
	b["armL"] = manifest.BonePose{R: g.fwd(m.arm*as*fR) - 0.35*roll}
	b["armR"] = manifest.BonePose{R: g.fwd(m.arm*as*fL) - 0.35*roll}
	// The tail sways after the body.
	b["?tail"] = manifest.BonePose{R: -m.tail * sw * uprightWeight(t-0.14, duty) * screenSide(g, "legL", "legR")}
	return b
}

var (
	uprightFeet = []gaitFoot{{"legL", 0}, {"legR", 0.5}}
	toddleFeet  = []gaitFoot{{"footL", 0}, {"footR", 0.5}}
)

// swingGrounds are the feet of each body being moved (*gaitBody →
// *ground), found once.
var swingGrounds sync.Map

// clearSwing draws a swinging leg up (into its hip) as far as it needs
// to stay above the ground once the body stands on its planted foot. A
// leg with its foot drawn on it can only clear the ground so: swung
// further forward (as gait.go does for a dragging foot) a foot drawn
// pointing back would dip its heel further in.
func clearSwing(g *gaitBody, b map[string]manifest.BonePose, t, duty float64, feet []gaitFoot) {
	var ids []string
	var down []bool
	for _, f := range feet {
		id := g.id(f.Role)
		if id == "" {
			return
		}
		u := t - f.Phase
		ids = append(ids, id)
		down = append(down, u-math.Floor(u) < duty)
	}
	v, ok := swingGrounds.Load(g)
	if !ok {
		v, _ = swingGrounds.LoadOrStore(g, newGround(g.p, ids))
	}
	gr := v.(*ground)
	pose := map[string]manifest.BonePose{}
	for role, q := range b {
		if id := g.id(role); id != "" && !containsStr(g.spec.Still, id) {
			pose[id] = q
		}
	}
	for id, q := range g.spec.Pose {
		p := pose[id]
		p.R, p.X, p.Y = p.R+q.R, p.X+q.X, p.Y+q.Y
		pose[id] = p
	}
	w := g.p.world(pose)
	dy, li := gr.stand(w, down)
	if li < 0 {
		return
	}
	for i := range ids {
		if down[i] {
			continue
		}
		// The body comes up by dy to stand: keep this foot 2 px clear.
		lo := gr.bottom(i, w)
		if over := lo.y - dy - gr.rest[i] + 2; over > 0 {
			q := b[feet[i].Role]
			q.Y -= over
			b[feet[i].Role] = q
		}
	}
}

// uprightStyle makes a style from a manner.
func uprightStyle(about string, cycle, duty float64, samples int, m uprightGait) gaitStyle {
	return gaitStyle{
		About:   about,
		Cycle:   cycle,
		Duty:    duty,
		Samples: samples,
		Feet:    uprightFeet,
		Pose: func(g *gaitBody, t float64) gaitPose {
			b := m.pose(g, t, duty)
			if g.has("tail") {
				b["tail"] = b["?tail"]
			}
			delete(b, "?tail")
			clearSwing(g, b, t, duty, uprightFeet)
			return gaitPose{Bones: b}
		},
	}
}

// toddle: a toy character on loose feet (no legs: each foot its own
// piece under the body, footL/footR on the root): the planted foot
// slides back under it at an even speed, the other is picked up, toes
// first up, and set down in front; the body rocks from foot to foot and
// bobs up as each foot passes under it, the arms out for balance
// seesawing against the rock. A cartoon toddler's walk.
func toddlePose(g *gaitBody, t, duty float64) gaitPose {
	b := map[string]manifest.BonePose{}
	sw, as := g.swing(), g.arms()
	step, lift := 1.1*g.leg*sw, 0.32*g.leg*sw
	for _, f := range []struct {
		role string
		ph   float64
	}{{"footL", 0}, {"footR", 0.5}} {
		fw, up := uprightLeg(t+f.ph, duty)
		// Toes up as it comes forward, flat as it lands.
		toe := 12 * sw * up * (0.6 + 0.4*fw)
		b[f.role] = manifest.BonePose{X: g.ahead(step * fw), Y: -lift * up, R: g.fwd(toe)}
	}
	w := uprightWeight(t-0.04, duty)
	roll := 5 * sw * w * screenSide(g, "footL", "footR")
	// Up as a foot passes under the body (twice a loop).
	bob := 0.12 * g.leg * sw * (0.5 - 0.5*math.Cos(4*math.Pi*(t-duty/2-0.25)))
	b["body"] = manifest.BonePose{R: roll + g.lean(2), Y: -bob}
	// Arms out: they seesaw against the rock (the one on the high side
	// dips), and swing a little with the steps.
	fL, _ := uprightLeg(t, duty)
	b["armL"] = manifest.BonePose{R: -1.4*roll + g.fwd(6*as*fL)}
	b["armR"] = manifest.BonePose{R: -1.4*roll + g.fwd(6*as*fL)}
	clearSwing(g, b, t, duty, toddleFeet)
	return gaitPose{Bones: b}
}

// skipFeet: a skip's feet, each down from the step just before it lands
// (at 0.95 of its loop), through its hop, till the other lands: always
// one foot on the ground but in the hop's flight, so the leg reaching
// down to step is the one stood on (human.skip's feet leave a gap where
// none is down and the stepping foot goes under the ground).
var skipFeet = []gaitFoot{{"legL", 0.92}, {"legR", 0.42}}

// armsBeside keeps each arm from swinging across the body: in a
// three-quarter view the arm drawn on the side it goes to swings back
// over the chest, the other forward over it; that way it only goes a
// quarter as far.
func armsBeside(g *gaitBody, b map[string]manifest.BonePose) {
	body := g.id("body")
	if body == "" {
		return
	}
	for _, arm := range []string{"armL", "armR"} {
		id := g.id(arm)
		q, ok := b[arm]
		if id == "" || !ok {
			continue
		}
		// +1 when the arm is on the side it travels to.
		ahead := -g.dir * math.Copysign(1, g.p.bone[id].X-g.p.bone[body].X)
		if f := q.R * g.dir; f*ahead < 0 {
			q.R *= 0.25
			b[arm] = q
		}
	}
}

func init() {
	gaitStyles["upright.bear"] = uprightStyle(
		"a bear cub walking on its hind legs: short plantigrade steps, wide-set feet, the heavy body rolling over each planted foot, the head steady, arms hanging and swinging a little",
		0.8, 0.62, 14,
		uprightGait{slide: 0.2, step: 3, tilt: 8, hike: 0.1, roll: 5, lean: 1.5, nod: 1.2, arm: 10, tail: 0},
	)
	gaitStyles["upright.walk"] = uprightStyle(
		"a raccoon walking on its hind legs: hunched forward, quick short steps, the body rolling a little, the ringed tail swaying after it",
		0.62, 0.6, 14,
		uprightGait{slide: 0.24, step: 3, tilt: 10, hike: 0.13, roll: 3.5, lean: 9, nod: 1.5, arm: 6, tail: 8},
	)
	gaitStyles["upright.waddle"] = uprightStyle(
		"a beaver waddling on its very short hind legs: little wide steps, the round body rolling far over each planted foot, the head kept level, the flat tail dragging",
		0.8, 0.62, 14,
		uprightGait{slide: 0.38, step: 2.5, tilt: 8, hike: 0.13, roll: 6, lean: 1, nod: 1, arm: 0, tail: 2},
	)
	gaitStyles["upright.scamper"] = uprightStyle(
		"a mouse scurrying on its hind legs: quick little steps, leaning forward, paws tucked in, the tail swinging after it",
		0.45, 0.52, 12,
		uprightGait{slide: 0.44, step: 2, tilt: 12, hike: 0.18, roll: 2.5, lean: 9, nod: 1.5, arm: 3, tail: 8},
	)
	gaitStyles["upright.toddle"] = gaitStyle{
		About:   "a toy character toddling on loose feet: each foot picked up toes first and set down in front, the body rocking and bobbing from foot to foot, arms out for balance",
		Cycle:   0.65,
		Duty:    0.6,
		Samples: 14,
		Feet:    toddleFeet,
		Pose:    func(g *gaitBody, t float64) gaitPose { return toddlePose(g, t, 0.6) },
	}
	gaitStyles["upright.skip"] = gaitStyle{
		About:   "a child skipping, as human.skip, but always stood on one foot outside the hops (the stepping foot does not go under the ground)",
		Cycle:   1.1,
		Duty:    0.5,
		Samples: 16,
		Feet:    skipFeet,
		Pose: func(g *gaitBody, t float64) gaitPose {
			gp := gaitStyles["human.skip"].Pose(g, t)
			armsBeside(g, gp.Bones)
			return gp
		},
	}
}
