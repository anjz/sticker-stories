package main

import (
	"flag"
	"fmt"
	"image"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"sort"
	"strings"
	"sync"

	"stickerstories/tools/internal/manifest"
	"stickerstories/tools/internal/stickerimg"
)

// check looks at installed puppets for the defects a review keeps finding
// (docs/pack-art.md, "3. Puppets"): a joint end that shows its outline
// where a limb meets the body, a bone away from its piece's joint, eyes
// that look opposite ways, a piece that faces the other way from the
// sticker, a face that slides off its head. It poses the rig as the app
// does and measures the parts' alpha masks; it only warns.

// checkOptions are the thresholds, in the rig's pixels (the sticker image
// at stickerSize) unless they say otherwise.
type checkOptions struct {
	// Tuck is how deep a joint end should go under what covers it.
	Tuck float64
	// Seam is how much outline at a joint end, drawn over another part,
	// shows as a seam (px of outline).
	Seam float64
	// BoneOut is how far outside its piece a bone may sit.
	BoneOut float64
	// BoneGap is how far a bone may sit from where its piece meets the
	// part it hangs on.
	BoneGap float64
	// Skew is how lopsided an eye must be (its dark pixels' centre off its
	// middle, as a fraction of its width) to say which way it looks.
	Skew float64
	// Mirror is how much better (correlation with the sticker) a piece
	// must match mirrored to say it faces the wrong way.
	Mirror float64
	// Slide is how much more of a face piece (a fraction of it) may leave
	// the head in a key than at rest.
	Slide float64
	// Turn is how far (degrees) an eye may turn on its own.
	Turn float64
	// Keys also checks every key of every animation (seams, the face).
	Keys bool
}

func defaultCheckOptions() checkOptions {
	return checkOptions{Tuck: 17, Seam: 40, BoneOut: 12, BoneGap: 60, Skew: 0.06, Mirror: 0.15, Slide: 0.1, Turn: 4, Keys: true}
}

// A finding is one warning: the sticker, where (an animation and its keys,
// or the rest), the rule and what it found.
type finding struct {
	Sticker, Anim, Rule, Msg string
	Keys                     []int
}

func (f finding) String() string {
	where := ""
	if f.Anim != "" {
		where = f.Anim
		if len(f.Keys) > 0 {
			var ks []string
			for _, k := range f.Keys {
				ks = append(ks, fmt.Sprint(k))
			}
			where += " key " + strings.Join(ks, ",")
		}
		where += ": "
	}
	return fmt.Sprintf("⚠ %-6s %s%s", f.Rule, where, f.Msg)
}

func runCheck(args []string) error {
	fs := flag.NewFlagSet("check", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	artDir := fs.String("art", "", "art directory (default author/art/<packID>)")
	only := fs.String("only", "", "comma-separated sticker ids")
	o := defaultCheckOptions()
	fs.Float64Var(&o.Tuck, "tuck", o.Tuck, "px a joint end should tuck under the part that covers it")
	fs.Float64Var(&o.Seam, "seam", o.Seam, "px of joint-end outline over another part that make a seam")
	fs.Float64Var(&o.BoneOut, "bone-out", o.BoneOut, "px a bone may sit outside its piece")
	fs.Float64Var(&o.BoneGap, "bone-gap", o.BoneGap, "px a bone may sit from where its piece meets its parent's parts")
	fs.Float64Var(&o.Skew, "skew", o.Skew, "how lopsided an eye must be to say which way it looks (fraction of its width)")
	fs.Float64Var(&o.Mirror, "mirror", o.Mirror, "how much better a mirrored piece must match the sticker (correlation)")
	fs.Float64Var(&o.Slide, "slide", o.Slide, "fraction more of a face piece that may leave the head in a key")
	fs.Float64Var(&o.Turn, "turn", o.Turn, "degrees an eye may turn on its own")
	fs.BoolVar(&o.Keys, "keys", o.Keys, "check every animation key too")
	fs.Parse(args)
	c, err := load(*packDir, *artDir, *only)
	if err != nil {
		return err
	}
	total, stickers := 0, 0
	for _, res := range c.checkAll(o) {
		found, err := res.found, res.err
		if err != nil {
			fmt.Printf("%s: %v\n", res.sticker, err)
			continue
		}
		printFindings(res.sticker, found)
		if len(found) > 0 {
			total += len(found)
			stickers++
		}
	}
	fmt.Printf("%d warnings on %d of %d puppets\n", total, stickers, len(c.rigs()))
	return nil
}

// warnChecks runs the check on the rigs just installed and prints what it
// finds: warnings only, never a reason to refuse.
func (c *ctxt) warnChecks() {
	for _, res := range c.checkAll(defaultCheckOptions()) {
		found, err := res.found, res.err
		if err != nil {
			fmt.Printf("  check %s: %v\n", res.sticker, err)
			continue
		}
		if len(found) > 0 {
			fmt.Printf("  check (stickerrig check -only %s):\n", res.sticker)
			for _, f := range found {
				fmt.Printf("    %s\n", f)
			}
		}
	}
}

type checkResult struct {
	sticker string
	found   []finding
	err     error
}

// checkAll checks the rigs -only asks for, several at once, in order.
func (c *ctxt) checkAll(o checkOptions) []checkResult {
	rigs := c.rigs()
	out := make([]checkResult, len(rigs))
	var wg sync.WaitGroup
	sem := make(chan struct{}, runtime.NumCPU())
	for i, r := range rigs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			found, err := c.checkRig(r.Sticker, o)
			out[i] = checkResult{r.Sticker, found, err}
		}()
	}
	wg.Wait()
	return out
}

