package main

import (
	"fmt"
	"math"
	"sync"

	"stickerstories/tools/internal/manifest"
)

// Swimmers, crawlers, many-legged scuttlers and rolling things.
//
// Most of these have no feet the engine can stand on (they swim, glide
// on a foot or a row of prolegs, or roll), so the engine keeps the move's
// own `stride`. Where the style itself knows how far one loop carries the
// sticker — a crab's planted feet sweeping back, a caterpillar's step, a
// ball's circumference — it says so on install ("travels … px a loop:
// stride …") so the rig's `stride` can be set to match and nothing
// slides.

func wtF(v float64) *float64 { return &v }

// wtS is a scale for a key, to three places.
func wtS(v float64) *float64 { return wtF(math.Round(v*1000) / 1000) }

func wtFrac(t float64) float64 { return t - math.Floor(t) }

// wtStroke goes from 1 to −1 over the first p of the loop and back over
// the rest, easing in and out at both ends: a stroke whose two halves
// take different times (a power stroke and a slower recovery).
func wtStroke(u, p float64) float64 {
	u = wtFrac(u)
	if u < p {
		return math.Cos(math.Pi * u / p)
	}
	return -math.Cos(math.Pi * (u - p) / (1 - p))
}

var (
	wtMu     sync.Mutex
	wtNoted  = map[*gaitBody]bool{}
	wtWidths = map[*puppet]float64{}
	wtLegs   = map[*puppet]map[string]wtLeg{}
)

// wtWidth is how wide the puppet is drawn at rest, in rig pixels (its
// opaque pixels, as the sticker's box measures the sticker).
func wtWidth(p *puppet) float64 {
	wtMu.Lock()
	defer wtMu.Unlock()
	if w, ok := wtWidths[p]; ok {
		return w
	}
	ls, _ := p.pose(nil, p.shown("", nil))
	lo, hi := math.Inf(1), math.Inf(-1)
	for _, l := range ls {
		for y := l.r.Min.Y; y < l.r.Max.Y; y++ {
			for x := l.r.Min.X; x < l.r.Max.X; x++ {
				if l.alpha(x, y) > 8 {
					lo, hi = math.Min(lo, float64(x)), math.Max(hi, float64(x+1))
				}
			}
		}
	}
	w := hi - lo
	if w <= 0 || math.IsInf(w, 0) {
		w = p.rig.Size
	}
	wtWidths[p] = w
	return w
}

// wtTravel says, once a move, how far its loop carries the sticker and
// the stride (sticker widths a loop) that matches it.
func wtTravel(g *gaitBody, px float64) {
	wtMu.Lock()
	seen := wtNoted[g]
	wtNoted[g] = true
	wtMu.Unlock()
	if seen {
		return
	}
	w := wtWidth(g.p)
	fmt.Printf("  gait %s: travels %.0f px a loop: its \"stride\" is that over the sticker's drawn width (about %.2f)\n", g.spec.Style, px, px/w)
}

// ---------- a stiff leg reaching its foot to a place ----------

// wtLeg is a one-piece leg: where its foot's tip is from its hip at rest.
type wtLeg struct {
	vx, vy, r, phi float64
}

func wtLegOf(g *gaitBody, id string) wtLeg {
	wtMu.Lock()
	defer wtMu.Unlock()
	m := wtLegs[g.p]
	if m == nil {
		m = map[string]wtLeg{}
		wtLegs[g.p] = m
	}
	if l, ok := m[id]; ok {
		return l
	}
	gr := newGround(g.p, []string{id})
	lo := gr.bottom(0, g.p.world(nil))
	b := g.p.bone[id]
	l := wtLeg{vx: lo.x - b.X, vy: lo.y - b.Y}
	l.r = math.Hypot(l.vx, l.vy)
	l.phi = math.Atan2(l.vy, l.vx)
	m[id] = l
	return l
}

