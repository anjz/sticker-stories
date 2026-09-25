// Package effects validates a story's effect trigger sidecar
// (docs/effects.md, "Trigger file"). It is the authoring-time, strict half
// of the contract: the app decodes the same file leniently (skip/clamp/log),
// so anything this package rejects would merely be ignored on device — but
// silently broken content is exactly what validation exists to catch.
//
// The libraries are closed: 12 sticker effects (Names) and the canvas
// effects (CanvasNames), each suited to one or more pack settings.
// docs/effects/effects.json is the shared catalogue; a test checks the names
// here match it.
package effects

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"regexp"
	"sort"
	"strings"
)

// SupportedSchema is the only trigger-file schema this validator accepts.
const SupportedSchema = 1

// Names lists every effect, in library order.
var Names = []string{
	"pulse", "wobble", "shake", "hop", "spin", "float",
	"fade-in", "fade-out", "glow", "tint",
	"sparkle", "hearts",
}

// CanvasNames lists every canvas effect (weather and light over the whole
// scene), in library order.
var CanvasNames = []string{
	"fog", "rain", "sunshine", "rainbow", "night", "snow", "sunset",
	"clouds", "wind", "fireflies", "leaves", "dimlight", "windowlight",
	"firelight", "rainywindow", "confetti", "bubbles", "shootingstars",
	"nebula", "warp", "comet", "sunrays", "ripples",
	"deepwater", "glowplankton", "current", "sandcloud",
}

// CanvasSettings maps each canvas effect to the pack settings it suits
// (docs/pack-format.md, "setting"). A pack whose setting is "none" gets no
// canvas effects.
var CanvasSettings = map[string][]string{
	"fog":           {"outdoors"},
	"rain":          {"outdoors"},
	"sunshine":      {"outdoors"},
	"rainbow":       {"outdoors"},
	"night":         {"outdoors"},
	"snow":          {"outdoors"},
	"sunset":        {"outdoors"},
	"clouds":        {"outdoors"},
	"wind":          {"outdoors"},
	"fireflies":     {"outdoors"},
	"leaves":        {"outdoors"},
	"dimlight":      {"indoors"},
	"windowlight":   {"indoors"},
	"firelight":     {"indoors"},
	"rainywindow":   {"indoors"},
	"confetti":      {"outdoors", "indoors", "space"},
	"bubbles":       {"outdoors", "indoors", "space", "underwater"},
	"shootingstars": {"space"},
	"nebula":        {"space"},
	"warp":          {"space"},
	"comet":         {"space"},
	"sunrays":       {"underwater"},
	"ripples":       {"underwater"},
	"deepwater":     {"underwater"},
	"glowplankton":  {"underwater"},
	"current":       {"underwater"},
	"sandcloud":     {"underwater"},
}

var (
	oneWay          = set("fade-in", "fade-out")
	supportsHold    = set("fade-in", "fade-out", "glow", "tint")
	readsColor      = set("glow", "tint", "sparkle")
	requiresColor   = set("tint")
	known           = set(Names...)
	knownCanvas     = set(CanvasNames...)
	knownKeys       = set("at", "cue", "sticker", "effect", "repeat", "duration", "intensity", "color", "hold")
	knownCanvasKeys = set("at", "cue", "effect", "intensity", "duration")
	knownLiveKeys   = set("at", "cue", "sticker", "animation", "mode")
	knownFaceKeys   = set("at", "cue", "sticker", "expression")
	knownEnterKeys  = set("at", "cue", "sticker", "enter", "by")
	knownGoKeys     = set("at", "cue", "sticker", "go", "target", "by", "toward")
	colorPattern    = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)
)

const (
	MaxRepeat   = 50
	MinDuration = 0.05
	MaxDuration = 30.0
	// Canvas effects stay on for whole beats or whole stories.
	CanvasMinDuration = 1.0
	CanvasMaxDuration = 120.0
)

// SuitsSetting reports whether a canvas effect may be used in a pack with
// the given setting.
func SuitsSetting(canvasEffect, setting string) bool {
	for _, s := range CanvasSettings[canvasEffect] {
		if s == setting {
			return true
		}
	}
	return false
}

func set(items ...string) map[string]bool {
	m := make(map[string]bool, len(items))
	for _, s := range items {
		m[s] = true
	}
	return m
}