func printFindings(sticker string, found []finding) {
	if len(found) == 0 {
		fmt.Printf("✓ %s\n", sticker)
		return
	}
	fmt.Printf("%s\n", sticker)
	for _, f := range found {
		fmt.Printf("  %s\n", f)
	}
}

// ---------- posing ----------

// mat is a 2D affine transform as a canvas has it: x' = a x + c y + e,
// y' = b x + d y + f.
type mat struct{ a, b, c, d, e, f float64 }

var identity = mat{a: 1, d: 1}

func (m mat) mul(n mat) mat {
	return mat{
		a: m.a*n.a + m.c*n.b, b: m.b*n.a + m.d*n.b,
		c: m.a*n.c + m.c*n.d, d: m.b*n.c + m.d*n.d,
		e: m.a*n.e + m.c*n.f + m.e, f: m.b*n.e + m.d*n.f + m.f,
	}
}
func translate(x, y float64) mat { return mat{a: 1, d: 1, e: x, f: y} }
func rotate(deg float64) mat {
	s, c := math.Sincos(deg * math.Pi / 180)
	return mat{a: c, b: s, c: -s, d: c}
}
func scale(x, y float64) mat                        { return mat{a: x, d: y} }
func (m mat) apply(x, y float64) (float64, float64) { return m.a*x + m.c*y + m.e, m.b*x + m.d*y + m.f }
func (m mat) inv() mat {
	det := m.a*m.d - m.b*m.c
	if det == 0 {
		return identity
	}
	a, b, c, d := m.d/det, -m.b/det, -m.c/det, m.a/det
	return mat{a: a, b: b, c: c, d: d, e: -(a*m.e + c*m.f), f: -(b*m.e + d*m.f)}
}

// puppet is an installed rig, its atlas and the sticker, ready to pose.
type puppet struct {
	rig     *manifest.PuppetRig
	atlas   *image.RGBA
	sticker *image.RGBA // at rig.Size
	bone    map[string]manifest.PuppetBone
	slot    map[string]int
}

func newPuppet(rig *manifest.PuppetRig, atlas, sticker *image.RGBA) *puppet {
	p := &puppet{rig: rig, atlas: atlas, sticker: sticker, bone: map[string]manifest.PuppetBone{}, slot: map[string]int{}}
	for _, b := range rig.Bones {
		p.bone[b.ID] = b
	}
	for i, s := range rig.Slots {
		p.slot[s.ID] = i
	}
	return p
}

// world is every bone's transform in a pose, as the preview and the app
// compute it.
func (p *puppet) world(poses map[string]manifest.BonePose) map[string]mat {
	w := map[string]mat{}
	for _, b := range p.rig.Bones {
		q := poses[b.ID]
		sx, sy := 1.0, 1.0
		if q.SX != nil {
			sx = *q.SX
		}
		if q.SY != nil {
			sy = *q.SY
		}
		m, rx, ry := identity, b.X, b.Y
		if b.Parent != "" {
			par := p.bone[b.Parent]
			m, rx, ry = w[b.Parent], b.X-par.X, b.Y-par.Y
		}
		w[b.ID] = m.mul(translate(rx+q.X, ry+q.Y)).mul(rotate(q.R)).mul(scale(sx, sy))
	}
	return w
}

// shown is the attachment each slot shows: a key's, else the face's, else
// the slot's default.
func (p *puppet) shown(face string, key map[string]string) map[string]string {
	out := map[string]string{}
	f := p.rig.Faces[face]
	for _, s := range p.rig.Slots {
		switch {
		case key[s.ID] != "":
			out[s.ID] = key[s.ID]
		case f[s.ID] != "":
			out[s.ID] = f[s.ID]
		default:
			out[s.ID] = s.Default
		}
	}
	return out
}

// layer is one slot's attachment drawn in a pose: its alpha and its
// luma (0–255) over r, in the rig's pixels.
type layer struct {
	slot    int
	id, att string
	bone    string
	flip    bool
	r       image.Rectangle
	a, l    []uint8
	m       mat
	opaque  int
	cx, cy  float64 // centroid of its opaque pixels
}

func (l *layer) alpha(x, y int) uint8 {
	if x < l.r.Min.X || y < l.r.Min.Y || x >= l.r.Max.X || y >= l.r.Max.Y {
		return 0
	}
	return l.a[(y-l.r.Min.Y)*l.r.Dx()+x-l.r.Min.X]
}

func (l *layer) luma(x, y int) uint8 { return l.l[(y-l.r.Min.Y)*l.r.Dx()+x-l.r.Min.X] }

