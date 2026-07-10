// Command packager validates sticker-pack source directories against the
// manifest schema documented in docs/pack-format.md.
//
// Usage:
//
//	packager validate <pack-dir>
//
// v0 only validates. Assembling distributable bundles will be added when
// packs are delivered outside the app bundle.
package main

import (
	"fmt"
	"os"

	"stickerstories/tools/internal/manifest"
)

func main() {
	if len(os.Args) != 3 || os.Args[1] != "validate" {
		fmt.Fprintln(os.Stderr, "usage: packager validate <pack-dir>")
		os.Exit(2)
	}
	dir := os.Args[2]

	m, err := manifest.Load(dir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "✗ %s: %v\n", dir, err)
		os.Exit(1)
	}

	errs := m.Validate(dir)
	if len(errs) > 0 {
		fmt.Fprintf(os.Stderr, "✗ pack %q is invalid (%d problem(s)):\n", m.ID, len(errs))
		for _, e := range errs {
			fmt.Fprintf(os.Stderr, "  - %v\n", e)
		}
		os.Exit(1)
	}

	fallbacks := 0
	for _, s := range m.Stories {
		if s.IsFallback() {
			fallbacks++
		}
	}
	fmt.Printf("✓ pack %q v%d: %d stickers, %d stories (%d fallback(s))\n",
		m.ID, m.Version, len(m.Stickers), len(m.Stories), fallbacks)
}
