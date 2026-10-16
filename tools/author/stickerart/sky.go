package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"stickerstories/tools/internal/manifest"
	"stickerstories/tools/internal/stickerimg"
)

// skyScale is the sky mask's size next to its background: half, plenty
// for a soft edge (docs/pack-format.md, "Sky").
const skyScale = 2

// installSky makes the pack's sky masks from its installed backgrounds
// (stickerimg.SkyMask) and points the manifest at them. With preview set,
// it also writes each background with its sky tinted there, to check by
// eye.
func installSky(c *ctxt, preview string) error {
	sky := &manifest.Sky{}
	for _, v := range []struct {
		background, out string
		path            *string
	}{{c.pack.Background, "art/sky.webp", &sky.Image}, {c.pack.BackgroundWide, "art/sky-wide.webp", &sky.ImageWide}} {
		if v.background == "" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(c.packDir, filepath.FromSlash(v.background)))
		if err != nil {
			return fmt.Errorf("sky: %w", err)
		}
		bg, err := stickerimg.Decode(data)
		if err != nil {
			return fmt.Errorf("sky: %s: %w", v.background, err)
		}
		mask := stickerimg.SkyMask(bg, bg.Bounds().Dx()/skyScale)
		encoded, err := stickerimg.EncodeWebP(mask)
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(c.packDir, filepath.FromSlash(v.out)), encoded, 0o644); err != nil {
			return err
		}
		*v.path = v.out
		if preview != "" {
			png, err := stickerimg.Encode(stickerimg.SkyPreview(bg, mask))
			if err != nil {
				return err
			}
			name := c.pack.ID + "-" + filepath.Base(v.out[:len(v.out)-len(".webp")]) + ".png"
			if err := os.WriteFile(filepath.Join(preview, name), png, 0o644); err != nil {
				return err
			}
		}
	}
	c.pack.Sky = sky
	return nil
}

// runSky remakes the sky masks of an installed pack on their own (no
// art.json or rendered art needed).
func runSky(args []string) error {
	fs := flag.NewFlagSet("sky", flag.ExitOnError)
	packDir := fs.String("pack", "", "pack directory")
	preview := fs.String("preview", "", "also write each background with its sky tinted into this directory")
	bump := fs.Bool("bump", false, "increment the pack's content version")
	fs.Parse(args)
	c, err := load(*packDir, "", false)
	if err != nil {
		return err
	}
	if *preview != "" {
		if err := os.MkdirAll(*preview, 0o755); err != nil {
			return err
		}
	}
	if err := installSky(c, *preview); err != nil {
		return err
	}
	if *bump {
		c.pack.Version++
	}
	if errs := c.pack.Validate(c.packDir); len(errs) > 0 {
		for _, e := range errs {
			fmt.Printf("  ✗ %v\n", e)
		}
		return errors.New("manifest would not validate; manifest.json left unchanged (masks were written)")
	}
	data, err := json.MarshalIndent(c.pack, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(c.packDir, "manifest.json"), append(data, '\n'), 0o644); err != nil {
		return err
	}
	fmt.Printf("✓ sky masks for %s (version %d); manifest validates\n", c.pack.ID, c.pack.Version)
	return nil
}