// AllStickers is the reserved sticker target meaning every placed sticker
// (sticker effects and expressions; a pack may not name a sticker this).
const AllStickers = "all"

// Normal is the expression that shows the sticker's own image.
const Normal = "normal"

// Animations maps each sticker ID to the live animations it declares
// (docs/pack-format.md, "Live animations"): the actions a live trigger may
// play, and the moves an entrance or a move may go by ("by").
type Animations map[string][]Animation

// Animation is one animation a trigger may name: an action, and whether
// it has a frame it can pause on ("mode": "hold"), or a move.
type Animation struct {
	ID       string
	Pausable bool
	Move     bool
}

func (a Animations) find(sticker, id string) (Animation, bool) {
	for _, x := range a[sticker] {
		if x.ID == id {
			return x, true
		}
	}
	return Animation{}, false
}

// Expressions maps each sticker ID to its expression variants' ids
// ("Expressions").
type Expressions map[string][]string

func (e Expressions) has(sticker, id string) bool {
	for _, x := range e[sticker] {
		if x == id {
			return true
		}
	}
	return false
}

// ValidateFile reads and strictly validates a trigger sidecar. declared
// maps sticker IDs the pack defines, animations their live animations;
// setting is the pack's setting (docs/pack-format.md). Every problem found
// is returned.
func ValidateFile(path string, declared map[string]bool, animations Animations, expressions Expressions, features map[string]bool, setting string) []error {
	data, err := os.ReadFile(path)
	if err != nil {
		return []error{fmt.Errorf("reading effects file: %w", err)}
	}
	return Validate(data, declared, animations, expressions, features, setting)
}

// Validate strictly validates the raw JSON of a trigger sidecar. declared
// maps the pack's sticker IDs (nil skips that check) and animations the
// live animations each declares (nil skips that check); features the
// pack's named places a move may go to (nil skips that check); setting is
// the pack's setting, which every canvas trigger must suit.
func Validate(data []byte, declared map[string]bool, animations Animations, expressions Expressions, features map[string]bool, setting string) []error {
	var errs []error
	fail := func(format string, args ...any) {
		errs = append(errs, fmt.Errorf(format, args...))
	}

	var root map[string]json.RawMessage
	if err := json.Unmarshal(data, &root); err != nil {
		return []error{fmt.Errorf("effects file is not a JSON object: %w", err)}
	}

	rawSchema, ok := root["schema"]
	if !ok {
		fail("schema is required (want %d)", SupportedSchema)
	} else {
		var schema int
		if err := json.Unmarshal(rawSchema, &schema); err != nil || schema != SupportedSchema {
			fail("schema must be %d", SupportedSchema)
		}
	}
	for key := range root {
		if key != "schema" && key != "triggers" {
			fail("unknown top-level key %q", key)
		}
	}

	rawTriggers, ok := root["triggers"]
	if !ok {
		fail("triggers is required")
		return errs
	}
	var triggers []json.RawMessage
	if err := json.Unmarshal(rawTriggers, &triggers); err != nil {
		fail("triggers must be an array")
		return errs
	}

	entered := map[string]bool{}
	for i, raw := range triggers {
		label := fmt.Sprintf("triggers[%d]", i)
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(raw, &fields); err != nil {
			fail("%s: must be an object", label)
			continue
		}
		// One list, five kinds: an entrance says enter, an expression names
		// an expression, a live animation an animation, and none of them
		// has an effect; otherwise the effect name says which.
		if _, ok := fields["enter"]; ok {
			validateEnterTrigger(label, fields, declared, animations, entered, fail)
			continue
		}
		if _, ok := fields["go"]; ok {
			validateGoTrigger(label, fields, declared, animations, features, fail)
			continue
		}
		if _, ok := fields["expression"]; ok {
			validateFaceTrigger(label, fields, declared, expressions, fail)
			continue
		}
		if _, ok := fields["animation"]; ok {
			validateLiveTrigger(label, fields, declared, animations, fail)
			continue
		}
		if raw, ok := fields["effect"]; ok {
			var name string
			if json.Unmarshal(raw, &name) == nil && knownCanvas[name] {
				validateCanvasTrigger(label, name, fields, setting, fail)
				continue
			}
		}
		validateTrigger(label, fields, declared, fail)
	}
	return errs
}