// reach is the leg's pose that puts its foot (dx, dy) from where it is
// at rest. A one-piece leg cannot bend, so it turns about its hip and
// stretches or shortens a little across (sx: a jointed leg reaching out
// or drawn in, as it looks from the front); what is left over after at
// most a fifth more or less, its hip slides up or down (the top of a
// crab's leg is tucked under the shell, so the slide does not show).
func (l wtLeg) reach(dx, dy float64) manifest.BonePose {
	if l.r < 1 {
		return manifest.BonePose{X: dx, Y: dy}
	}
	tx, ty := l.vx+dx, l.vy+dy
	sx := 1.0
	if math.Abs(l.vx) > 0.5*l.r {
		need := math.Sqrt(math.Max(tx*tx+ty*ty-l.vy*l.vy, 0)) / math.Abs(l.vx)
		sx = math.Max(0.8, math.Min(1.22, need))
	}
	vx, vy := l.vx*sx, l.vy
	r, phi := math.Hypot(vx, vy), math.Atan2(vy, vx)
	c := math.Max(-0.98, math.Min(0.98, tx/r))
	a := math.Acos(c)
	diff := func(x float64) float64 { return math.Remainder(x-phi, 2*math.Pi) }
	if math.Abs(diff(-a)) < math.Abs(diff(a)) {
		a = -a
	}
	th := diff(a)
	fx, fy := r*math.Cos(a), r*math.Sin(a)
	p := manifest.BonePose{R: th * 180 / math.Pi, X: tx - fx, Y: ty - fy}
	if math.Abs(sx-1) > 0.001 {
		p.SX = wtS(sx)
	}
	return p
}

// ---------- crabs ----------

// A crab walks sideways on four legs a side in an alternating tetrapod:
// the first and third legs of one side step with the second and fourth
// of the other (L1 L3 R2 R4, then L2 L4 R1 R3), each group's feet down
// for a little over half the loop. On the leading side the planted legs
// reach out and pull the body over their feet, on the trailing side they
// push it away, so every planted foot goes back under the body at the
// pace the body travels and stays put on the sand; a lifted foot swings
// forward in an arc. The body rides level with a small rise as each
// group pushes, the claws held up with a little sway, the eye stalks
// jiggling a beat behind. The hermit crab walks forwards on its two
// pairs the same way (L1 with R2, L2 with R1), its shell rocking after it.
// (After crab-locomotion studies: Blickhan & Full 1987, Ghost crab
// sideways tetrapod; hermit crabs' alternating forward walk.)

var wtCrabLegs = []gaitFoot{
	{"legL1", 0}, {"legL3", 0}, {"legR2", 0}, {"legR4", 0},
	{"legL2", 0.5}, {"legL4", 0.5}, {"legR1", 0.5}, {"legR3", 0.5},
}

type wtScuttle struct {
	duty  float64 // of the loop a foot is down
	sweep float64 // half a foot's sweep, in leg lengths
	up    float64 // a lifted foot's height, in leg lengths
	bob   float64 // the body's rise, px
	shell bool    // a hermit crab's shell rocking after it
}

