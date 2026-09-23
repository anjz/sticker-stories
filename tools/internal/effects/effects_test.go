package effects

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNamesMatchCatalog(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "docs", "effects", "effects.json"))
	if err != nil {
		t.Fatalf("reading catalogue: %v", err)
	}
	var catalog struct {
		TriggerSchema int `json:"triggerSchema"`
		Effects       []struct {
			Name       string   `json:"name"`
			OneWay     bool     `json:"oneWay"`
			Hold       bool     `json:"hold"`
			Parameters []string `json:"parameters"`
		} `json:"effects"`
		CanvasEffects []struct {
			Name          string    `json:"name"`
			Settings      []string  `json:"settings"`
			Parameters    []string  `json:"parameters"`
			DurationRange []float64 `json:"durationRange"`
		} `json:"canvasEffects"`
	}
	if err := json.Unmarshal(data, &catalog); err != nil {
		t.Fatalf("decoding catalogue: %v", err)
	}
	if catalog.TriggerSchema != SupportedSchema {
		t.Errorf("catalogue triggerSchema %d, validator supports %d", catalog.TriggerSchema, SupportedSchema)
	}
	if len(catalog.Effects) != len(Names) {
		t.Fatalf("catalogue has %d effects, validator knows %d", len(catalog.Effects), len(Names))
	}
	for i, e := range catalog.Effects {
		if e.Name != Names[i] {
			t.Errorf("effects[%d]: catalogue %q, validator %q", i, e.Name, Names[i])
		}
		if e.OneWay != oneWay[e.Name] || e.Hold != supportsHold[e.Name] {
			t.Errorf("%s: oneWay/hold flags disagree with the catalogue", e.Name)
		}
		reads := false
		for _, p := range e.Parameters {
			if p == "color" {
				reads = true
			}
		}
		if reads != readsColor[e.Name] {
			t.Errorf("%s: color parameter disagrees with the catalogue", e.Name)
		}
	}
	if len(catalog.CanvasEffects) != len(CanvasNames) {
		t.Fatalf("catalogue has %d canvas effects, validator knows %d", len(catalog.CanvasEffects), len(CanvasNames))
	}
	for i, e := range catalog.CanvasEffects {
		if e.Name != CanvasNames[i] {
			t.Errorf("canvasEffects[%d]: catalogue %q, validator %q", i, e.Name, CanvasNames[i])
		}
		if strings.Join(e.Settings, ",") != strings.Join(CanvasSettings[e.Name], ",") {
			t.Errorf("%s: settings disagree with the catalogue: %v vs %v", e.Name, e.Settings, CanvasSettings[e.Name])
		}
		if strings.Join(e.Parameters, ",") != "intensity,duration" {
			t.Errorf("%s: canvas effects take intensity and duration only, catalogue says %v", e.Name, e.Parameters)
		}
		if len(e.DurationRange) != 2 || e.DurationRange[0] != CanvasMinDuration || e.DurationRange[1] != CanvasMaxDuration {
			t.Errorf("%s: duration range disagrees with the catalogue: %v", e.Name, e.DurationRange)
		}
	}
}