// draw renders one attachment under the world transform of its bone.
func (p *puppet) draw(slot int, att string, world map[string]mat, flip bool) *layer {
	s := p.rig.Slots[slot]
	a, ok := s.Attachments[att]
	if !ok || att == manifest.PuppetHidden {
		return nil
	}
	part, ok := p.rig.Parts[a.Part]
	if !ok || a.W <= 0 || a.H <= 0 {
		return nil
	}
	b := p.bone[s.Bone]
	fx := 1.0
	if flip {
		fx = -1
	}
	m := world[s.Bone].mul(translate(a.X+a.W/2-b.X, a.Y+a.H/2-b.Y)).mul(rotate(a.Rotate)).mul(scale(fx, 1))
	minX, minY, maxX, maxY := math.Inf(1), math.Inf(1), math.Inf(-1), math.Inf(-1)
	for _, c := range [4][2]float64{{-1, -1}, {1, -1}, {-1, 1}, {1, 1}} {
		x, y := m.apply(c[0]*a.W/2, c[1]*a.H/2)
		minX, minY, maxX, maxY = math.Min(minX, x), math.Min(minY, y), math.Max(maxX, x), math.Max(maxY, y)
	}
	r := image.Rect(int(math.Floor(minX)), int(math.Floor(minY)), int(math.Ceil(maxX)), int(math.Ceil(maxY)))
	l := &layer{slot: slot, id: s.ID, att: att, bone: s.Bone, flip: flip, r: r, m: m,
		a: make([]uint8, r.Dx()*r.Dy()), l: make([]uint8, r.Dx()*r.Dy())}
	inv := m.inv()
	rx, ry, rw, rh := float64(part.Rect[0]), float64(part.Rect[1]), float64(part.Rect[2]), float64(part.Rect[3])
	ab := p.atlas.Bounds()
	var sx, sy float64
	for y := r.Min.Y; y < r.Max.Y; y++ {
		lx, ly := inv.apply(float64(r.Min.X)-0.5, float64(y)+0.5)
		for x := r.Min.X; x < r.Max.X; x++ {
			lx, ly = lx+inv.a, ly+inv.b
			if lx < -a.W/2 || lx >= a.W/2 || ly < -a.H/2 || ly >= a.H/2 {
				continue
			}
			u := int(rx + (lx+a.W/2)*rw/a.W)
			v := int(ry + (ly+a.H/2)*rh/a.H)
			if u < ab.Min.X || v < ab.Min.Y || u >= ab.Max.X || v >= ab.Max.Y {
				continue
			}
			o := p.atlas.PixOffset(u, v)
			al := p.atlas.Pix[o+3]
			if al == 0 {
				continue
			}
			i := (y-r.Min.Y)*r.Dx() + x - r.Min.X
			l.a[i] = al
			px := p.atlas.Pix[o : o+3]
			lum := (0.299*float64(px[0]) + 0.587*float64(px[1]) + 0.114*float64(px[2])) * 255 / float64(al)
			l.l[i] = uint8(math.Min(255, lum))
			if al >= 128 {
				l.opaque++
				sx += float64(x) + 0.5
				sy += float64(y) + 0.5
			}
		}
	}
	if l.opaque > 0 {
		l.cx, l.cy = sx/float64(l.opaque), sy/float64(l.opaque)
	}
	return l
}

// pose draws every slot that shows something, back to front.
func (p *puppet) pose(bones map[string]manifest.BonePose, shown map[string]string) ([]*layer, map[string]mat) {
	w := p.world(bones)
	var out []*layer
	for i, s := range p.rig.Slots {
		a := s.Attachments[shown[s.ID]]
		if l := p.draw(i, shown[s.ID], w, a.Flip); l != nil && l.opaque > 0 {
			out = append(out, l)
		}
	}
	return out, w
}

// maxAlpha is the most opaque of the layers at a pixel.
func maxAlpha(ls []*layer, x, y int) uint8 {
	var m uint8
	for _, l := range ls {
		if v := l.alpha(x, y); v > m {
			m = v
		}
	}
	return m
}

// overlapping keeps the layers whose box meets r.
func overlapping(ls []*layer, r image.Rectangle) []*layer {
	var out []*layer
	for _, l := range ls {
		if l.r.Overlaps(r) {
			out = append(out, l)
		}
	}
	return out
}

// ---------- the rig's anatomy ----------

type anatomy struct {
	parent  map[string]string
	trunk   map[string]bool // the bone of the biggest piece and its ancestors
	face    map[string]bool // slots of the face: eyes, brows, mouths…
	eyes    []string        // eye slots
	faceID  string          // the face bone, if any
	jointed map[string]bool // slots on a joint (a limb, a head, a wing…)
}

func isFaceSlot(id string) bool {
	id = strings.ToLower(id)
	for _, p := range []string{"eye", "brow", "mouth", "beak", "tear", "blush", "cheek", "nose", "pupil", "lid", "tongue", "teeth"} {
		if strings.HasPrefix(id, p) {
			return true
		}
	}
	return false
}

