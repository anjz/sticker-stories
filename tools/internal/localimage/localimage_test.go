package localimage

import (
	"os"
	"path/filepath"
	"testing"
)

func TestModelIDFollowsWhatChangesThePictures(t *testing.T) {
	dir := t.TempDir()
	id := func(cfg string) string {
		p := filepath.Join(dir, "config.json")
		if err := os.WriteFile(p, []byte(cfg), 0o644); err != nil {
			t.Fatal(err)
		}
		c, err := Load(p)
		if err != nil {
			t.Fatal(err)
		}
		return c.ModelID("high")
	}
	base := id(`{"model": {"name": "flux2-klein-4b", "path": "/a"}, "qualities": {"high": {"steps": 4}, "low": {"steps": 2}}}`)
	if got := id(`{"listen": "127.0.0.1:9999", "model": {"name": "flux2-klein-4b", "path": "/b"}, "qualities": {"high": {"steps": 4}, "low": {"steps": 2}}}`); got != base {
		t.Errorf("where the weights live or the port changed the ID: %s vs %s", got, base)
	}
	if got := id(`{"model": {"name": "flux2-klein-4b", "path": "/a"}, "qualities": {"high": {"steps": 4}, "low": {"steps": 3}}}`); got != base {
		t.Errorf("another quality's profile changed the ID: %s vs %s", got, base)
	}
	if got := id(`{"model": {"name": "flux2-klein-4b", "path": "/a"}, "qualities": {"high": {"steps": 6}, "low": {"steps": 2}}}`); got == base {
		t.Error("the quality's steps did not change the ID")
	}
	if got := id(`{"model": {"name": "flux2-klein-4b", "path": "/a", "quantize": 8}, "qualities": {"high": {"steps": 4}, "low": {"steps": 2}}}`); got == base {
		t.Error("quantizing did not change the ID")
	}
}
