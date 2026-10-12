package main

import (
	"os"
	"strings"
	"testing"

	"stickerstories/tools/internal/manifest"
)

func TestForestSpaceIsValid(t *testing.T) {
	s, err := LoadSpace("../art/forest/space.json")
	if err != nil {
		t.Fatal(err)
	}
	m, err := manifest.Load("../../../packs/forest")
	if err != nil {
		t.Fatal(err)
	}
	stickers, features := map[string]bool{}, map[string]bool{}
	for _, st := range m.Stickers {
		stickers[st.ID] = true
	}
	for id := range m.Features {
		features[id] = true
	}
	if errs := s.Validate(stickers, features); len(errs) != 0 {
		t.Errorf("%v", errs)
	}
}

func TestSaveKeepsPointsOnOneLine(t *testing.T) {
	s, err := LoadSpace("../art/forest/space.json")
	if err != nil {
		t.Fatal(err)
	}
	s.Lineup = []LineupSticker{{Sticker: "fox", At: [2]float64{0.4, 0.25}}}
	path := t.TempDir() + "/space.json"
	if err := s.Save(path); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(path)
	if !strings.Contains(string(data), `"at": [0.4, 0.25]`) || !strings.Contains(string(data), `"horizon"`) {
		t.Errorf("points not compact or the space not flattened:\n%s", data)
	}
	again, err := LoadSpace(path)
	if err != nil {
		t.Fatal(err)
	}
	if again.Horizon != s.Horizon || len(again.Layers) != len(s.Layers) || again.Lineup[0] != s.Lineup[0] {
		t.Errorf("round trip changed the space")
	}
	pack, err := manifest.LoadSpace(path)
	if err != nil || pack.Horizon != s.Horizon || len(pack.Sizes) != len(s.Sizes) {
		t.Errorf("the pack's reading of it: %v", err)
	}
}
