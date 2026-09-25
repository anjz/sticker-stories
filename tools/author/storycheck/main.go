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
	printFaces(pack)
	printStages(pack)
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
	line = line[:0]
	faces := make([]string, 0, len(cov.FaceUse))
	for name := range cov.FaceUse {
		faces = append(faces, name)
	}
	sort.Strings(faces)
	for _, name := range faces {
		line = append(line, fmt.Sprintf("%s %d", name, cov.FaceUse[name]))
	}
	if len(line) == 0 {
		line = append(line, "none")
	}
	fmt.Printf("  faces: %d of %d stories change one (%s); %d cue every sticker with {%s:…}\n", cov.FaceStories, cov.Stories, strings.Join(line, ", "), cov.AllStories, story.AllTarget)
}

// printLive lists the stickers that come alive — what each animation
// shows and how long it plays, and where one can pause ({sticker:live
// hold} … {sticker:live resume}), so an author can put the cues on the
// words that tell those moments — and how many stories use each.
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
	fmt.Printf("  moves: %d of %d stories move a sticker ({sticker:go …})\n", cov.GoStories, cov.Stories)
	fmt.Printf("  live stickers ({sticker:live}; %d of %d stories play one):\n", cov.LiveStories, cov.Stories)
	for _, id := range ids {
		for _, a := range pack.Animations[id] {
			fmt.Printf("    %-10s %-13s %4.1fs  %2d stories  %s\n", id, a.ID, a.Seconds, cov.LiveUse[id], a.Description)
			if a.Pause != "" {
				fmt.Printf("    %-10s %-13s %4.1fs + %.1fs   hold: %s\n", "", "", a.ToPause, a.FromPause, a.Pause)
			}
			if a.Perched {
				fmt.Printf("    %-10s %-13s perched: land it first (go on/under a sticker, go to the ground or a tree), never in the air\n", "", "")
			}
		}
	}
}

// printFaces lists the expressions stickers can show ({sticker:face …}),
// grouped by the set so a pack where everyone has the same faces takes one
// line.
func printFaces(pack story.Manifest) {
	groups := map[string][]string{}
	for _, id := range pack.Stickers {
		if list := pack.Expressions[id]; len(list) > 0 {
			key := strings.Join(list, ", ")
			groups[key] = append(groups[key], id)
		}
	}
	if len(groups) == 0 {
		return
	}
	keys := make([]string, 0, len(groups))
	for k := range groups {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	fmt.Println("  faces ({sticker:face …}, {all:face …}; normal is always there):")
	for _, k := range keys {
		who := strings.Join(groups[k], ", ")
		if len(groups[k]) == len(pack.Stickers) {
			who = "every sticker"
		}
		fmt.Printf("    %s: %s\n", who, k)
	}
}

// printStages lists how each sticker comes into the scene when a story
// names it ({sticker:enter}) and the child has not placed it, grouped by
// entrance.
func printStages(pack story.Manifest) {
	groups := map[string][]string{}
	for _, id := range pack.Stickers {
		entrance := pack.Stages[id]
		if entrance == "" {
			entrance = "no stage (grows in the default area)"
		}
		groups[entrance] = append(groups[entrance], id)
	}
	fmt.Println("  entrances ({sticker:enter} on the first mention; used when the child has not placed it):")
	for _, k := range []string{"hop", "fly", "grow", "no stage (grows in the default area)"} {
		if len(groups[k]) > 0 {
			fmt.Printf("    %s: %s\n", k, strings.Join(groups[k], ", "))
		}
	}
	movers := append(append([]string{}, groups["hop"]...), groups["fly"]...)
	fmt.Printf("  moves ({sticker:go to X}, go on X, go under X, go to <place>, go away, go back): %s can move; %s stay put\n",
		strings.Join(movers, ", "), strings.Join(groups["grow"], ", "))
	// Stickers with more than one way to go: the first is the usual one,
	// the others need naming ({ladybug:go on flower by fly}, {ladybug:enter by fly}).
	var ways []string
	for _, id := range pack.Stickers {
		moves := pack.Moves[id]
		if len(moves) < 2 {
			continue
		}
		others := make([]string, 0, len(moves)-1)
		for _, m := range moves[1:] {
			others = append(others, "by "+m.ID)
		}
		ways = append(ways, fmt.Sprintf("%s %s (or %s)", id, moves[0].ID, strings.Join(others, ", ")))
	}
	if len(ways) > 0 {
		fmt.Printf("  ways to go (name another than the usual on go and enter cues, as the words say): %s\n", strings.Join(ways, "; "))
	}
	if len(pack.Features) == 0 {
		return
	}
	// Where they land: each feature with the stickers that go there first
	// (then, in brackets, those that go there when their first choice is
	// taken or off screen) — so the words can put them there too.
	ids := make([]string, 0, len(pack.Features))
	for id := range pack.Features {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	fmt.Println("  where they land (manifest features; write them there):")
	for _, id := range ids {
		var first, then []string
		for _, st := range pack.Stickers {
			for i, f := range pack.LandsOn[st] {
				if f == id && i == 0 {
					first = append(first, st)
				} else if f == id {
					then = append(then, st)
				}
			}
		}
		line := strings.Join(first, ", ")
		if len(then) > 0 {
			line += " (else " + strings.Join(then, ", ") + ")"
		}
		fmt.Printf("    %-9s %s — %s\n", id, pack.Features[id], line)
	}
}