func (s wtScuttle) pose(g *gaitBody, t float64) gaitPose {
	b := map[string]manifest.BonePose{}
	var n, sum float64
	for _, f := range wtCrabLegs {
		if g.has(f.Role) {
			sum += wtLegOf(g, g.id(f.Role)).r
			n++
		}
	}
	if n == 0 {
		return gaitPose{Bones: b}
	}
	leg := sum / n
	amp := s.sweep * leg * g.swing()
	lift := s.up * leg * g.lift()
	// px a loop: each foot goes 2·amp back while down, for duty of it.
	wtTravel(g, 2*amp/s.duty)

	bodyY := -s.bob * math.Cos(4*math.Pi*(t-s.duty/2))
	b["body"] = manifest.BonePose{Y: bodyY}
	for _, f := range wtCrabLegs {
		if !g.has(f.Role) {
			continue
		}
		u := wtFrac(t - f.Phase)
		var x, y float64
		if u < s.duty {
			x = amp - 2*amp*u/s.duty
		} else {
			v := (u - s.duty) / (1 - s.duty)
			x = -amp + 2*amp*(1-math.Cos(math.Pi*v))/2
			y = -lift * math.Sin(math.Pi*v)
		}
		b[f.Role] = wtLegOf(g, g.id(f.Role)).reach(g.ahead(x), y-bodyY)
	}
	// Claws held up, swaying a little against each other.
	b["clawL"] = manifest.BonePose{R: 2.5 * math.Sin(2*math.Pi*t)}
	b["clawR"] = manifest.BonePose{R: 2.5 * math.Sin(2*math.Pi*t+math.Pi*0.8)}
	jig := 2.5 * math.Sin(4*math.Pi*(t-s.duty/2)-1.2)
	if g.has("stalkL") {
		b["stalkL"] = manifest.BonePose{R: jig}
		b["stalkR"] = manifest.BonePose{R: jig * 0.8}
	}
	if s.shell {
		b["shell"] = manifest.BonePose{R: g.lean(1.2 * math.Sin(4*math.Pi*(t-s.duty/2)-1.0)), Y: bodyY * 0.7}
	}
	return gaitPose{Bones: b}
}

// ---------- swimmers ----------

// fishSwim: a carangiform swimmer (bream, goldfish): the body wave runs
// from head to tail growing as it goes, so the head yaws a little, the
// rear and the tail beat most, the tail a quarter beat behind the body;
// one smooth sine with no stop in the middle of a beat. The pectoral
// fins scull, the others flutter after the body.
func fishSwim(g *gaitBody, t float64) gaitPose {
	w := 2 * math.Pi * t
	sw := g.swing()
	body := 2.2 * math.Sin(w) * sw
	tail := 17 * math.Sin(w-1.4) * sw
	b := map[string]manifest.BonePose{
		"body":     {R: body},
		"tail":     {R: tail - body},
		"finSide":  {R: 12 * math.Sin(w-0.5) * sw},
		"finTop":   {R: -4 * math.Sin(w-2.0) * sw},
		"finBack":  {R: 6 * math.Sin(w-2.2) * sw},
		"finFront": {R: 5 * math.Sin(w-1.8) * sw},
		"root":     {Y: -2 * math.Sin(w/1+0.6) * g.lift()},
	}
	return gaitPose{Bones: b}
}

// shrimpSwim: a shrimp swims on its swimmerets (pleopods), which beat
// in a metachronal wave from the back pair to the front, a quick power
// stroke back and a slower recovery forward, three beats a loop; the
// near and the far row a little apart in the wave. Once a loop the tail
// fan gives a small flick (curls under and back), the feelers trailing.
func shrimpSwim(g *gaitBody, t float64) gaitPose {
	sw := g.swing()
	beat := 3 * t
	near := wtStroke(beat, 0.4)
	far := wtStroke(beat+0.18, 0.4)
	flick := bump(t, 0.55, 0.85)
	steer := math.Sin(2*math.Pi*t - 0.5)
	b := map[string]manifest.BonePose{
		"legs":     {R: g.fwd(14 * near * sw)},
		"legsFar":  {R: g.fwd(12 * far * sw)},
		"tail":     {R: g.dir * 4 * flick * sw},
		"tail2":    {R: g.dir * (7*flick + 1.5*steer) * sw},
		"fan":      {R: g.dir * (10*flick + 2*steer) * sw},
		"antennaL": {R: -3 + 2.5*math.Sin(2*math.Pi*beat-1.5)},
		"antennaR": {R: -3 + 2.5*math.Sin(2*math.Pi*beat-2.0)},
		"body":     {R: g.lean(1.2 * flick)},
		"root":     {Y: (-1.5*math.Sin(2*math.Pi*beat) - 3*flick) * g.lift()},
	}
	return gaitPose{Bones: b}
}