func (p *puppet) anatomy(rest []*layer) *anatomy {
	an := &anatomy{parent: map[string]string{}, trunk: map[string]bool{}, face: map[string]bool{}, jointed: map[string]bool{}}
	for _, b := range p.rig.Bones {
		an.parent[b.ID] = b.Parent
		if b.ID == "face" {
			an.faceID = "face"
		}
	}
	var big *layer
	for _, l := range rest {
		if big == nil || l.opaque > big.opaque {
			big = l
		}
	}
	// The trunk: the bone that breathes (the body's art), else the
	// biggest piece's, and the bones it hangs on.
	trunk := ""
	if p.rig.Idle != nil && p.rig.Idle.Breathe != "" {
		trunk = p.rig.Idle.Breathe
	} else if big != nil {
		trunk = big.bone
	}
	for b := trunk; b != ""; b = an.parent[b] {
		an.trunk[b] = true
	}
	for _, s := range p.rig.Slots {
		if isFaceSlot(s.ID) || (an.faceID != "" && an.under(s.Bone, an.faceID)) {
			an.face[s.ID] = true
		}
		if strings.HasPrefix(strings.ToLower(s.ID), "eye") && !strings.HasPrefix(strings.ToLower(s.ID), "eyebrow") {
			an.eyes = append(an.eyes, s.ID)
		}
		if !an.trunk[s.Bone] && !an.face[s.ID] && an.parent[s.Bone] != "" {
			an.jointed[s.ID] = true
		}
	}
	return an
}

// under says whether bone b is anc or hangs on it.
func (an *anatomy) under(b, anc string) bool {
	for ; b != ""; b = an.parent[b] {
		if b == anc {
			return true
		}
	}
	return false
}

// ---------- the rules ----------

// jointEnd measures a piece hung on a joint: J is the bone's point. It
// says whether the bone is at one end of the piece (not in its middle,
// like an eye's) and how deep the end towards the bone goes under the
// layers above it, and how much of its outline there shows over the
// layers below it.
type jointEnd struct {
	ok    bool
	depth float64 // px fully covered from the joint end
	seam  int     // px of the end's outline drawn over another part
	over  string  // the part most of that outline lies over
}

const (
	opaqueAlpha = 128
	solidAlpha  = 200
	darkLuma    = 110 // an outline's pixels (dark brown in the packs' style)
)

func measureJoint(l *layer, jx, jy float64, above, below []*layer, drawn func(x, y int) bool, o checkOptions) jointEnd {
	// below: only the parts it hangs on (an outline over anything else is
	// the limb's own, as the drawing has it).
	dx, dy := l.cx-jx, l.cy-jy
	dist := math.Hypot(dx, dy)
	req := math.Sqrt(float64(l.opaque) / math.Pi)
	if dist < 0.5*req || l.opaque < 100 {
		return jointEnd{}
	}
	ux, uy := dx/dist, dy/dist
	above, below = overlapping(above, l.r), overlapping(below, l.r)
	w := l.r.Dx()
	tmin, tmax := math.Inf(1), math.Inf(-1)
	for y := l.r.Min.Y; y < l.r.Max.Y; y++ {
		for x := l.r.Min.X; x < l.r.Max.X; x++ {
			if l.a[(y-l.r.Min.Y)*w+x-l.r.Min.X] >= opaqueAlpha {
				t := (float64(x)+0.5-jx)*ux + (float64(y)+0.5-jy)*uy
				if t < tmin {
					tmin = t
				}
				if t > tmax {
					tmax = t
				}
			}
		}
	}
	if float64(l.opaque)/math.Max(1, tmax-tmin) < 10 {
		return jointEnd{} // a string, a whisker: no joint end to hide
	}
	look := int(3*o.Tuck) + 1
	count, open := make([]int, look), make([]int, look)
	band := math.Max(o.Tuck, 0.25*(tmax-tmin))
	seam := 0
	overBy := map[string]int{}
	for y := l.r.Min.Y; y < l.r.Max.Y; y++ {
		for x := l.r.Min.X; x < l.r.Max.X; x++ {
			if l.a[(y-l.r.Min.Y)*w+x-l.r.Min.X] < opaqueAlpha {
				continue
			}
			t := (float64(x)+0.5-jx)*ux + (float64(y)+0.5-jy)*uy - tmin
			covered := maxAlpha(above, x, y) >= opaqueAlpha
			if i := int(t); i < look {
				count[i]++
				if !covered {
					open[i]++
				}
			}
			if t >= band || covered || !isRing(l, x, y) || !darkNear(l, x, y, 3) || (drawn != nil && drawn(x, y)) {
				continue
			}
			var under *layer
			for _, b := range below {
				if b.alpha(x, y) >= solidAlpha {
					under = b
				}
			}
			if under != nil {
				seam++
				overBy[under.id]++
			}
		}
	}
	depth := float64(look)
	for i := range look {
		if count[i] >= 3 && float64(open[i]) > 0.25*float64(count[i]) {
			depth = float64(i)
			break
		}
	}
	over := ""
	for id, n := range overBy {
		if n > overBy[over] || (n == overBy[over] && id < over) {
			over = id
		}
	}
	return jointEnd{ok: true, depth: depth, seam: seam, over: over}
}

// isRing: an opaque pixel of the layer next to a clear one, its edge.
func isRing(l *layer, x, y int) bool {
	for _, d := range [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}} {
		if l.alpha(x+d[0], y+d[1]) < opaqueAlpha {
			return true
		}
	}
	return false
}

// interior: the layer's edge at x, y runs inside the puppet's shape, with
// another part just outside it (an outline there is not the silhouette's).
func interior(l *layer, x, y int, others []*layer) bool {
	for _, d := range [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}} {
		for k := 1; k <= 2; k++ {
			px, py := x+k*d[0], y+k*d[1]
			if l.alpha(px, py) < opaqueAlpha {
				if maxAlpha(others, px, py) < opaqueAlpha {
					return false
				}
				break
			}
		}
	}
	return true
}

