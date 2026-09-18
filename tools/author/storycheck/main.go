// Command storycheck validates a pack's authored stories
// (tools/author/stories/<packID>/<storyID>/story.json — see FORMAT.md):
// structure, inline effect cues against docs/effects/effects.json, word
// budgets, forbidden words, and sticker coverage across the set.
//
// Usage:
//
//	storycheck -pack <pack-dir> [-stories <dir>] [-effects <effects.json>] [-count 50] [-plan]
//
// Exit status is 1 when any error is found. Warnings never fail the run.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"stickerstories/tools/internal/manifest"
	"stickerstories/tools/internal/story"
)

func main() {
	packDir := flag.String("pack", "", "pack directory containing manifest.json (required)")
	storiesDir := flag.String("stories", "", "stories directory (default author/stories/<packID>)")
	effectsPath := flag.String("effects", "../docs/effects/effects.json", "effects catalogue")
	count := flag.Int("count", story.DefaultCount, "expected number of stories in the set (0 = don't check)")
	planOnly := flag.Bool("plan", false, "only report coverage of what exists (roster check); no per-story output")
	flag.Parse()
	if *packDir == "" {
		fmt.Fprintln(os.Stderr, "usage: storycheck -pack <pack-dir> [-stories <dir>] [-effects <effects.json>] [-count N] [-plan]")
		os.Exit(2)
	}

	m, err := manifest.Load(*packDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "✗ %v\n", err)
		os.Exit(1)
	}
	pack := story.Manifest{ID: m.ID, Languages: m.Languages}
	for _, st := range m.Stickers {
		pack.Stickers = append(pack.Stickers, st.ID)
	}
	cat, err := story.LoadCatalog(*effectsPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "✗ %v\n", err)
		os.Exit(1)
	}
	dir := *storiesDir
	if dir == "" {
		dir = filepath.Join("author", "stories", m.ID)
	}
	stories, loadErrs := story.LoadDir(dir)
	failed := false
	for _, e := range loadErrs {
		fmt.Printf("✗ %v\n", e)
		failed = true
	}

	if !*planOnly {
		for _, s := range stories {
			is := story.Validate(s, pack, cat)
			if len(is.Errors) == 0 && len(is.Warnings) == 0 {
				fmt.Printf("✓ %s\n", s.ID)
				continue
			}
			mark := "!"
			if len(is.Errors) > 0 {
				mark = "✗"
				failed = true
			}
			fmt.Printf("%s %s\n", mark, s.ID)
			for _, e := range is.Errors {
				fmt.Printf("    error: %s\n", e)
			}
			for _, w := range is.Warnings {
				fmt.Printf("    warn:  %s\n", w)
			}
		}
	}

	cov := story.Cover(stories, pack, *count)
	fmt.Printf("\nCoverage for pack %q: %d stories (%d fallback)\n", m.ID, cov.Stories, cov.Fallbacks)
	ids := append([]string(nil), pack.Stickers...)
	sort.Slice(ids, func(i, j int) bool {
		if cov.Featured[ids[i]] != cov.Featured[ids[j]] {
			return cov.Featured[ids[i]] < cov.Featured[ids[j]]
		}
		return ids[i] < ids[j]
	})
	width := 0
	for _, id := range ids {
		if len(id) > width {
			width = len(id)
		}
	}
	fmt.Printf("  %-*s  featured  used\n", width, "sticker")
	for _, id := range ids {
		fmt.Printf("  %-*s  %8d  %4d\n", width, id, cov.Featured[id], cov.Used[id])
	}
	for _, e := range cov.Errors {
		fmt.Printf("  error: %s\n", e)
		failed = true
	}
	for _, w := range cov.Warnings {
		fmt.Printf("  warn:  %s\n", w)
	}
	if failed {
		fmt.Println("\n✗ fix the errors above")
		os.Exit(1)
	}
	if len(cov.Warnings) == 0 {
		fmt.Println("\n✓ no errors")
	} else {
		fmt.Println("\n✓ no errors (see warnings above)")
	}
}
