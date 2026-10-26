package main

import (
	"fmt"
	"math"
	"os"
	"sort"
	"strings"

	"stickerstories/tools/internal/manifest"
)

// Gaits: a move's loop made from how a body of its kind moves, instead
// of keys written by hand. A style ("human.walk", "quadruped.trot") turns
// each limb along a curve over the cycle taken from how real bodies move
// (a knee bends one way, the arms swing against the legs, a walk's
// feet fall in their order); the body rises and falls so the lowest foot
// stays on the ground, and the stride is measured from the planted foot,
// so the feet do not slide while the app carries the character along.
// The loop is sampled into evenly spaced keys that move on linearly: no
// stop at every key.

// gaitSpec is an animation's "gait" in the rig file.
type gaitSpec struct {
	// Style is "<body>.<gait>", one of gaitStyles.
	Style string `json:"style"`
	// Cycle is the seconds of one loop (the style's when 0).
	Cycle float64 `json:"cycle,omitempty"`
	// Swing scales the limbs' turns (1 when 0); Arms the arms' or front
	// limbs' on top; Lift a hop's or a flight's height.
	Swing float64 `json:"swing,omitempty"`
	Arms  float64 `json:"arms,omitempty"`
	Lift  float64 `json:"lift,omitempty"`
	// Samples is how many keys the loop has (the style's when 0).
	Samples int `json:"samples,omitempty"`
	// Still are bones the gait leaves alone (an arm holding a board);
	// Pose is added to every key of the loop (that arm's grip); Slots
	// are shown through it (happy eyes on a skip).
	Still []string                     `json:"still,omitempty"`
	Pose  map[string]manifest.BonePose `json:"pose,omitempty"`
	Slots map[string]string            `json:"slots,omitempty"`
	// Bones names the rig's bone for a role of the style where it is
	// called otherwise ({"footL": "legL"}).
	Bones map[string]string `json:"bones,omitempty"`
	// Ground, for a style whose feet touch it: false lets the body float
	// as the style poses it (a swimmer's legs).
	Ground *bool `json:"ground,omitempty"`
	// Then are keys played after the loop instead of settling to rest:
	// a flight's landing, the legs reaching down and the wings flaring.
	// The last one should be at rest.
	Then []manifest.PuppetKey `json:"then,omitempty"`
}

// gaitStyle is one way a body of a kind moves.
type gaitStyle struct {
	About   string
	Cycle   float64 // seconds per loop
	Samples int     // keys per loop
	// Feet are the limbs that stand on the ground, each down from its
	// Phase of the loop for Duty of it (a walk's foot ~0.6, a run's
	// ~0.35): the planted foot is kept on its ground line. None: it swims
	// or flies.
	Feet []gaitFoot
	Duty float64
	// Hops: the app lifts it in an arc once per loop (a hop drawn in
	// place). A style that leaves the ground otherwise lifts it itself.
	Hops, Flies bool
	// Pose is the body at t (0–1) of the loop: turns and shifts by role.
	Pose func(g *gaitBody, t float64) gaitPose
}

type gaitFoot struct {
	Role  string
	Phase float64
}

// gaitPose is a style's pose at a moment of its loop.
type gaitPose struct {
	Bones map[string]manifest.BonePose // by role
	// Lift raises the body off the ground, in leg lengths (a skip's
	// flight), on top of the lowest foot standing on it.
	Lift float64
}

// gaitStyles are every style, by name; each body's file adds its own.
var gaitStyles = map[string]gaitStyle{}

func gaitStyleNames() string {
	var names []string
	for n := range gaitStyles {
		names = append(names, n)
	}
	sort.Strings(names)
	return strings.Join(names, ", ")
}

// gaitBody is a rig being moved by a style.
type gaitBody struct {
	p    *puppet
	spec gaitSpec
	// dir is +1 when it travels left, −1 right: a limb hanging down
	// swings forward by dir × its turn (turns are clockwise).
	dir float64
	// leg is how long its legs are (root to the hips), in rig pixels.
	leg float64
}

