package main

import "stickerstories/tools/internal/manifest"

// People: two-part limbs (legL/kneeL, legR/kneeR at the hips and knees,
// armL/elbowL, armR/elbowR at the shoulders and elbows), body at the
// hips, head at the neck; root at the feet. Each leg's t starts as its
// heel strikes; the other leg is half a loop behind. The curves are the
// thigh's angle from the vertical (+ forward) and the knee's bend (+ the
// shin folds back: a knee never bends forwards), after published gait
// data, softened a little for a picture-book child.

var (
	walkThigh = curve{{0, 22}, {0.15, 17}, {0.32, 4}, {0.5, -11}, {0.6, -6}, {0.7, 9}, {0.86, 23}}
	walkKnee  = curve{{0, 4}, {0.14, 17}, {0.38, 4}, {0.52, 10}, {0.62, 30}, {0.72, 58}, {0.84, 30}, {0.95, 5}}

	runThigh = curve{{0, 24}, {0.14, 10}, {0.32, -18}, {0.45, -12}, {0.6, 18}, {0.76, 40}, {0.9, 34}}
	runKnee  = curve{{0, 18}, {0.12, 36}, {0.3, 18}, {0.46, 60}, {0.6, 100}, {0.76, 82}, {0.92, 28}}

	// A skip is a step and a hop on one foot, then on the other: this
	// leg steps at 0, hops at 0.25 and lands at 0.42, then swings up
	// with its knee high while the other foot does the same.
	skipThigh = curve{{0, 16}, {0.12, 4}, {0.3, -10}, {0.44, -16}, {0.56, 8}, {0.68, 44}, {0.8, 46}, {0.92, 28}}
	skipKnee  = curve{{0, 8}, {0.1, 24}, {0.2, 12}, {0.32, 10}, {0.42, 24}, {0.54, 58}, {0.68, 92}, {0.82, 78}, {0.94, 18}}
)

// humanLimbs poses both legs and both arms from a leg's curves: the
// arms swing against the legs (the left arm forward with the right
// leg), the forearms bending as they come forward.
func humanLimbs(g *gaitBody, t float64, thigh, knee curve, armSwing, elbowRest, elbowSwing float64) map[string]manifest.BonePose {
	b := map[string]manifest.BonePose{}
	sw, as := g.swing(), g.arms()
	for _, side := range []struct {
		hip, knee, arm, elbow string
		ph                    float64
	}{{"legL", "kneeL", "armL", "elbowL", 0}, {"legR", "kneeR", "armR", "elbowR", 0.5}} {
		u := t + side.ph
		th := thigh.at(u) * sw
		b[side.hip] = manifest.BonePose{R: g.fwd(th)}
		b[side.knee] = manifest.BonePose{R: g.fwd(-knee.at(u) * sw)}
		// The arm on this side goes with the other leg.
		arm := -armSwing * as * (thigh.at(u) - thigh.at(u+0.5)) / 2 / 20
		b[side.arm] = manifest.BonePose{R: g.fwd(arm)}
		bend := elbowRest + elbowSwing*max(0, arm)/max(1, armSwing*as)
		b[side.elbow] = manifest.BonePose{R: g.fwd(bend)}
	}
	return b
}

func init() {
	gaitStyles["human.walk"] = gaitStyle{
		About:   "a person walking: heel strike, the knee soft through the step and folding in the swing, arms against the legs, the body highest over the planted foot",
		Cycle:   1.05,
		Duty:    0.62,
		Samples: 14,
		Feet:    []gaitFoot{{"legL", 0}, {"legR", 0.5}},
		Pose: func(g *gaitBody, t float64) gaitPose {
			b := humanLimbs(g, t, walkThigh, walkKnee, 12, 8, 10)
			// A little forward lean that breathes with each step; the
			// head stays level.
			lean := 2 + 0.6*wave(2*t, 0.05, 1)
			b["body"] = manifest.BonePose{R: g.lean(lean)}
			b["head"] = manifest.BonePose{R: g.lean(-lean + 0.8*wave(2*t, 0.3, 1))}
			return gaitPose{Bones: b}
		},
	}
	gaitStyles["human.run"] = gaitStyle{
		About:   "a person running: a flight between steps, knees high in the swing, elbows bent at a right angle pumping against the legs, leaning into it",
		Cycle:   0.72,
		Duty:    0.36,
		Samples: 12,
		Feet:    []gaitFoot{{"legL", 0}, {"legR", 0.5}},
		Pose: func(g *gaitBody, t float64) gaitPose {
			b := humanLimbs(g, t, runThigh, runKnee, 26, 70, 20)
			lean := 7 + 1.2*wave(2*t, 0.1, 1)
			b["body"] = manifest.BonePose{R: g.lean(lean)}
			b["head"] = manifest.BonePose{R: g.lean(-lean + 2)}
			return gaitPose{Bones: b, Lift: 0.07 * (bump(t, 0.3, 0.5) + bump(t, 0.8, 1.0))}
		},
	}
	gaitStyles["human.skip"] = gaitStyle{
		About:   "a child skipping: step-hop on one foot with the other knee swinging up high, then on the other; arms swinging big against the legs",
		Cycle:   1.1,
		Duty:    0.45,
		Samples: 16,
		Feet:    []gaitFoot{{"legL", 0}, {"legR", 0.5}},
		Pose: func(g *gaitBody, t float64) gaitPose {
			b := humanLimbs(g, t, skipThigh, skipKnee, 30, 25, 30)
			lean := 3 + 1.5*wave(2*t, 0.33, 1)
			b["body"] = manifest.BonePose{R: g.lean(lean)}
			b["head"] = manifest.BonePose{R: g.lean(-lean + 2*wave(2*t, 0.33, 1))}
			return gaitPose{Bones: b, Lift: 0.13 * (bump(t, 0.22, 0.44) + bump(t, 0.72, 0.94))}
		},
	}
}