func sortedKeys(fields map[string]json.RawMessage) []string {
	keys := make([]string, 0, len(fields))
	for k := range fields {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func validateTrigger(label string, fields map[string]json.RawMessage, declared map[string]bool, fail func(string, ...any)) {
	for _, k := range sortedKeys(fields) {
		if !knownKeys[k] {
			fail("%s: unknown key %q", label, k)
		}
	}

	effect := requireString(label, "effect", fields, fail)
	if effect != "" && !known[effect] {
		fail("%s: unknown effect %q", label, effect)
		effect = ""
	}
	sticker := requireString(label, "sticker", fields, fail)
	if sticker != "" && sticker != AllStickers && declared != nil && !declared[sticker] {
		fail("%s: sticker %q is not declared in the manifest", label, sticker)
	}
	if raw, ok := fields["at"]; !ok {
		fail("%s: at is required", label)
	} else if at, ok := number(raw); !ok || at < 0 {
		fail("%s: at must be a number >= 0", label)
	}
	if raw, ok := fields["cue"]; ok {
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			fail("%s: cue must be a string", label)
		}
	}

	if raw, ok := fields["repeat"]; ok {
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			if s != "loop" {
				fail("%s: repeat must be an integer or \"loop\"", label)
			}
		} else if n, ok := number(raw); !ok || n != math.Trunc(n) || n < 1 || n > MaxRepeat {
			fail("%s: repeat must be an integer in 1..%d or \"loop\"", label, MaxRepeat)
		}
		if oneWay[effect] {
			fail("%s: repeat is ignored by one-way effect %q; remove it", label, effect)
		}
	}
	if raw, ok := fields["duration"]; ok {
		if d, ok := number(raw); !ok || d < MinDuration || d > MaxDuration {
			fail("%s: duration must be a number in %g..%g", label, MinDuration, MaxDuration)
		}
	}
	if raw, ok := fields["intensity"]; ok {
		if v, ok := number(raw); !ok || v < 0 || v > 1 {
			fail("%s: intensity must be a number in 0..1", label)
		}
	}
	hasColor := false
	if raw, ok := fields["color"]; ok {
		var s string
		if err := json.Unmarshal(raw, &s); err != nil || !colorPattern.MatchString(s) {
			fail("%s: color must be \"#RRGGBB\"", label)
		} else {
			hasColor = true
		}
		if effect != "" && !readsColor[effect] {
			fail("%s: color is ignored by %q; remove it", label, effect)
		}
	}
	if effect != "" && requiresColor[effect] && !hasColor {
		fail("%s: %q requires a color", label, effect)
	}
	if raw, ok := fields["hold"]; ok {
		var b bool
		if err := json.Unmarshal(raw, &b); err != nil {
			fail("%s: hold must be true or false", label)
		}
		if effect != "" && !supportsHold[effect] {
			fail("%s: hold is ignored by %q; remove it", label, effect)
		}
	}
}

// validateCanvasTrigger checks a trigger whose effect is a canvas effect:
// no sticker, only intensity and duration, and an effect that suits the
// pack's setting.
func validateCanvasTrigger(label, effect string, fields map[string]json.RawMessage, setting string, fail func(string, ...any)) {
	for _, k := range sortedKeys(fields) {
		if !knownCanvasKeys[k] {
			if knownKeys[k] {
				fail("%s: %s is not used by canvas effect %q; remove it", label, k, effect)
			} else {
				fail("%s: unknown key %q", label, k)
			}
		}
	}
	if !SuitsSetting(effect, setting) {
		fail("%s: canvas effect %q suits %s packs; this pack's setting is %q", label, effect, strings.Join(CanvasSettings[effect], "/"), setting)
	}
	if raw, ok := fields["at"]; !ok {
		fail("%s: at is required", label)
	} else if at, ok := number(raw); !ok || at < 0 {
		fail("%s: at must be a number >= 0", label)
	}
	if raw, ok := fields["cue"]; ok {
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			fail("%s: cue must be a string", label)
		}
	}
	if raw, ok := fields["duration"]; ok {
		if d, ok := number(raw); !ok || d < CanvasMinDuration || d > CanvasMaxDuration {
			fail("%s: duration must be a number in %g..%g for a canvas effect", label, CanvasMinDuration, CanvasMaxDuration)
		}
	}
	if raw, ok := fields["intensity"]; ok {
		if v, ok := number(raw); !ok || v < 0 || v > 1 {
			fail("%s: intensity must be a number in 0..1", label)
		}
	}
}