// octopusSwim: an octopus jets: the mantle fills slowly while the arms
// spread open (about 60 % of the loop), then squeezes, the water jetting
// out as the arms close together and stream behind (about 25 %), and it
// coasts. It rises on the jet and sinks gently while filling again.
func octopusSwim(g *gaitBody, t float64) gaitPose {
	c := curve{{0, 0.3}, {0.2, -0.5}, {0.45, -0.95}, {0.58, -0.7}, {0.7, 0.85}, {0.8, 1}, {0.9, 0.75}}.at(t) * g.swing()
	y := curve{{0, -5}, {0.3, 0}, {0.6, 3}, {0.7, 1}, {0.82, -6}, {0.92, -7}}.at(t) * g.lift()
	k := 14.0
	b := map[string]manifest.BonePose{
		"armL":  {R: k * c},
		"armR":  {R: -k * c},
		"sideL": {R: -k * c},
		"sideR": {R: k * c},
		"lowL":  {R: -k * c},
		"lowR":  {R: k * c},
		"front": {SY: wtS(1 + 0.04*c)},
		"belly": {SX: wtS(1 - 0.045*c), SY: wtS(1 + 0.04*c)},
		"body":  {R: g.lean(1.5 * math.Max(0, c))},
		"root":  {Y: y},
	}
	return gaitPose{Bones: b}
}

// turtleSwim: a sea turtle flies through the water: both front flippers
// beat together, raised forward, then a long slow downstroke down and
// back (the power stroke, ~55 % of the loop) and a quicker recovery; the
// shell lifts a little on the downstroke, the head stays steady, the
// back flippers trail and steer. (After Davenport et al. 1984, green
// turtle swimming kinematics.)
func turtleSwim(g *gaitBody, t float64) gaitPose {
	sw := g.arms()
	fl := 4 + 28*wtStroke(t, 0.55)*sw
	pitch := 1.5 * math.Cos(2*math.Pi*(t-0.35))
	b := map[string]manifest.BonePose{
		// The near flipper hangs further back at rest than the far one:
		// its stroke is centred a little further forward.
		"armL": {R: g.fwd(fl + 12)},
		"armR": {R: g.fwd(fl * 0.9)},
		"legB": {R: g.fwd(5 * math.Sin(2*math.Pi*t-1.2) * g.swing())},
		"body": {R: g.lean(pitch)},
		"head": {R: g.lean(-pitch*0.8 + 1.2*math.Sin(2*math.Pi*t-2))},
		"root": {Y: -3.5 * math.Cos(2*math.Pi*(t-0.3)) * g.lift()},
	}
	return gaitPose{Bones: b}
}

// sealSwim: a true seal swims with its hind flippers, sweeping them from
// side to side with the back half of the body (a travelling wave from
// the chest to the flippers), the fore flippers held in against its
// sides; the head stays steady at the front. (Phocid swimming: Fish et
// al. 1988, harbour seal.)
func sealSwim(g *gaitBody, t float64) gaitPose {
	w := 2 * math.Pi * t
	sw := g.swing()
	body := 2.2 * math.Sin(w) * sw
	tail := 15 * math.Sin(w-1.3) * sw
	tuck := -14.0
	b := map[string]manifest.BonePose{
		"body": {R: body},
		"tail": {R: tail - body},
		"head": {R: -body*0.9 + 1.0*math.Sin(w-0.4)},
		"armR": {R: g.fwd(tuck + 1.5*math.Sin(w-1.8))},
		"armL": {R: g.fwd(tuck*0.8 + 1.5*math.Sin(w-2.1))},
		"root": {Y: -2 * math.Sin(w+0.4) * g.lift()},
	}
	return gaitPose{Bones: b}
}