// id is the rig's bone for a role, "" when it has none.
func (g *gaitBody) id(role string) string {
	if b := g.spec.Bones[role]; b != "" {
		role = b
	}
	if _, ok := g.p.bone[role]; ok {
		return role
	}
	return ""
}

func (g *gaitBody) has(role string) bool { return g.id(role) != "" }

// fwd is the turn that swings a limb hanging down deg forward (towards
// where it goes); a negative deg swings it back.
func (g *gaitBody) fwd(deg float64) float64 { return g.dir * deg }

// lean is the turn that tips something standing up deg forward.
func (g *gaitBody) lean(deg float64) float64 { return -g.dir * deg }

// ahead is a shift of px forward.
func (g *gaitBody) ahead(px float64) float64 { return -g.dir * px }

func (g *gaitBody) swing() float64 { return orOne(g.spec.Swing) }
func (g *gaitBody) arms() float64  { return orOne(g.spec.Arms) * g.swing() }
func (g *gaitBody) lift() float64  { return orOne(g.spec.Lift) }

func orOne(v float64) float64 {
	if v == 0 {
		return 1
	}
	return v
}

// curve is a value over a loop: points (t 0–1, value), wrapping round,
// passed through smoothly (a periodic Catmull-Rom spline).
type curve [][2]float64

func (c curve) at(t float64) float64 {
	n := len(c)
	if n == 0 {
		return 0
	}
	if n == 1 {
		return c[0][1]
	}
	t -= math.Floor(t)
	pt := func(k int) (float64, float64) {
		i := ((k % n) + n) % n
		return c[i][0] + math.Floor(float64(k)/float64(n)), c[i][1]
	}
	k := -1
	for i := range n {
		if c[i][0] <= t {
			k = i
		}
	}
	t0, v0 := pt(k - 1)
	t1, v1 := pt(k)
	t2, v2 := pt(k + 1)
	t3, v3 := pt(k + 2)
	h := t2 - t1
	m1 := (v2 - v0) / (t2 - t0) * h
	m2 := (v3 - v1) / (t3 - t1) * h
	s := (t - t1) / h
	s2, s3 := s*s, s*s*s
	return (2*s3-3*s2+1)*v1 + (s3-2*s2+s)*m1 + (-2*s3+3*s2)*v2 + (s3-s2)*m2
}

// bump is 0 outside [from, to] of the loop and rises to 1 in its middle
// and back, smoothly (wrapping round).
func bump(t, from, to float64) float64 {
	t -= math.Floor(t)
	if to < from {
		to++
		if t < from {
			t++
		}
	}
	if t < from || t > to {
		return 0
	}
	return math.Pow(math.Sin(math.Pi*(t-from)/(to-from)), 2)
}

// wave is a sine over the loop: amp at t = peak.
func wave(t, peak, amp float64) float64 { return amp * math.Cos(2*math.Pi*(t-peak)) }

// ---------- making the keys ----------

