package manifest

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Narration is delivered per language as Apple-hosted Background Assets
// asset packs, not inside the app (docs/asset-delivery.md). A pack's
// manifest names, per language, the asset pack that carries that
// language's narration (`narrationPacks`); the app, its art and every
// language's effect sidecars stay in the pack itself.

// narrationPackPattern is what an asset pack ID may look like.
var narrationPackPattern = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// NarrationLanguage is the language an asset pack carrying lang's
// narration is tagged with: its primary subtag ("en"), so any English
// the user prefers matches it — unless another of the pack's languages
// shares that subtag, when the whole tag tells them apart ("en-GB").
func (m *Manifest) NarrationLanguage(lang string) string {
	primary := strings.ToLower(strings.SplitN(lang, "-", 2)[0])
	for _, other := range m.Languages {
		if other != lang && strings.ToLower(strings.SplitN(other, "-", 2)[0]) == primary {
			return lang
		}
	}
	return primary
}

// NarrationFiles lists lang's narration audio files, pack-relative and
// sorted: what its asset pack carries.
func (m *Manifest) NarrationFiles(lang string) []string {
	var files []string
	for _, s := range m.Stories {
		if loc, ok := s.Localizations[lang]; ok && loc.Audio != "" {
			files = append(files, loc.Audio)
		}
	}
	sort.Strings(files)
	return files
}

// NarrationPackID is the ID of the asset pack that carries lang's
// narration: "<pack>-narration-<language>-<hash>", the hash taken over
// the narration files' paths and contents. A new recording is a new
// asset pack, so an app version only ever reads the narration its own
// manifest — and its effect sidecars, timed to that recording — name.
func (m *Manifest) NarrationPackID(dir, lang string) (string, error) {
	files := m.NarrationFiles(lang)
	if len(files) == 0 {
		return "", fmt.Errorf("no %s narration in the pack", lang)
	}
	h := sha256.New()
	for _, rel := range files {
		data, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(rel)))
		if err != nil {
			return "", err
		}
		h.Write([]byte(rel))
		h.Write([]byte{0})
		h.Write(data)
		h.Write([]byte{0})
	}
	return fmt.Sprintf("%s-narration-%s-%s", m.ID, strings.ToLower(m.NarrationLanguage(lang)), hex.EncodeToString(h.Sum(nil))[:8]), nil
}

// NarrationPath is where a narration file sits inside its asset pack: under
// the asset pack's ID, so two recordings of a language on the device at
// once (the old one not yet removed after an update) never share a path.
func NarrationPath(assetPackID, rel string) string {
	return path.Join(assetPackID, rel)
}