func TestCanvasTriggersAreValidated(t *testing.T) {
	good := []byte(`{ "schema": 1, "triggers": [
	  { "at": 4.5, "cue": "rain", "effect": "rain", "intensity": 0.8, "duration": 20 },
	  { "at": 0, "effect": "fog" },
	  { "at": 30, "effect": "rainbow", "duration": 1 },
	  { "at": 1, "sticker": "fox", "effect": "hop" }
	] }`)
	if errs := Validate(good, set("fox"), nil, nil, "outdoors"); len(errs) != 0 {
		t.Fatalf("unexpected errors: %v", errs)
	}
	if errs := Validate([]byte(`{"schema": 1, "triggers": [{"at": 0, "effect": "dimlight"}]}`), nil, nil, nil, "indoors"); len(errs) != 0 {
		t.Fatalf("dimlight should suit an indoors pack: %v", errs)
	}
	cases := []struct {
		name, json, setting, want string
	}{
		{"wrong setting", `{"schema": 1, "triggers": [{"at": 0, "effect": "rain"}]}`, "indoors", `suits outdoors packs; this pack's setting is "indoors"`},
		{"no setting", `{"schema": 1, "triggers": [{"at": 0, "effect": "dimlight"}]}`, "none", `suits indoors packs`},
		{"sticker on canvas", `{"schema": 1, "triggers": [{"at": 0, "effect": "fog", "sticker": "fox"}]}`, "outdoors", "sticker is not used by canvas effect"},
		{"repeat on canvas", `{"schema": 1, "triggers": [{"at": 0, "effect": "fog", "repeat": "loop"}]}`, "outdoors", "repeat is not used"},
		{"hold on canvas", `{"schema": 1, "triggers": [{"at": 0, "effect": "sunshine", "hold": true}]}`, "outdoors", "hold is not used"},
		{"color on canvas", `{"schema": 1, "triggers": [{"at": 0, "effect": "rainbow", "color": "#FF0000"}]}`, "outdoors", "color is not used"},
		{"unknown key", `{"schema": 1, "triggers": [{"at": 0, "effect": "rainbow", "wind": 3}]}`, "outdoors", `unknown key "wind"`},
		{"missing at", `{"schema": 1, "triggers": [{"effect": "rain"}]}`, "outdoors", "at is required"},
		{"duration too short", `{"schema": 1, "triggers": [{"at": 0, "effect": "rain", "duration": 0.5}]}`, "outdoors", "duration must be a number in 1..120"},
		{"duration too long", `{"schema": 1, "triggers": [{"at": 0, "effect": "rain", "duration": 500}]}`, "outdoors", "duration must be"},
		{"intensity out of range", `{"schema": 1, "triggers": [{"at": 0, "effect": "rain", "intensity": 3}]}`, "outdoors", "intensity must be"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			errs := Validate([]byte(tc.json), set("fox"), nil, nil, tc.setting)
			if len(errs) == 0 {
				t.Fatalf("expected an error containing %q, got none", tc.want)
			}
			for _, e := range errs {
				if strings.Contains(e.Error(), tc.want) {
					return
				}
			}
			t.Fatalf("no error contained %q; got %v", tc.want, errs)
		})
	}
}

func TestValidFileHasNoErrors(t *testing.T) {
	data := []byte(`{ "schema": 1, "triggers": [
	  { "at": 3.2, "cue": "sneeze", "sticker": "fox", "effect": "wobble", "repeat": 3 },
	  { "at": 3.2, "sticker": "fox", "effect": "sparkle", "intensity": 0.8, "color": "#FFD166" },
	  { "at": 0, "sticker": "tree", "effect": "float", "repeat": "loop" },
	  { "at": 41.5, "sticker": "fox", "effect": "fade-out", "hold": true },
	  { "at": 5, "sticker": "fox", "effect": "tint", "color": "#FF0000", "duration": 0.2 }
	] }`)
	if errs := Validate(data, set("fox", "tree"), nil, nil, "outdoors"); len(errs) != 0 {
		t.Fatalf("unexpected errors: %v", errs)
	}
}

func TestValidationFailures(t *testing.T) {
	cases := []struct {
		name string
		json string
		want string
	}{
		{"not an object", `[]`, "not a JSON object"},
		{"missing schema", `{"triggers": []}`, "schema is required"},
		{"wrong schema", `{"schema": 2, "triggers": []}`, "schema must be 1"},
		{"missing triggers", `{"schema": 1}`, "triggers is required"},
		{"unknown top-level key", `{"schema": 1, "triggers": [], "extra": 1}`, `unknown top-level key "extra"`},
		{"unknown effect", `{"schema": 1, "triggers": [{"at": 0, "sticker": "fox", "effect": "explode"}]}`, `unknown effect "explode"`},
		{"undeclared sticker", `{"schema": 1, "triggers": [{"at": 0, "sticker": "dragon", "effect": "pulse"}]}`, "not declared"},
		{"missing at", `{"schema": 1, "triggers": [{"sticker": "fox", "effect": "pulse"}]}`, "at is required"},
		{"negative at", `{"schema": 1, "triggers": [{"at": -1, "sticker": "fox", "effect": "pulse"}]}`, "at must be a number >= 0"},
		{"unknown key", `{"schema": 1, "triggers": [{"at": 0, "sticker": "fox", "effect": "pulse", "easing": "x"}]}`, `unknown key "easing"`},
		{"repeat too big", `{"schema": 1, "triggers": [{"at": 0, "sticker": "fox", "effect": "pulse", "repeat": 51}]}`, "repeat must be"},
		{"repeat bad string", `{"schema": 1, "triggers": [{"at": 0, "sticker": "fox", "effect": "pulse", "repeat": "forever"}]}`, "repeat must be"},
		{"repeat on one-way", `{"schema": 1, "triggers": [{"at": 0, "sticker": "fox", "effect": "fade-in", "repeat": 2}]}`, "repeat is ignored"},
		{"duration out of range", `{"schema": 1, "triggers": [{"at": 0, "sticker": "fox", "effect": "pulse", "duration": 99}]}`, "duration must be"},
		{"intensity out of range", `{"schema": 1, "triggers": [{"at": 0, "sticker": "fox", "effect": "pulse", "intensity": 1.5}]}`, "intensity must be"},
		{"bad color", `{"schema": 1, "triggers": [{"at": 0, "sticker": "fox", "effect": "glow", "color": "gold"}]}`, "color must be"},
		{"color on non-color effect", `{"schema": 1, "triggers": [{"at": 0, "sticker": "fox", "effect": "hop", "color": "#FFFFFF"}]}`, "color is ignored"},
		{"tint without color", `{"schema": 1, "triggers": [{"at": 0, "sticker": "fox", "effect": "tint"}]}`, "requires a color"},
		{"hold on non-hold effect", `{"schema": 1, "triggers": [{"at": 0, "sticker": "fox", "effect": "hop", "hold": true}]}`, "hold is ignored"},
		{"hold not bool", `{"schema": 1, "triggers": [{"at": 0, "sticker": "fox", "effect": "glow", "hold": "yes"}]}`, "hold must be"},
		{"trigger not object", `{"schema": 1, "triggers": ["x"]}`, "must be an object"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			errs := Validate([]byte(tc.json), set("fox", "tree"), nil, nil, "outdoors")
			if len(errs) == 0 {
				t.Fatalf("expected an error containing %q, got none", tc.want)
			}
			for _, e := range errs {
				if strings.Contains(e.Error(), tc.want) {
					return
				}
			}
			t.Fatalf("no error contained %q; got %v", tc.want, errs)
		})
	}
}

