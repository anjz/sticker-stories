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
}

func TestValidFileHasNoErrors(t *testing.T) {
	data := []byte(`{ "schema": 1, "triggers": [
	  { "at": 3.2, "cue": "sneeze", "sticker": "fox", "effect": "wobble", "repeat": 3 },
	  { "at": 3.2, "sticker": "fox", "effect": "sparkle", "intensity": 0.8, "color": "#FFD166" },
	  { "at": 0, "sticker": "tree", "effect": "float", "repeat": "loop" },
	  { "at": 41.5, "sticker": "fox", "effect": "fade-out", "hold": true },
	  { "at": 5, "sticker": "fox", "effect": "tint", "color": "#FF0000", "duration": 0.2 }
	] }`)
	if errs := Validate(data, set("fox", "tree"), "outdoors"); len(errs) != 0 {
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
			errs := Validate([]byte(tc.json), set("fox", "tree"), "outdoors")
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