// darkNear: an outline's dark, solid pixel of the layer within r px.
func darkNear(l *layer, x, y, r int) bool {
	for dy := -r; dy <= r; dy++ {
		for dx := -r; dx <= r; dx++ {
			px, py := x+dx, y+dy
			if l.alpha(px, py) >= solidAlpha && l.luma(px, py) < darkLuma {
				return true
			}
		}
	}
	return false
}

// skew says which way an eye looks: its dark pixels' centre (the pupil,
// the lashes) left (−) or right (+) of its middle, as a fraction of its
// width; 0 when it has no dark pixels.
func skew(l *layer) float64 {
	var ax, an, dx, dn float64
	w := l.r.Dx()
	for y := l.r.Min.Y; y < l.r.Max.Y; y++ {
		for x := l.r.Min.X; x < l.r.Max.X; x++ {
			i := (y-l.r.Min.Y)*w + x - l.r.Min.X
			if l.a[i] < solidAlpha {
				continue
			}
			ax += float64(x)
			an++
			if l.l[i] < 80 {
				dx += float64(x)
				dn++
			}
		}
	}
	if an == 0 || dn < 4 || dn > 0.9*an {
		return 0
	}
	return (dx/dn - ax/an) / float64(max(w, 1))
}

// stickerCorr is how well the layer's visible pixels (not covered by the
// layers above) match the sticker's: the correlation of their luma.
func (p *puppet) stickerCorr(l *layer, above []*layer) (float64, int) {
	above = overlapping(above, l.r)
	var n, sa, sb, saa, sbb, sab float64
	sb0 := p.sticker.Bounds()
	for y := l.r.Min.Y; y < l.r.Max.Y; y++ {
		for x := l.r.Min.X; x < l.r.Max.X; x++ {
			if l.alpha(x, y) < solidAlpha || maxAlpha(above, x, y) >= opaqueAlpha || !image.Pt(x, y).In(sb0) {
				continue
			}
			o := p.sticker.PixOffset(x, y)
			al := p.sticker.Pix[o+3]
			if al < solidAlpha {
				continue
			}
			px := p.sticker.Pix[o : o+3]
			b := (0.299*float64(px[0]) + 0.587*float64(px[1]) + 0.114*float64(px[2])) * 255 / float64(al)
			a := float64(l.luma(x, y))
			n++
			sa, sb, saa, sbb, sab = sa+a, sb+b, saa+a*a, sbb+b*b, sab+a*b
		}
	}
	if n < 50 {
		return 0, int(n)
	}
	va, vb := saa/n-(sa/n)*(sa/n), sbb/n-(sb/n)*(sb/n)
	if va < 1 || vb < 1 {
		return 0, int(n)
	}
	return (sab/n - sa/n*sb/n) / math.Sqrt(va*vb), int(n)
}

// offHead is the fraction of a face layer outside the head's layers.
func offHead(l *layer, head []*layer) float64 {
	head = overlapping(head, l.r)
	off, all := 0, 0
	for y := l.r.Min.Y; y < l.r.Max.Y; y++ {
		for x := l.r.Min.X; x < l.r.Max.X; x++ {
			if l.alpha(x, y) < opaqueAlpha {
				continue
			}
			all++
			if maxAlpha(head, x, y) < opaqueAlpha {
				off++
			}
		}
	}
	if all == 0 {
		return 0
	}
	return float64(off) / float64(all)
}

// drawn says whether the sticker has an outline (a dark, solid pixel)
// within r px: an outline the puppet shows there is the drawing's own.
func (p *puppet) drawn(x, y, r int) bool {
	b := p.sticker.Bounds()
	for dy := -r; dy <= r; dy++ {
		for dx := -r; dx <= r; dx++ {
			px, py := x+dx, y+dy
			if !image.Pt(px, py).In(b) {
				continue
			}
			o := p.sticker.PixOffset(px, py)
			al := p.sticker.Pix[o+3]
			if al < solidAlpha {
				continue
			}
			c := p.sticker.Pix[o : o+3]
			if (0.299*float64(c[0])+0.587*float64(c[1])+0.114*float64(c[2]))*255/float64(al) < darkLuma {
				return true
			}
		}
	}
	return false
}

// ---------- the check ----------

func (c *ctxt) loadPuppet(sticker string) (*puppet, []*manifest.StickerAnimation, error) {
	rig, err := manifest.LoadPuppetRig(filepath.Join(c.packDir, "anims", sticker+".rig.json"))
	if err != nil {
		return nil, nil, fmt.Errorf("not installed: %w", err)
	}
	read := func(rel string) (*image.RGBA, error) {
		data, err := os.ReadFile(filepath.Join(c.packDir, filepath.FromSlash(rel)))
		if err != nil {
			return nil, err
		}
		return stickerimg.Decode(data)
	}
	atlas, err := read(rig.Atlas)
	if err != nil {
		return nil, nil, err
	}
	st := c.sticker(sticker)
	if st == nil {
		return nil, nil, fmt.Errorf("not in the manifest")
	}
	img, err := read(st.Image)
	if err != nil {
		return nil, nil, err
	}
	if size := int(math.Round(rig.Size)); img.Bounds().Dx() != size || img.Bounds().Dy() != size {
		img = stickerimg.Resize(img, size, size)
	}
	var anims []*manifest.StickerAnimation
	for _, rel := range st.Animations {
		a, err := manifest.LoadStickerAnimation(filepath.Join(c.packDir, filepath.FromSlash(rel)))
		if err != nil {
			return nil, nil, err
		}
		if a.Puppet != nil {
			anims = append(anims, a)
		}
	}
	return newPuppet(rig, atlas, img), anims, nil
}

