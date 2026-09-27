// Command packager validates sticker-pack source directories against the
// manifest schema documented in docs/pack-format.md, and builds the
// asset packs a pack's narration is delivered in (docs/asset-delivery.md).
//
// Usage:
//
//	packager validate <pack-dir>
//	packager assetpacks [-out <dir>] [-policy essential|onDemand] [-no-archive] <pack-dir>
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"

	"stickerstories/tools/internal/manifest"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "validate":
		if len(os.Args) != 3 {
			usage()
		}
		validate(os.Args[2])
	case "assetpacks":
		assetPacks(os.Args[2:])
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: packager validate <pack-dir>")
	fmt.Fprintln(os.Stderr, "       packager assetpacks [-out <dir>] [-policy essential|onDemand] [-no-archive] <pack-dir>")
	os.Exit(2)
}

// load reads and validates a pack, exiting on any problem.
func load(dir string) *manifest.Manifest {
	m, err := manifest.Load(dir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "✗ %s: %v\n", dir, err)
		os.Exit(1)
	}
	if errs := m.Validate(dir); len(errs) > 0 {
		fmt.Fprintf(os.Stderr, "✗ pack %q is invalid (%d problem(s)):\n", m.ID, len(errs))
		for _, e := range errs {
			fmt.Fprintf(os.Stderr, "  - %v\n", e)
		}
		os.Exit(1)
	}
	return m
}

func validate(dir string) {
	m := load(dir)
	fallbacks := 0
	for _, s := range m.Stories {
		if s.IsFallback() {
			fallbacks++
		}
	}
	fmt.Printf("✓ pack %q v%d (%s): %d stickers, %d stories (%d fallback(s))\n",
		m.ID, m.Version, m.EffectiveSetting(), len(m.Stickers), len(m.Stories), fallbacks)
}

// assetPackManifest is ba-package's manifest for one asset pack (`xcrun
// ba-package template` prints the full format).
type assetPackManifest struct {
	AssetPackID    string         `json:"assetPackID"`
	DownloadPolicy map[string]any `json:"downloadPolicy"`
	FileSelectors  []fileSelector `json:"fileSelectors"`
	Language       string         `json:"language"`
	Platforms      []string       `json:"platforms"`
	SourceRoot     string         `json:"sourceRoot"`
}

type fileSelector struct {
	FileSource      string `json:"fileSource"`
	FileDestination string `json:"fileDestination"`
}

// assetPacks writes, for each language the pack names a narration pack
// for, that asset pack's manifest and (unless -no-archive) its archive,
// ready for App Store Connect — or for Xcode's Run scheme to serve while
// debugging.
func assetPacks(args []string) {
	fs := flag.NewFlagSet("assetpacks", flag.ExitOnError)
	out := fs.String("out", "", "output directory (default <repo>/build/assetpacks)")
	policy := fs.String("policy", "essential", "download policy: essential (a pack that ships with the app) or onDemand (a pack bought later)")
	noArchive := fs.Bool("no-archive", false, "write the manifests only, without running ba-package")
	fs.Parse(args)
	if fs.NArg() != 1 || (*policy != "essential" && *policy != "onDemand") {
		usage()
	}
	dir, err := filepath.Abs(fs.Arg(0))
	if err != nil {
		fail(err)
	}
	m := load(dir)
	if len(m.NarrationPacks) == 0 {
		fail(fmt.Errorf("pack %q names no narration packs (storyaudio install writes them)", m.ID))
	}
	outDir := *out
	if outDir == "" {
		outDir = filepath.Join(dir, "..", "..", "build", "assetpacks")
	}
	if outDir, err = filepath.Abs(outDir); err != nil {
		fail(err)
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		fail(err)
	}
	// This pack's earlier builds would otherwise be served (or uploaded)
	// next to the current ones.
	stale, _ := filepath.Glob(filepath.Join(outDir, m.ID+"-narration-*"))
	for _, p := range stale {
		if err := os.Remove(p); err != nil {
			fail(err)
		}
	}
	sourceRoot, err := filepath.Rel(outDir, dir)
	if err != nil {
		fail(err)
	}
	downloadPolicy := map[string]any{"onDemand": map[string]any{}}
	if *policy == "essential" {
		// Delivered with the app — the language that best matches the user
		// only — on a first install and on every update.
		downloadPolicy = map[string]any{"essential": map[string]any{
			"installationEventTypes": []string{"firstInstallation", "subsequentUpdate"},
		}}
	}
	languages := make([]string, 0, len(m.NarrationPacks))
	for lang := range m.NarrationPacks {
		languages = append(languages, lang)
	}
	slices.Sort(languages)
	for _, lang := range languages {
		id := m.NarrationPacks[lang]
		pack := assetPackManifest{
			AssetPackID:    id,
			DownloadPolicy: downloadPolicy,
			Language:       m.NarrationLanguage(lang),
			Platforms:      []string{"iOS"},
			SourceRoot:     filepath.ToSlash(sourceRoot),
		}
		for _, rel := range m.NarrationFiles(lang) {
			pack.FileSelectors = append(pack.FileSelectors, fileSelector{FileSource: rel, FileDestination: manifest.NarrationPath(id, rel)})
		}
		data, err := json.MarshalIndent(pack, "", "  ")
		if err != nil {
			fail(err)
		}
		manifestPath := filepath.Join(outDir, id+".json")
		if err := os.WriteFile(manifestPath, append(data, '\n'), 0o644); err != nil {
			fail(err)
		}
		if *noArchive {
			fmt.Printf("✓ %s (%s, %s, %d files): %s\n", id, pack.Language, *policy, len(pack.FileSelectors), manifestPath)
			continue
		}
		archive := filepath.Join(outDir, id+".aar")
		cmd := exec.Command("xcrun", "ba-package", "package", manifestPath, "--output-path", archive, "--quiet")
		cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
		if err := cmd.Run(); err != nil {
			fail(fmt.Errorf("ba-package %s: %w", id, err))
		}
		fmt.Printf("✓ %s (%s, %s, %d files): %s\n", id, pack.Language, *policy, len(pack.FileSelectors), archive)
	}
	fmt.Printf("  Upload the .aar archives to App Store Connect with the build that ships manifest v%d; in Xcode, point the Run scheme's Background Asset Packs folder at %s to serve them while debugging.\n",
		m.Version, strings.TrimSuffix(outDir, "/"))
}

func fail(err error) {
	fmt.Fprintf(os.Stderr, "✗ %v\n", err)
	os.Exit(1)
}