// pronePaddle: lying on a board and paddling with the front-crawl
// stroke, the arms half a loop apart: a hand goes in ahead, pulls back
// through the water beside the board (the arm drawn shorter, under the
// surface), lifts out and swings round over the water to go in ahead
// again; the body rolls a touch towards the pulling arm and rises a
// little with each pull. Seen from the front (towards us: ahead is down
// the screen) or from behind (away: ahead is up the screen). Roles armL
// and armR are the one-piece prone arms, prone the lying body.
func pronePaddle(away bool) func(g *gaitBody, t float64) gaitPose {
	// One arm through a stroke, u from the hand going in: its turn
	// outwards (from the board) and its length.
	out := curve{{0, 4}, {0.22, -2}, {0.45, -6}, {0.6, 6}, {0.75, 20}, {0.9, 14}}
	length := curve{{0, 1.1}, {0.2, 1.02}, {0.45, 0.84}, {0.6, 0.9}, {0.78, 0.96}, {0.92, 1.06}}
	if away {
		// From behind, the hand goes in ahead (up the screen: the arm turned
		// up and drawn short), pulls back down beside the board and lifts
		// out at the side.
		out = curve{{0, 26}, {0.2, 10}, {0.45, -14}, {0.6, -8}, {0.78, 12}, {0.9, 22}}
		length = curve{{0, 0.88}, {0.2, 0.94}, {0.45, 1.06}, {0.6, 0.96}, {0.78, 0.92}, {0.92, 0.88}}
	}
	return func(g *gaitBody, t float64) gaitPose {
		sw := g.arms()
		b := map[string]manifest.BonePose{}
		for _, side := range []struct {
			role string
			ph   float64
			sign float64 // + turns this arm's hand outwards
		}{{"armL", 0, 1}, {"armR", 0.5, -1}} {
			u := t - side.ph
			b[side.role] = manifest.BonePose{R: side.sign * out.at(u) * sw, SY: wtS(1 + (length.at(u)-1)*sw)}
		}
		// Each pull lifts and rolls the body a little.
		pull := math.Sin(2 * math.Pi * (t - 0.2))
		b["prone"] = manifest.BonePose{R: 1.0 * pull, Y: -1.5 * math.Cos(4*math.Pi*(t-0.2))}
		if !away {
			b["head"] = manifest.BonePose{R: -0.8 * pull}
		}
		return gaitPose{Bones: b}
	}
}

// ---------- crawlers ----------

// caterpillarCrawl: a caterpillar walks on its prolegs in a wave from
// the tail to the head: the last segment lets go, lifts and steps
// forward, then the next, and so on to the front, while every segment
// on the ground stays put (the body goes forward one step a wave). Each
// segment here moves on its own (the chain's shifts undo its parent's),
// so the hump travels forward segment by segment. (After Trimmer & Lin
// 2014, Manduca sexta crawling.)
var wtCaterpillarSegs = []struct {
	role       string
	phase, lft float64
}{{"seg4", 0, 1}, {"seg3", 0.17, 1}, {"seg2", 0.34, 1}, {"body", 0.51, 0.55}}

func caterpillarCrawl(g *gaitBody, t float64) gaitPose {
	step := 0.075 * g.p.rig.Size * g.swing() // px a wave
	lift := 0.026 * g.p.rig.Size * g.lift()
	const win = 0.34
	wtTravel(g, step)
	b := map[string]manifest.BonePose{}
	px, py := 0.0, 0.0
	for _, s := range wtCaterpillarSegs {
		if !g.has(s.role) {
			continue
		}
		u := wtFrac(t - s.phase)
		var x, y float64
		if u < win {
			v := u / win
			x = -step/2 + step*(v-math.Sin(2*math.Pi*v)/(2*math.Pi))
			y = -lift * s.lft * math.Pow(math.Sin(math.Pi*v), 2)
		} else {
			x = step/2 - step*(u-win)/(1-win)
		}
		x = g.ahead(x)
		b[s.role] = manifest.BonePose{X: x - px, Y: y - py}
		px, py = x, y
	}
	// The head reaches on as the front steps, lifting a touch.
	hu := wtFrac(t - 0.6)
	b["head"] = manifest.BonePose{X: g.ahead(0.012 * g.p.rig.Size * bump(hu, 0, 0.45)), R: g.lean(2 * bump(hu, 0, 0.45))}
	b["antennaL"] = manifest.BonePose{R: 3 * math.Sin(2*math.Pi*t-2.2)}
	b["antennaR"] = manifest.BonePose{R: 3 * math.Sin(2*math.Pi*t-2.6)}
	return gaitPose{Bones: b}
}