// validateFaceTrigger checks an expression change: a sticker (or all), an
// expression that sticker has (or normal), at and an optional cue.
func validateFaceTrigger(label string, fields map[string]json.RawMessage, declared map[string]bool, expressions Expressions, fail func(string, ...any)) {
	for _, k := range sortedKeys(fields) {
		if !knownFaceKeys[k] {
			fail("%s: %s is not used by an expression; remove it", label, k)
		}
	}
	sticker := requireString(label, "sticker", fields, fail)
	if sticker != "" && sticker != AllStickers && declared != nil && !declared[sticker] {
		fail("%s: sticker %q is not declared in the manifest", label, sticker)
		sticker = ""
	}
	expression := requireString(label, "expression", fields, fail)
	if expression != "" && expression != Normal && expressions != nil {
		switch {
		case sticker == AllStickers:
			found := false
			for _, ids := range expressions {
				for _, id := range ids {
					found = found || id == expression
				}
			}
			if !found {
				fail("%s: no sticker has the expression %q", label, expression)
			}
		case sticker != "" && !expressions.has(sticker, expression):
			fail("%s: sticker %q has no expression %q", label, sticker, expression)
		}
	}
	if raw, ok := fields["at"]; !ok {
		fail("%s: at is required", label)
	} else if at, ok := number(raw); !ok || at < 0 {
		fail("%s: at must be a number >= 0", label)
	}
	if raw, ok := fields["cue"]; ok {
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			fail("%s: cue must be a string", label)
		}
	}
}

// Move kinds (docs/effects.md, "Movement"): beside another sticker or to
// a place (to), on or under another sticker, off the canvas (away), back
// to its own spot (back).
var goKinds = set("to", "on", "under", "away", "back")

// validateGoTrigger checks a move: one sticker (never all), a kind, a
// target for to (a sticker or a feature), on and under (a sticker), none
// for away and back, at and an optional cue.
func validateGoTrigger(label string, fields map[string]json.RawMessage, declared map[string]bool, animations Animations, features map[string]bool, fail func(string, ...any)) {
	for _, k := range sortedKeys(fields) {
		if !knownGoKeys[k] {
			fail("%s: %s is not used by a move; remove it", label, k)
		}
	}
	sticker := requireString(label, "sticker", fields, fail)
	if sticker == AllStickers {
		fail("%s: a move names one sticker, not %q", label, AllStickers)
	} else if sticker != "" && declared != nil && !declared[sticker] {
		fail("%s: sticker %q is not declared in the manifest", label, sticker)
	}
	kind := requireString(label, "go", fields, fail)
	if kind != "" && !goKinds[kind] {
		fail("%s: go must be one of to, on, under, away, back, got %q", label, kind)
	}
	var target string
	if raw, ok := fields["target"]; ok {
		if err := json.Unmarshal(raw, &target); err != nil || target == "" {
			fail("%s: target must be a non-empty string", label)
		}
	}
	switch kind {
	case "to", "on", "under":
		switch {
		case target == "":
			fail("%s: go %s needs a target", label, kind)
		case target == sticker:
			fail("%s: a sticker cannot go %s itself", label, kind)
		case declared != nil && !declared[target] && (kind != "to" || features == nil || !features[target]):
			if kind == "to" {
				fail("%s: target %q is neither a declared sticker nor a feature", label, target)
			} else {
				fail("%s: target %q is not a declared sticker", label, target)
			}
		}
	case "away", "back":
		if target != "" {
			fail("%s: go %s takes no target", label, kind)
		}
	}
	validateBy(label, sticker, fields, animations, fail)
	if raw, ok := fields["toward"]; ok {
		var side string
		if err := json.Unmarshal(raw, &side); err != nil || (side != "left" && side != "right") {
			fail("%s: toward must be left or right", label)
		} else if kind != "to" && kind != "away" {
			fail("%s: toward is only for go to and go away", label)
		}
	}
	if raw, ok := fields["at"]; !ok {
		fail("%s: at is required", label)
	} else if at, ok := number(raw); !ok || at < 0 {
		fail("%s: at must be a number >= 0", label)
	}
}

