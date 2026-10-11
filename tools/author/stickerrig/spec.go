package main

import (
	"fmt"
	"slices"

	"stickerstories/tools/internal/manifest"
)

// rigFile is rig.json: one puppet per sticker.
type rigFile struct {
	Rigs []rigSpec `json:"rigs"`
}

// rigSpec is how one sticker's puppet is made and moves.
type rigSpec struct {
	Sticker string `json:"sticker"`
	// Sheets are drawn in order, each from the sticker's raw art and the
	// sheets it lists as references (the face pieces see the parts).
	Sheets []sheetSpec `json:"sheets"`
	// Parts name pieces of the drawn sheets: the piece at (or nearest to)
	// At, a point of the sheet (stickerrig parts lists them).
	Parts map[string]partSpec `json:"parts,omitempty"`
	// Bones, Slots and Faces are the rig's (manifest.PuppetRig), with
	// every coordinate in the sticker image's pixels at stickerSize.
	Bones []manifest.PuppetBone        `json:"bones,omitempty"`
	Slots []slotSpec                   `json:"slots,omitempty"`
	Faces map[string]map[string]string `json:"faces,omitempty"`
	Idle  *manifest.PuppetIdle         `json:"idle,omitempty"`
	// Animations are the puppet's versions of the sticker's animations
	// (same ids as anim.json's): install puts each into that sidecar.
	Animations []animSpec `json:"animations,omitempty"`
}

type sheetSpec struct {
	ID         string   `json:"id"`
	Size       string   `json:"size"`
	Prompt     string   `json:"prompt"`
	References []string `json:"references,omitempty"`
}

// slotSpec is a slot as rig.json gives it: each attachment by its
// centre at rest and its scale from the piece (install works out the box).
type slotSpec struct {
	ID          string                `json:"id"`
	Bone        string                `json:"bone"`
	Default     string                `json:"default"`
	Attachments map[string]attachSpec `json:"attachments"`
}

type attachSpec struct {
	Part   string  `json:"part"`
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Scale  float64 `json:"scale"`
	Rotate float64 `json:"rotate,omitempty"`
	Flip   bool    `json:"flip,omitempty"`
	Shade  float64 `json:"shade,omitempty"`
}

type partSpec struct {
	Sheet string `json:"sheet"`
	At    [2]int `json:"at"`
}

type animSpec struct {
	ID string `json:"id"`
	manifest.AnimationPuppet
}

func (r *rigSpec) check(c *ctxt) error {
	if c.sticker(r.Sticker) == nil {
		return fmt.Errorf("sticker %q is not in the manifest", r.Sticker)
	}
	var sheets []string
	for _, sh := range r.Sheets {
		if sh.ID == "" || sh.Size == "" || sh.Prompt == "" {
			return fmt.Errorf("every sheet needs an id, a size and a prompt")
		}
		for _, ref := range sh.References {
			if !slices.Contains(sheets, ref) {
				return fmt.Errorf("sheet %s: reference %q must be a sheet drawn before it", sh.ID, ref)
			}
		}
		sheets = append(sheets, sh.ID)
	}
	for name, p := range r.Parts {
		if !slices.Contains(sheets, p.Sheet) {
			return fmt.Errorf("part %s: sheet %q is not one of the rig's", name, p.Sheet)
		}
	}
	return nil
}