// snailCrawl: a snail glides on its foot (waves of muscle run along the
// sole, too small to see): a slow, steady glide; the front of the foot
// stretches on and the tail draws up after it, the shell riding a
// little behind, the eye stalks swaying slowly.
func snailCrawl(g *gaitBody, t float64) gaitPose {
	e := 0.5 - 0.5*math.Cos(2*math.Pi*t)
	sx := 1 + 0.03*e*g.swing()
	// Keep the tail end where it is as the foot stretches.
	pivot := g.p.bone[g.id("belly")].X
	rear := wtRear(g, "body")
	shift := (rear - pivot) * (1 - sx)
	b := map[string]manifest.BonePose{
		"belly":  {X: shift, SX: wtS(sx), SY: wtS(1 - 0.012*e)},
		"shell":  {X: shift * 0.5, Y: -1.2 * math.Sin(2*math.Pi*t-0.9), R: g.lean(0.8 * math.Sin(2*math.Pi*t-1.4))},
		"stalkL": {R: g.lean(3 * math.Sin(2*math.Pi*t-1.6))},
		"stalkR": {R: g.lean(3 * math.Sin(2*math.Pi*t-2.1))},
		"head":   {R: g.lean(1.2 * math.Sin(2*math.Pi*t-0.8))},
	}
	return gaitPose{Bones: b}
}

// wtRear is the end of a slot's piece away from the way it goes, at rest.
func wtRear(g *gaitBody, slot string) float64 {
	i, ok := g.p.slot[slot]
	if !ok {
		return g.p.bone[g.p.rig.Bones[0].ID].X
	}
	s := g.p.rig.Slots[i]
	l := g.p.draw(i, s.Default, g.p.world(nil), s.Attachments[s.Default].Flip)
	if l == nil {
		return g.p.bone[s.Bone].X
	}
	if g.dir > 0 {
		return float64(l.r.Max.X)
	}
	return float64(l.r.Min.X)
}

// urchinCreep: a sea urchin creeps on hundreds of tube feet under it
// (not drawn): a very slow, even glide, the ball rocking a little and
// its spines swaying, as an urchin's do when it moves.
func urchinCreep(g *gaitBody, t float64) gaitPose {
	w := 2 * math.Pi * t
	b := map[string]manifest.BonePose{
		"belly":  {SX: wtS(1 + 0.02*math.Sin(2*w)), SY: wtS(1 - 0.02*math.Sin(2*w))},
		"spines": {R: 3 * math.Sin(w-0.8) * g.swing()},
		"face":   {X: g.ahead(1.5 + 1.5*math.Sin(w))},
		"root":   {Y: -1.5 * (0.5 - 0.5*math.Cos(2*w))},
	}
	return gaitPose{Bones: b}
}

// ---------- rolling things ----------

