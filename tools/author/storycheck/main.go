// Command storycheck validates a pack's authored stories
// (tools/author/stories/<packID>/<storyID>/story.json — see FORMAT.md):
// structure, inline effect cues (sticker and canvas) against
// docs/effects/effects.json and the pack's setting, word budgets, forbidden
// words, and sticker coverage and effect usage across the set.
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
	"strings"

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
	pack, err := story.PackManifest(m, *packDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "✗ %v\n", err)
		os.Exit(1)
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
	fmt.Printf("\nCoverage for pack %q (%s): %d stories (%d fallback)\n", m.ID, pack.EffectiveSetting(), cov.Stories, cov.Fallbacks)
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
	printEffectUse(cat, cov)
	printLive(pack, cov)
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

// printEffectUse shows how many stories use each effect, alphabetically,
// so an author can see which effects the set leans on and which it never
// touches; canvas effects are listed last with the share of stories.
func printEffectUse(cat *story.Catalog, cov story.Coverage) {
	names := make([]string, 0, len(cat.Effects))
	for name := range cat.Effects {
		names = append(names, name)
	}
	sort.Strings(names)
	canvas := make([]string, 0, len(cat.Canvas))
	for name := range cat.Canvas {
		canvas = append(canvas, name)
	}
	sort.Strings(canvas)
	fmt.Println("  effects used (stories):")
	var line []string
	for _, name := range names {
		line = append(line, fmt.Sprintf("%s %d", name, cov.EffectUse[name]))
	}
	fmt.Printf("    %s\n", strings.Join(line, ", "))
	line = line[:0]
	for _, name := range canvas {
		line = append(line, fmt.Sprintf("%s %d", name, cov.EffectUse[story.CanvasTarget+":"+name]))
	}
	fmt.Printf("    canvas (%d of %d stories): %s\n", cov.CanvasStories, cov.Stories, strings.Join(line, ", "))
	line = line[:0]
	for _, t := range story.AudioTags {
		if n := cov.TagUse[t.Name]; n > 0 {
			line = append(line, fmt.Sprintf("[%s] %d", t.Name, n))
		}
	}
	if len(line) == 0 {
		line = append(line, "none")
	}
	fmt.Printf("    audio tags (stories): %s\n", strings.Join(line, ", "))
	fmt.Printf("    sound effects: %d of %d stories (%d with a solo sound)\n", cov.SoundStories, cov.Stories, cov.SoloStories)
	fmt.Printf("  learning: %d of %d stories carry a small fact\n", cov.LearningStories, cov.Stories)
}

// printLive lists the stickers that come alive — what each animation
// shows and how long it plays, so an author can put {sticker:live} on the
// words that tell that moment — and how many stories use each.
func printLive(pack story.Manifest, cov story.Coverage) {
	var ids []string
	for _, id := range pack.Stickers {
		if len(pack.Animations[id]) > 0 {
			ids = append(ids, id)
		}
	}
	if len(ids) == 0 {
		return
	}
	fmt.Printf("  live stickers ({sticker:live}; %d of %d stories play one):\n", cov.LiveStories, cov.Stories)
	for _, id := range ids {
		for _, a := range pack.Animations[id] {
			fmt.Printf("    %-10s %-13s %4.1fs  %2d stories  %s\n", id, a.ID, a.Seconds, cov.LiveUse[id], a.Description)
		}
	}
}