// gaitAnim fills a move's keys, loop and stride from its gait.
func (c *ctxt) gaitAnim(r *rigSpec, a animSpec, p *puppet, box manifest.UnitBox) (animSpec, []string, error) {
	st, ok := gaitStyles[a.Gait.Style]
	if !ok {
		return a, nil, fmt.Errorf("animation %s: no gait %q (%s)", a.ID, a.Gait.Style, gaitStyleNames())
	}
	if a.Kind == "" {
		a.Kind = manifest.KindMove
	}
	g := &gaitBody{p: p, spec: *a.Gait, dir: 1}
	switch a.Facing {
	case "left":
	case "right":
		g.dir = -1
	default:
		return a, nil, fmt.Errorf("animation %s: a gait needs facing left or right", a.ID)
	}
	var notes []string
	var feet []string
	var phases []float64
	for _, f := range st.Feet {
		if id := g.id(f.Role); id != "" {
			feet = append(feet, id)
			phases = append(phases, f.Phase)
		} else {
			notes = append(notes, f.Role)
		}
	}
	if a.Gait.Ground != nil && !*a.Gait.Ground {
		feet = nil
	}
	root := p.rig.Bones[0]
	g.leg = p.rig.Size * 0.2
	if len(feet) > 0 {
		var sum float64
		for _, f := range feet {
			sum += root.Y - p.bone[f].Y
		}
		if l := sum / float64(len(feet)); l > 10 {
			g.leg = l
		}
	}
	cycle := a.Gait.Cycle
	if cycle == 0 {
		cycle = st.Cycle
	}
	n := a.Gait.Samples
	if n == 0 {
		n = st.Samples
	}
	if n == 0 {
		n = 12
	}

	ground := newGround(p, feet)

	// planted is the foot on the ground at t: one down at t, else the
	// one nearest to it (just lifting or about to land, in a flight).
	planted := func(t float64) (down []bool) {
		down = make([]bool, len(feet))
		near, nearest := -1, 2.0
		for i, ph := range phases {
			u := t - ph - math.Floor(t-ph)
			if u < st.Duty {
				down[i] = true
				near = -2
			} else if d := math.Min(u-st.Duty, 1-u); near != -2 && d < nearest {
				near, nearest = i, d
			}
		}
		if near >= 0 {
			down[near] = true
		}
		return down
	}
	var scrape float64
	measuring := false // the stride's samples between keys
	var scrapeAt float64
	pose := func(t, amp float64) (map[string]manifest.BonePose, float64) {
		gp := st.Pose(g, t)
		out := map[string]manifest.BonePose{}
		for role, b := range gp.Bones {
			id := g.id(role)
			if id == "" {
				if !strings.HasPrefix(role, "?") && !containsStr(notes, role) {
					notes = append(notes, role)
				}
				continue
			}
			if containsStr(a.Gait.Still, id) {
				continue
			}
			b.R *= amp
			b.X *= amp
			b.Y *= amp
			out[id] = b
		}
		for id, b := range a.Gait.Pose {
			q := out[id]
			q.R += b.R
			q.X += b.X
			q.Y += b.Y
			if b.SX != nil {
				q.SX = b.SX
			}
			if b.SY != nil {
				q.SY = b.SY
			}
			out[id] = q
		}
		lift := gp.Lift * g.leg * g.lift() * amp
		if len(feet) > 0 {
			q := out[root.ID]
			down := planted(t)
			dy, li := ground.stand(p.world(out), down)
			q.Y += -dy - lift
			out[root.ID] = q
			// Reach along the slant gives an even rise and fall; the foot
			// on screen still stands on its line, give or take 3 % of a
			// leg (about a point at the size stickers show).
			if tol := 0.03 * g.leg; li >= 0 && lift == 0 {
				_, ay := ground.ankleAt(li, p.world(out))
				if off := ay - ground.ankleY[li]; math.Abs(off) > tol {
					q.Y -= off - math.Copysign(tol, off)
					out[root.ID] = q
				}
			}
			// A swinging foot clears the ground: its leg comes forward a
			// little more where its toes would drag (as an ankle would
			// lift them).
			for li := range feet {
				if down[li] {
					continue
				}
				// Forward, unless that digs it in (a foot drawn pointing
				// back): then back; stop when it no longer helps.
				hip := feet[li]
				below := ground.bottom(li, p.world(out)).y - ground.rest[li]
				step := g.fwd(2)
				for k := 0; k < 12 && below > 1; k++ {
					h := out[hip]
					h.R += step
					out[hip] = h
					now := ground.bottom(li, p.world(out)).y - ground.rest[li]
					if now >= below {
						h.R -= step
						out[hip] = h
						if k > 0 || step != g.fwd(2) {
							break
						}
						step = -step
						continue
					}
					below = now
				}
				if below > 1 && amp == 1 && !measuring && below > scrape {
					scrape, scrapeAt = below, t
				}
			}
			out[root.ID] = q
		} else if lift != 0 {
			q := out[root.ID]
			q.Y -= lift
			out[root.ID] = q
		}
		for id, q := range out {
			q.R, q.X, q.Y = round2(q.R), round2(q.X), round2(q.Y)
			out[id] = q
		}
		return out, gp.Lift
	}

	const lead = 0.2
	keys := []manifest.PuppetKey{{Hold: lead}}
	// The app lifts a hopper in an arc from the moment it sets off, and
	// the loop starts after the first key: start the loop that far in.
	start := 0.0
	if st.Hops {
		start = lead / cycle
	}
	for i := range n {
		b, _ := pose(start+float64(i)/float64(n), 1)
		keys = append(keys, manifest.PuppetKey{Hold: round3(cycle / float64(n)), Ease: "linear", Bones: b, Slots: a.Gait.Slots})
	}
	if len(a.Gait.Then) > 0 {
		keys = append(keys, a.Gait.Then...)
	} else {
		settle, _ := pose(0, 0.35)
		keys = append(keys, manifest.PuppetKey{Hold: 0.3, Bones: settle, Slots: a.Gait.Slots}, manifest.PuppetKey{Hold: 0.35})
	}
	a.Keys = keys
	a.Loop = &manifest.FrameRange{From: 1, To: n}
	a.Hops, a.Flies = st.Hops, st.Flies
	a.Pause, a.Particles = nil, nil

	// The stride: how fast the planted foot goes back under the body.
	if len(feet) > 0 && !st.Hops {
		// The foot under the body goes back with the ground: follow the
		// bit of it touching the ground (not the touching point, which
		// rolls forward from heel to toe) from one moment to the next.
		const m = 240
		var back, time float64
		measuring = true
		for i := 0; i < m; i++ {
			t := float64(i) / m
			b, lift := pose(t, 1)
			if lift > 0.01 {
				continue
			}
			_, li := ground.stand(p.world(b), planted(t))
			if li < 0 {
				continue
			}
			next, nlift := pose(t+1.0/m, 1)
			if nlift > 0.01 || !planted(t + 1.0/m)[li] {
				continue // it lifts off in between
			}
			x0, _ := ground.ankleAt(li, p.world(b))
			x1, _ := ground.ankleAt(li, p.world(next))
			back += g.dir * (x1 - x0)
			time += cycle / m
			if os.Getenv("GAIT_DEBUG") != "" && i%8 == 0 {
				fmt.Printf("t=%.3f limb=%d d=%.2f root=%.1f\n", t, li, g.dir*(x1-x0), b[root.ID].Y)
			}
		}
		if width := box.Width * p.rig.Size; time > 0 && back > 0 && width > 0 {
			a.Stride = round2(back / time * cycle / width)
		}
	}
	if scrape > 2 {
		fmt.Printf("  %s (gait %s): a swinging foot goes %.0f px under the ground at t=%.2f\n", a.ID, a.Gait.Style, scrape, scrapeAt)
	}
	if a.Stride <= 0 {
		return a, notes, fmt.Errorf("animation %s: gait %s needs a stride (it has no feet on the ground)", a.ID, a.Gait.Style)
	}
	return a, notes, nil
}