// objectRoll: a rigid thing rolling without slipping turns once for
// each length of its outline it rolls along (a ball: π × its
// diameter), so one loop is one whole turn of the spin bone at an even
// pace, and the travel is the perimeter of the piece's outline (its
// convex hull, so a pinecone tumbling end over end works too); the body
// rises and falls so its lowest point stays on the ground.
//
// Not usable as a rig's gait yet: after the loop the engine eases to a
// settle key and back to rest, which for a bone that has gone round
// unwinds the whole turn backwards. The ball's and the pinecone's rolls
// keep keys, written from these samples (gait_water_test.go,
// TestWaterRollKeys) with their own wind-down.
func objectRoll(g *gaitBody, t float64) gaitPose {
	spin := g.id("spin")
	if spin == "" {
		return gaitPose{}
	}
	r := -g.dir * 360 * t
	hull, rest := wtHull(g, spin)
	wtTravel(g, hull)
	b := map[string]manifest.BonePose{"spin": {R: r}}
	// Keep the lowest point on the ground.
	low := wtLowest(g, spin, r)
	b["root"] = manifest.BonePose{Y: rest - low}
	return gaitPose{Bones: b}
}

// wtHull is the perimeter of the convex hull of the pieces on a bone
// and below, at rest, and their lowest point.
func wtHull(g *gaitBody, bone string) (float64, float64) {
	pts := wtOpaque(g, bone, 0)
	if len(pts) < 3 {
		return 0, 0
	}
	h := wtConvexHull(pts)
	var per float64
	for i := range h {
		j := (i + 1) % len(h)
		per += math.Hypot(h[j][0]-h[i][0], h[j][1]-h[i][1])
	}
	low := math.Inf(-1)
	for _, p := range pts {
		low = math.Max(low, p[1])
	}
	return per, low
}

func wtLowest(g *gaitBody, bone string, r float64) float64 {
	low := math.Inf(-1)
	for _, p := range wtOpaque(g, bone, r) {
		low = math.Max(low, p[1])
	}
	return low
}

// wtOpaque is the outline points (row ends) of the pieces on a bone and
// below with the bone turned r.
func wtOpaque(g *gaitBody, bone string, r float64) [][2]float64 {
	under := map[string]bool{bone: true}
	for _, b := range g.p.rig.Bones {
		if under[b.Parent] {
			under[b.ID] = true
		}
	}
	w := g.p.world(map[string]manifest.BonePose{bone: {R: r}})
	var pts [][2]float64
	for i, s := range g.p.rig.Slots {
		if !under[s.Bone] {
			continue
		}
		l := g.p.draw(i, s.Default, w, s.Attachments[s.Default].Flip)
		if l == nil {
			continue
		}
		for y := l.r.Min.Y; y < l.r.Max.Y; y++ {
			lo, hi := -1, -1
			for x := l.r.Min.X; x < l.r.Max.X; x++ {
				if l.alpha(x, y) > 128 {
					if lo < 0 {
						lo = x
					}
					hi = x
				}
			}
			if lo >= 0 {
				pts = append(pts, [2]float64{float64(lo), float64(y)}, [2]float64{float64(hi + 1), float64(y + 1)})
			}
		}
	}
	return pts
}

// wtConvexHull: Andrew's monotone chain.
func wtConvexHull(pts [][2]float64) [][2]float64 {
	ps := append([][2]float64(nil), pts...)
	for i := 1; i < len(ps); i++ {
		for j := i; j > 0 && (ps[j][0] < ps[j-1][0] || ps[j][0] == ps[j-1][0] && ps[j][1] < ps[j-1][1]); j-- {
			ps[j], ps[j-1] = ps[j-1], ps[j]
		}
	}
	cross := func(o, a, b [2]float64) float64 {
		return (a[0]-o[0])*(b[1]-o[1]) - (a[1]-o[1])*(b[0]-o[0])
	}
	var h [][2]float64
	for _, p := range ps {
		for len(h) >= 2 && cross(h[len(h)-2], h[len(h)-1], p) <= 0 {
			h = h[:len(h)-1]
		}
		h = append(h, p)
	}
	lower := len(h) + 1
	for i := len(ps) - 2; i >= 0; i-- {
		for len(h) >= lower && cross(h[len(h)-2], h[len(h)-1], ps[i]) <= 0 {
			h = h[:len(h)-1]
		}
		h = append(h, ps[i])
	}
	return h[:len(h)-1]
}