func TestLiveTriggers(t *testing.T) {
	anims := Animations{"fox": {"yawn"}}
	good := []byte(`{"schema": 1, "triggers": [{"at": 1.5, "cue": "yawned", "sticker": "fox", "animation": "yawn"}]}`)
	if errs := Validate(good, set("fox"), anims, nil, "outdoors"); len(errs) != 0 {
		t.Fatalf("valid live trigger rejected: %v", errs)
	}
	cases := []struct{ name, json, want string }{
		{"unknown animation", `{"schema": 1, "triggers": [{"at": 0, "sticker": "fox", "animation": "dance"}]}`, "no live animation"},
		{"no sticker", `{"schema": 1, "triggers": [{"at": 0, "animation": "yawn"}]}`, "sticker is required"},
		{"undeclared sticker", `{"schema": 1, "triggers": [{"at": 0, "sticker": "owl", "animation": "yawn"}]}`, "not declared"},
		{"effect keys", `{"schema": 1, "triggers": [{"at": 0, "sticker": "fox", "animation": "yawn", "effect": "hop"}]}`, "not used by a live animation"},
		{"no at", `{"schema": 1, "triggers": [{"sticker": "fox", "animation": "yawn"}]}`, "at is required"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			errs := Validate([]byte(tc.json), set("fox"), anims, nil, "outdoors")
			for _, e := range errs {
				if strings.Contains(e.Error(), tc.want) {
					return
				}
			}
			t.Fatalf("no error contained %q; got %v", tc.want, errs)
		})
	}
}

func TestFaceTriggersAndAllTargets(t *testing.T) {
	faces := Expressions{"fox": {"happy", "sleeping"}}
	good := []byte(`{"schema": 1, "triggers": [
		{"at": 1, "cue": "smiled", "sticker": "fox", "expression": "happy"},
		{"at": 2, "sticker": "all", "expression": "sleeping"},
		{"at": 3, "sticker": "all", "expression": "normal"},
		{"at": 4, "sticker": "all", "effect": "hop"}]}`)
	if errs := Validate(good, set("fox"), nil, faces, "outdoors"); len(errs) != 0 {
		t.Fatalf("valid expression triggers rejected: %v", errs)
	}
	cases := []struct{ name, json, want string }{
		{"unknown face", `{"schema": 1, "triggers": [{"at": 0, "sticker": "fox", "expression": "angry"}]}`, `no expression "angry"`},
		{"nobody has it", `{"schema": 1, "triggers": [{"at": 0, "sticker": "all", "expression": "angry"}]}`, "no sticker has"},
		{"extra keys", `{"schema": 1, "triggers": [{"at": 0, "sticker": "fox", "expression": "happy", "duration": 2}]}`, "not used by an expression"},
		{"no sticker", `{"schema": 1, "triggers": [{"at": 0, "expression": "happy"}]}`, "sticker is required"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			for _, e := range Validate([]byte(tc.json), set("fox"), nil, faces, "outdoors") {
				if strings.Contains(e.Error(), tc.want) {
					return
				}
			}
			t.Fatalf("no error contained %q", tc.want)
		})
	}
}