func round3(v float64) float64 { return math.Round(v*1000) / 1000 }

func containsStr(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// ground finds the foot a body stands on in a pose: each foot has its
// own ground line, where it stands in the sticker (in a three-quarter
// view the far foot stands higher), and the one reaching furthest below
// its line is the one on the ground.
type ground struct {
	p     *puppet
	limbs [][]int   // per foot role, the slots on its bone and below
	rest  []float64 // per foot, its bottom at rest
	// The ankle of each foot, a little above its bottom at rest, in its
	// piece's bone: a planted foot keeps it at its height, so the body
	// rides on the legs as they swing (a foot without an ankle of its
	// own tips with the shin, and its toes would lift the body).
	ankleBone []string
	ankle     [][2]float64
	ankleY    []float64
	ankleRest [][2]float64
	feet      []string
}

type lowPoint struct {
	x, y  float64
	below float64
	limb  int
	bone  string // whose piece it is
}

func newGround(p *puppet, feet []string) *ground {
	g := &ground{p: p}
	children := map[string][]string{}
	for _, b := range p.rig.Bones {
		children[b.Parent] = append(children[b.Parent], b.ID)
	}
	for _, f := range feet {
		under := map[string]bool{}
		var walk func(string)
		walk = func(id string) {
			under[id] = true
			for _, ch := range children[id] {
				walk(ch)
			}
		}
		walk(f)
		var slots []int
		for i, s := range p.rig.Slots {
			if under[s.Bone] {
				slots = append(slots, i)
			}
		}
		g.limbs = append(g.limbs, slots)
	}
	g.feet = feet
	w := g.p.world(nil)
	for li := range g.limbs {
		lo := g.bottom(li, w)
		g.rest = append(g.rest, lo.y)
		y := lo.y - 0.08*(lo.y-p.bone[feet[li]].Y)
		ax, ay := w[lo.bone].inv().apply(lo.x, y)
		g.ankleBone = append(g.ankleBone, lo.bone)
		g.ankle = append(g.ankle, [2]float64{ax, ay})
		g.ankleY = append(g.ankleY, y)
		g.ankleRest = append(g.ankleRest, [2]float64{lo.x, y})
	}
	return g
}

// ankleAt is where a foot's ankle is in a pose's bones.
func (g *ground) ankleAt(li int, w map[string]mat) (float64, float64) {
	return w[g.ankleBone[li]].apply(g.ankle[li][0], g.ankle[li][1])
}

// stand is how far the body must go up for the planted feet to stand
// on their lines, and the foot it stands on. A leg's reach is measured
// along the way it slants in the sticker: legs drawn apart in a
// three-quarter view are apart sideways, and swing about that.
func (g *ground) stand(w map[string]mat, down []bool) (float64, int) {
	best, limb := math.Inf(-1), -1
	for li := range g.limbs {
		if !down[li] {
			continue
		}
		hx, hy := w[g.feet[li]].apply(0, 0)
		ax, ay := g.ankleAt(li, w)
		rx, ry := g.p.bone[g.feet[li]].X, g.p.bone[g.feet[li]].Y
		restX, restY := g.ankleRest[li][0]-rx, g.ankleRest[li][1]-ry
		l := math.Hypot(restX, restY)
		reach := ((ax-hx)*restX + (ay-hy)*restY) / l
		if d := hy + reach - (ry + l); d > best {
			best, limb = d, li
		}
	}
	return best, limb
}

// lowest is the foot of those given that reaches furthest below its
// ground line in a pose (the body goes up by that much to stand on it).
func (g *ground) lowest(pose map[string]manifest.BonePose, which []bool) lowPoint {
	w := g.p.world(pose)
	best := lowPoint{below: math.Inf(-1), limb: -1}
	for li := range g.limbs {
		if !which[li] {
			continue
		}
		if lo := g.bottom(li, w); lo.limb >= 0 && lo.y-g.rest[li] > best.below {
			lo.below = lo.y - g.rest[li]
			best = lo
		}
	}
	return best
}

// bottom is a foot's bottom edge (its default attachments) and where
// along it it touches.
func (g *ground) bottom(li int, w map[string]mat) lowPoint {
	best := lowPoint{y: math.Inf(-1), limb: -1}
	for _, i := range g.limbs[li] {
		s := g.p.rig.Slots[i]
		att := s.Default
		l := g.p.draw(i, att, w, s.Attachments[att].Flip)
		if l == nil || l.opaque == 0 {
			continue
		}
		for y := l.r.Max.Y - 1; y >= l.r.Min.Y; y-- {
			var top uint8
			var sx, n float64
			for x := l.r.Min.X; x < l.r.Max.X; x++ {
				if v := l.alpha(x, y); v > 0 {
					if v > top {
						top = v
					}
					sx += float64(x) + 0.5
					n++
				}
			}
			if n == 0 {
				continue
			}
			if edge := float64(y) + float64(top)/255; edge > best.y {
				best = lowPoint{x: sx / n, y: edge, limb: li, bone: s.Bone}
			}
			break
		}
	}
	return best
}