func (c *ctxt) checkRig(sticker string, o checkOptions) ([]finding, error) {
	p, anims, err := c.loadPuppet(sticker)
	if err != nil {
		return nil, err
	}
	return p.check(sticker, anims, o), nil
}

func (p *puppet) check(sticker string, anims []*manifest.StickerAnimation, o checkOptions) []finding {
	var out []finding
	add := func(anim, rule, msg string, keys ...int) {
		out = append(out, finding{Sticker: sticker, Anim: anim, Rule: rule, Msg: msg, Keys: keys})
	}
	restShown := p.shown("normal", nil)
	rest, world := p.pose(nil, restShown)
	an := p.anatomy(rest)

	// Joint ends: at rest, outline the sticker does not have; in a key,
	// outline the same parts at rest do not show.
	joints := func(ls []*layer, w map[string]mat, drawn func(x, y int) bool, only func(*layer) bool) map[string]jointEnd {
		out := map[string]jointEnd{}
		for i, l := range ls {
			if !an.jointed[l.id] || (only != nil && !only(l)) {
				continue
			}
			jx, jy := w[l.bone].apply(0, 0)
			var hangs []*layer
			for _, b := range ls[:i] {
				if !an.face[b.id] && !an.under(b.bone, l.bone) && (an.trunk[b.bone] || an.under(l.bone, b.bone)) {
					hangs = append(hangs, b)
				}
			}
			if j := measureJoint(l, jx, jy, ls[i+1:], hangs, drawn, o); j.ok {
				out[l.id+"/"+l.att] = j
			}
		}
		return out
	}
	restSeams := map[string]jointEnd{}
	for id, j := range joints(rest, world, func(x, y int) bool { return p.drawn(x, y, 5) }, nil) {
		if j.depth < o.Tuck && float64(j.seam) >= o.Seam {
			restSeams[id] = j
		}
	}
	for _, k := range sortedKeys(restSeams) {
		j := restSeams[k]
		add("", "seam", fmt.Sprintf("%s: its joint end tucks %.0f px under what covers it (want %.0f); %d px of its outline show over %s", slotAtt(k), j.depth, o.Tuck, j.seam, j.over))
	}

	// Outlines that show through another part's faded end.
	for i, l := range rest {
		if an.face[l.id] {
			continue
		}
		above := overlapping(rest[i+1:], l.r)
		var others []*layer
		for _, q := range overlapping(rest, l.r.Inset(-2)) {
			if q != l {
				others = append(others, q)
			}
		}
		n, by := 0, map[string]int{}
		for y := l.r.Min.Y; y < l.r.Max.Y; y++ {
			for x := l.r.Min.X; x < l.r.Max.X; x++ {
				if l.alpha(x, y) < opaqueAlpha || !isRing(l, x, y) || !darkNear(l, x, y, 2) {
					continue
				}
				m := maxAlpha(above, x, y)
				if m < 40 || m >= solidAlpha || p.drawn(x, y, 5) || !interior(l, x, y, others) {
					continue
				}
				n++
				for _, a := range above {
					if a.alpha(x, y) == m {
						by[a.id]++
					}
				}
			}
		}
		if float64(n) >= 2*o.Seam {
			var who []string
			for id := range by {
				who = append(who, id)
			}
			sort.Strings(who)
			add("", "fade", fmt.Sprintf("%s: %d px of its outline show through the faded end of %s (draw it without that outline, or over them)", l.id, n, strings.Join(who, ", ")))
		}
	}

	// Bones at their pieces' joints: every attachment of a jointed slot.
	// The bone lies inside the piece (a joint end turns about a point of
	// itself), and near where the piece meets what it hangs on: the parts
	// on its bone's ancestors and the trunk.
	var trunkArea int
	for _, l := range rest {
		if an.trunk[l.bone] {
			trunkArea = max(trunkArea, l.opaque)
		}
	}
	for i, s := range p.rig.Slots {
		if !an.jointed[s.ID] || len(an.eyes) == 0 {
			continue // an object's pieces rest and lean more than they hinge
		}
		var parents []*layer
		for _, l := range rest {
			if !an.face[l.id] && !an.under(l.bone, s.Bone) && (an.trunk[l.bone] || an.under(s.Bone, l.bone)) {
				parents = append(parents, l)
			}
		}
		jx, jy := world[s.Bone].apply(0, 0)
		for _, att := range sortedKeys(s.Attachments) {
			l := p.draw(i, att, world, s.Attachments[att].Flip)
			if l == nil || l.opaque < 100 {
				continue
			}
			req := math.Sqrt(float64(l.opaque) / math.Pi)
			if math.Hypot(l.cx-jx, l.cy-jy) < 0.5*req {
				continue // turns about its middle
			}
			if out, _ := boneGap(l, jx, jy, nil); out > o.BoneOut {
				add("", "bone", fmt.Sprintf("%s: the %s bone is %.0f px outside its piece (put it inside the joint end, at the joint)", slotAtt(s.ID+"/"+att), s.Bone, out))
				continue
			}
			if float64(l.opaque) > 0.6*float64(trunkArea) {
				continue // the whole body in another pose: it meets everything
			}
			if d, on := boneGap(l, jx, jy, overlapping(parents, l.r)); on != "" && d > o.BoneGap {
				add("", "bone", fmt.Sprintf("%s: the %s bone is %.0f px from where the piece meets %s (put it at the joint)", slotAtt(s.ID+"/"+att), s.Bone, d, on))
			}
		}
	}

	// Eyes: a pair looks the same way in every face, and a slot's
	// expressions look the way its default does.
	faces := []string{"normal"}
	for f := range p.rig.Faces {
		if f != "normal" {
			faces = append(faces, f)
		}
	}
	sort.Strings(faces[1:])
	look := func(id, att string) (float64, *layer) {
		i := p.slot[id]
		a := p.rig.Slots[i].Attachments[att]
		l := p.draw(i, att, world, a.Flip)
		if l == nil {
			return 0, nil
		}
		return skew(l), l
	}
	for _, e := range an.eyes {
		if !strings.HasSuffix(e, "L") {
			continue
		}
		pair := strings.TrimSuffix(e, "L") + "R"
		if _, ok := p.slot[pair]; !ok {
			continue
		}
		var bad []string
		for _, f := range faces {
			sh := p.shown(f, nil)
			a, b := sh[e], sh[pair]
			sa, la := look(e, a)
			sb, lb := look(pair, b)
			if gazeless(a) || gazeless(b) || la == nil || lb == nil || math.Abs(sa) < o.Skew || math.Abs(sb) < o.Skew || (sa > 0) == (sb > 0) {
				continue
			}
			what := f
			if la.flip != lb.flip && p.rig.Slots[p.slot[e]].Attachments[a].Part == p.rig.Slots[p.slot[pair]].Attachments[b].Part {
				what += " (one mirrored)"
			}
			bad = append(bad, what)
		}
		if len(bad) > 0 {
			add("", "eyes", fmt.Sprintf("%s and %s look opposite ways in %s: draw each eye for its side, looking the sticker's way, never mirrored", e, pair, strings.Join(bad, ", ")))
		}
	}
	for _, e := range an.eyes {
		s := p.rig.Slots[p.slot[e]]
		s0, l0 := look(e, s.Default)
		if l0 == nil || math.Abs(s0) < o.Skew {
			continue
		}
		var bad []string
		for _, att := range sortedKeys(s.Attachments) {
			if att == s.Default || gazeless(att) || s.Attachments[att].Flip == s.Attachments[s.Default].Flip {
				continue
			}
			if sa, l := look(e, att); l != nil && math.Abs(sa) >= o.Skew && (sa > 0) != (s0 > 0) {
				bad = append(bad, att)
			}
		}
		if len(bad) > 0 {
			add("", "flip", fmt.Sprintf("%s: %s flipped otherwise than %s and look the other way", e, strings.Join(bad, ", "), s.Default))
		}
	}

	// Mirrored pieces (and eyes) that match the sticker better the other
	// way round.
	for i, l := range rest {
		if an.trunk[l.bone] || !(l.flip || slices.Contains(an.eyes, l.id)) {
			continue
		}
		above := rest[i+1:]
		as, n := p.stickerCorr(l, above)
		if n < 150 && !an.face[l.id] {
			continue
		}
		m := p.draw(l.slot, l.att, world, !l.flip)
		ms, _ := p.stickerCorr(m, above)
		if ms-as >= o.Mirror && ms >= 0.3 {
			way := "flipped"
			if l.flip {
				way = "not flipped"
			}
			add("", "mirror", fmt.Sprintf("%s: faces the other way from the sticker's (matches it %.2f as it is, %.2f %s)", slotAtt(l.id+"/"+l.att), as, ms, way))
		}
	}

	if !o.Keys {
		return out
	}
	// Every key: the face stays on the head, eyes do not turn alone, and
	// no joint end shows that rest hides.
	var head []string
	if an.faceID != "" {
		hb := an.parent[an.faceID]
		for _, s := range p.rig.Slots {
			if !an.face[s.ID] && s.Bone == hb {
				head = append(head, s.ID)
			}
		}
		if len(head) == 0 { // the face is on the body
			for _, s := range p.rig.Slots {
				if !an.face[s.ID] && an.trunk[s.Bone] {
					head = append(head, s.ID)
				}
			}
		}
	}
	pick := func(ls []*layer, ids []string) []*layer {
		var out []*layer
		for _, l := range ls {
			if slices.Contains(ids, l.id) {
				out = append(out, l)
			}
		}
		return out
	}
	// The parts at rest showing a key's attachments, and their joint
	// ends: keys share them.
	type stillPose struct {
		ls     []*layer
		joints map[string]jointEnd
	}
	stills := map[string]*stillPose{}
	stillFor := func(sh map[string]string) *stillPose {
		var sig strings.Builder
		for _, sl := range p.rig.Slots {
			sig.WriteString(sh[sl.ID] + "\x00")
		}
		if st, ok := stills[sig.String()]; ok {
			return st
		}
		ls, w := p.pose(nil, sh)
		st := &stillPose{ls: ls, joints: joints(ls, w, nil, nil)}
		stills[sig.String()] = st
		return st
	}
	for _, a := range anims {
		var slideWorst struct {
			v    float64
			what string
		}
		var slideKeys, turnKeys []int
		turnWhat := ""
		seams := map[string][]int{}
		seamWhat := map[string]jointEnd{}
		for ki, k := range a.Puppet.Keys {
			sh := p.shown("normal", k.Slots)
			if len(k.Bones) == 0 {
				continue // a pose at rest: what rest has
			}
			ls, w := p.pose(k.Bones, sh)
			st := stillFor(sh)
			if len(head) > 0 {
				still := st.ls
				hk, hr := pick(ls, head), pick(still, head)
				worst, who := 0.0, ""
				for _, l := range ls {
					if id := strings.ToLower(l.id); !strings.HasPrefix(id, "eye") && !strings.HasPrefix(id, "brow") {
						continue // eyes and brows sit on the head; a beak or a mouth may stick out
					}
					if l.bone != an.faceID && !an.under(l.bone, an.faceID) {
						continue
					}
					var r *layer
					for _, s := range still {
						if s.id == l.id {
							r = s
						}
					}
					if r == nil {
						continue
					}
					if d := offHead(l, hk) - offHead(r, hr); d > worst {
						worst, who = d, l.id
					}
				}
				if worst > o.Slide {
					slideKeys = append(slideKeys, ki)
					if worst > slideWorst.v {
						slideWorst.v, slideWorst.what = worst, fmt.Sprintf("%s %.0f %%", who, 100*worst)
					}
				}
			}
			for _, e := range an.eyes {
				b := p.rig.Slots[p.slot[e]].Bone
				if b == an.faceID || an.faceID == "" || !an.under(b, an.faceID) {
					continue // eyes on stalks turn on their own
				}
				if r := k.Bones[b].R; math.Abs(r) > o.Turn {
					turnKeys = append(turnKeys, ki)
					turnWhat = fmt.Sprintf("%s by %.0f°", e, r)
					break
				}
			}
			// Only limbs that turn on the body: what moves with it keeps
			// its joints as at rest.
			moved := func(l *layer) bool {
				for b := l.bone; b != "" && !an.trunk[b]; b = an.parent[b] {
					if q, ok := k.Bones[b]; ok && (q.R != 0 || q.X != 0 || q.Y != 0 || q.SX != nil || q.SY != nil) {
						return true
					}
				}
				return false
			}
			for id, j := range joints(ls, w, nil, moved) {
				if _, atRest := restSeams[id]; atRest || j.depth >= o.Tuck {
					continue
				}
				if j.seam -= st.joints[id].seam; float64(j.seam) < o.Seam {
					continue
				}
				seams[id] = append(seams[id], ki)
				if j.seam > seamWhat[id].seam {
					seamWhat[id] = j
				}
			}
		}
		if len(slideKeys) > 0 {
			add(a.ID, "face", fmt.Sprintf("the face slides off the head (%s more of it off than at rest): turn the head, don't shift the face", slideWorst.what), slideKeys...)
		}
		if len(turnKeys) > 0 {
			add(a.ID, "turn", fmt.Sprintf("an eye turns on its own (%s): eyes turn with the face", turnWhat), turnKeys...)
		}
		for _, id := range sortedKeys(seams) {
			j := seamWhat[id]
			add(a.ID, "seam", fmt.Sprintf("%s: its joint end shows (tucked %.0f px; %d px more outline over %s than at rest)", slotAtt(id), j.depth, j.seam, j.over), seams[id]...)
		}
	}
	return out
}

