package dotenv

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoad(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, ".env")
	os.WriteFile(p, []byte("# comment\nexport A=1\nB=\"two words\"\nC='x' \nD=raw # trailing\nPRESET=new\n"), 0o644)
	t.Setenv("PRESET", "old")
	for _, k := range []string{"A", "B", "C", "D"} {
		os.Unsetenv(k)
	}
	if err := Load(p); err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"A": "1", "B": "two words", "C": "x", "D": "raw", "PRESET": "old"}
	for k, v := range want {
		if got := os.Getenv(k); got != v {
			t.Errorf("%s = %q, want %q", k, got, v)
		}
	}
	if err := Load(filepath.Join(dir, "missing")); err != nil {
		t.Errorf("missing file should not error: %v", err)
	}
}