// validateEnterTrigger checks an entrance: the moment the story first
// names a sticker, when the app brings it into the scene if the child has
// not placed it (docs/effects.md, "Entrances"). A declared sticker (never
// all), "enter": true, at and an optional cue; one per sticker.
func validateEnterTrigger(label string, fields map[string]json.RawMessage, declared map[string]bool, animations Animations, entered map[string]bool, fail func(string, ...any)) {
	for _, k := range sortedKeys(fields) {
		if !knownEnterKeys[k] {
			fail("%s: %s is not used by an entrance; remove it", label, k)
		}
	}
	var enter bool
	if err := json.Unmarshal(fields["enter"], &enter); err != nil || !enter {
		fail("%s: enter must be true", label)
	}
	sticker := requireString(label, "sticker", fields, fail)
	switch {
	case sticker == AllStickers:
		fail("%s: an entrance names one sticker, not %q", label, AllStickers)
	case sticker != "" && declared != nil && !declared[sticker]:
		fail("%s: sticker %q is not declared in the manifest", label, sticker)
	case sticker != "" && entered[sticker]:
		fail("%s: sticker %q already has an entrance; one per story", label, sticker)
	}
	if sticker != "" {
		entered[sticker] = true
	}
	validateBy(label, sticker, fields, animations, fail)
	if raw, ok := fields["at"]; !ok {
		fail("%s: at is required", label)
	} else if at, ok := number(raw); !ok || at < 0 {
		fail("%s: at must be a number >= 0", label)
	}
	if raw, ok := fields["cue"]; ok {
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			fail("%s: cue must be a string", label)
		}
	}
}

// validateBy checks the move an entrance or a move goes by, when it names
// one: one of the sticker's moves (nil animations skip that check).
func validateBy(label, sticker string, fields map[string]json.RawMessage, animations Animations, fail func(string, ...any)) {
	raw, ok := fields["by"]
	if !ok {
		return
	}
	var by string
	if err := json.Unmarshal(raw, &by); err != nil || by == "" {
		fail("%s: by must be a move's id", label)
		return
	}
	if sticker != "" && sticker != AllStickers && animations != nil {
		if a, ok := animations.find(sticker, by); !ok || !a.Move {
			fail("%s: sticker %q has no move %q", label, sticker, by)
		}
	}
}

// Live trigger modes: play an action up to its pause frame and stay there,
// or play it on from there to the end. No mode plays it whole.
const (
	LiveHold   = "hold"
	LiveResume = "resume"
)

// validateLiveTrigger checks a trigger that plays one of a sticker's live
// animations: a sticker, the animation's id, at, an optional mode and an
// optional cue.
func validateLiveTrigger(label string, fields map[string]json.RawMessage, declared map[string]bool, animations Animations, fail func(string, ...any)) {
	for _, k := range sortedKeys(fields) {
		if !knownLiveKeys[k] {
			fail("%s: %s is not used by a live animation; remove it", label, k)
		}
	}
	sticker := requireString(label, "sticker", fields, fail)
	if sticker != "" && declared != nil && !declared[sticker] {
		fail("%s: sticker %q is not declared in the manifest", label, sticker)
		sticker = ""
	}
	animation := requireString(label, "animation", fields, fail)
	mode := ""
	if raw, ok := fields["mode"]; ok {
		if err := json.Unmarshal(raw, &mode); err != nil || (mode != LiveHold && mode != LiveResume) {
			fail("%s: mode must be %q or %q", label, LiveHold, LiveResume)
		}
	}
	if sticker != "" && animation != "" && animations != nil {
		if a, ok := animations.find(sticker, animation); !ok || a.Move {
			fail("%s: sticker %q has no live animation %q", label, sticker, animation)
		} else if mode != "" && !a.Pausable {
			fail("%s: %s's %s has no pause frame, so it cannot %s", label, sticker, animation, mode)
		}
	}
	if raw, ok := fields["at"]; !ok {
		fail("%s: at is required", label)
	} else if at, ok := number(raw); !ok || at < 0 {
		fail("%s: at must be a number >= 0", label)
	}
	if raw, ok := fields["cue"]; ok {
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			fail("%s: cue must be a string", label)
		}
	}
}

func requireString(label, key string, fields map[string]json.RawMessage, fail func(string, ...any)) string {
	raw, ok := fields[key]
	if !ok {
		fail("%s: %s is required", label, key)
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil || s == "" {
		fail("%s: %s must be a non-empty string", label, key)
		return ""
	}
	return s
}

func number(raw json.RawMessage) (float64, bool) {
	var f float64
	if err := json.Unmarshal(raw, &f); err != nil {
		return 0, false
	}
	return f, true
}