// boneGap is how far the bone's point is from where the piece meets the
// parts it hangs on (the nearest such pixel), and which part that is; with
// no such overlap, from the piece itself and "".
func boneGap(l *layer, jx, jy float64, parents []*layer) (float64, string) {
	best, bestOn, any := math.Inf(1), "", false
	pieceBest := math.Inf(1)
	for y := l.r.Min.Y; y < l.r.Max.Y; y++ {
		for x := l.r.Min.X; x < l.r.Max.X; x++ {
			if l.alpha(x, y) < opaqueAlpha {
				continue
			}
			d := math.Hypot(float64(x)+0.5-jx, float64(y)+0.5-jy)
			pieceBest = math.Min(pieceBest, d)
			for _, q := range parents {
				if q.alpha(x, y) >= opaqueAlpha {
					any = true
					if d < best {
						best, bestOn = d, q.id
					}
					break
				}
			}
		}
	}
	if !any {
		return pieceBest, ""
	}
	return best, bestOn
}

// slotAtt names "slot/attachment" as "slot" or "slot (attachment)".
func slotAtt(k string) string {
	s, a, _ := strings.Cut(k, "/")
	if a == "" || a == s {
		return s
	}
	return s + " (" + a + ")"
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// gazeless reports whether an eye attachment is shut (closed, a blink,
// asleep, a happy or crying squint): it looks nowhere, and its lashes or
// tear belong at each eye's outer corner, so a flip for the other side is
// right, not a mirrored gaze.
func gazeless(att string) bool {
	for _, w := range []string{"closed", "blink", "sleep", "happy", "cry", "squint", "shut"} {
		if strings.Contains(att, w) {
			return true
		}
	}
	return false
}