func init() {
	gaitStyles["crab.scuttle"] = gaitStyle{
		About:   "a crab scuttling sideways: alternating tetrapod (L1 L3 R2 R4 / L2 L4 R1 R3), the planted feet sweeping under the body as it goes, claws up",
		Cycle:   0.5,
		Samples: 12,
		Pose:    wtScuttle{duty: 0.55, sweep: 0.2, up: 0.11, bob: 1.5}.pose,
	}
	gaitStyles["crab.hermit"] = gaitStyle{
		About:   "a hermit crab walking forwards on two pairs of legs (L1 with R2, L2 with R1), the shell rocking after it",
		Cycle:   0.55,
		Samples: 12,
		Pose:    wtScuttle{duty: 0.6, sweep: 0.26, up: 0.12, bob: 1.5, shell: true}.pose,
	}
	gaitStyles["fish.swim"] = gaitStyle{
		About:   "a fish swimming carangiform: the rear third and the tail beating smoothly a quarter beat after the body, fins sculling",
		Cycle:   0.6,
		Samples: 12,
		Pose:    fishSwim,
	}
	gaitStyles["shrimp.swim"] = gaitStyle{
		About:   "a shrimp swimming on its swimmerets: a metachronal beat, quick back and slow forward, three a loop; a small tail flick once a loop",
		Cycle:   0.9,
		Samples: 18,
		Pose:    shrimpSwim,
	}
	gaitStyles["octopus.swim"] = gaitStyle{
		About:   "an octopus jetting: arms spread slowly as the mantle fills, close quickly as it squeezes, rising on the jet",
		Cycle:   1.2,
		Samples: 16,
		Pose:    octopusSwim,
	}
	gaitStyles["turtle.swim"] = gaitStyle{
		About:   "a sea turtle flying through the water: both front flippers together, a long slow downstroke, the back flippers steering",
		Cycle:   1.2,
		Samples: 16,
		Pose:    turtleSwim,
	}
	gaitStyles["seal.swim"] = gaitStyle{
		About:   "a seal swimming with its hind flippers and a body wave, fore flippers held in",
		Cycle:   1.0,
		Samples: 14,
		Pose:    sealSwim,
	}
	gaitStyles["prone.paddle"] = gaitStyle{
		About:   "lying on a board paddling towards us: front-crawl arms half a loop apart, in ahead, pull back, out and round",
		Cycle:   1.1,
		Samples: 16,
		Pose:    pronePaddle(false),
	}
	gaitStyles["prone.paddle-away"] = gaitStyle{
		About:   "lying on a board paddling away, seen from behind: front-crawl arms half a loop apart",
		Cycle:   1.1,
		Samples: 16,
		Pose:    pronePaddle(true),
	}
	gaitStyles["caterpillar.crawl"] = gaitStyle{
		About:   "a caterpillar crawling: segments lift and step forward one after another from the tail to the head, the rest staying put",
		Cycle:   1.0,
		Samples: 20,
		Pose:    caterpillarCrawl,
	}
	gaitStyles["snail.crawl"] = gaitStyle{
		About:   "a snail gliding on its foot: slow and even, the front stretching on and the tail drawing up",
		Cycle:   1.2,
		Samples: 12,
		Pose:    snailCrawl,
	}
	gaitStyles["urchin.creep"] = gaitStyle{
		About:   "a sea urchin creeping on its tube feet: a very slow glide, spines swaying",
		Cycle:   1.2,
		Samples: 12,
		Pose:    urchinCreep,
	}
	gaitStyles["object.roll"] = gaitStyle{
		About:   "a rigid thing rolling without slipping: one turn a loop at an even pace, travelling its outline's length",
		Cycle:   1.6,
		Samples: 12,
		Pose:    objectRoll,
	}
}
