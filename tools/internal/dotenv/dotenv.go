// Package dotenv loads KEY=VALUE pairs from a .env file into the process
// environment without overriding variables that are already set. It is
// deliberately tiny: comments (#), blank lines, optional "export ", and
// single or double quotes around the value.
package dotenv

import (
	"bufio"
	"os"
	"strings"
)

// Load reads path and sets each variable that is not already set. A missing
// file is not an error (the environment may carry the values instead).
func Load(path string) error {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		val = strings.TrimSpace(val)
		if len(val) >= 2 && (val[0] == '"' || val[0] == '\'') && val[len(val)-1] == val[0] {
			val = val[1 : len(val)-1]
		} else if i := strings.Index(val, " #"); i >= 0 {
			val = strings.TrimSpace(val[:i])
		}
		if key == "" || os.Getenv(key) != "" {
			continue
		}
		os.Setenv(key, val)
	}
	return sc.Err()
}

// LoadFirst loads the first path that exists.
func LoadFirst(paths ...string) error {
	for _, p := range paths {
		if _, err := os.Stat(p); err == nil {
			return Load(p)
		}
	}
	return nil
}
