package main

import (
	"bytes"
	"encoding/json"
	"testing"

	"stickerstories/tools/internal/manifest"
)

// The rig file's on, away and faces reach the sidecars, from the
// animation or its template.
func TestSidecarsCarryOnAwayAndFaces(t *testing.T) {
	var specs []animSpec
	dec := json.NewDecoder(bytes.NewReader([]byte(`[
		{"id": "ride-wave", "description": "the surfer rides a wave.", "on": ["sea"], "faces": "right",
		 "keys": [{"hold": 0.3}, {"hold": 0.3}]},
		{"id": "paddle", "template": "human.paddle"}
	]`)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&specs); err != nil {
		t.Fatal(err)
	}
	templates := map[string]animSpec{"human.paddle": {
		ID: "paddle", Kind: manifest.KindMove, Description: "{the} paddles.", On: []string{"sea"}, Away: "paddle-out",
		Keys: []manifest.PuppetKey{{Hold: 0.3}, {Hold: 0.3}},
	}}
	r := &rigSpec{Sticker: "surfer"}
	var sides []manifest.StickerAnimation
	for _, a := range specs {
		resolved, _, err := r.resolve(a, templates)
		if err != nil {
			t.Fatal(err)
		}
		sides = append(sides, sidecar(r.Sticker, resolved, manifest.UnitBox{Width: 1, Height: 1}))
	}
	if ride := sides[0]; len(ride.On) != 1 || ride.On[0] != "sea" || ride.Faces != "right" {
		t.Errorf("ride-wave: on %v, faces %q", ride.On, ride.Faces)
	}
	if paddle := sides[1]; paddle.Away != "paddle-out" || len(paddle.On) != 1 || paddle.Description != "the surfer paddles." {
		t.Errorf("paddle: away %q, on %v, %q", paddle.Away, paddle.On, paddle.Description)
	}
}
