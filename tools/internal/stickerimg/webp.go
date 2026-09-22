package stickerimg

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"image"
	"image/draw"
	"os"
	"path/filepath"
	"strconv"

	"github.com/gen2brain/webp"
)

// WebPQuality is the lossy quality every pack image is encoded at. At 90
// the colour error on painted art is below what the eye picks up (mean
// ≈ 2/255) while files come out ~85 % smaller than PNG; the alpha channel
// is always stored losslessly, so a die-cut edge stays pixel-exact.
const WebPQuality = 90

// EncodeWebP writes an image as lossy WebP with lossless alpha
// (docs/pack-format.md, "Image formats"). Colour is handed over
// straight (non-premultiplied), as the format stores it.
func EncodeWebP(img image.Image) ([]byte, error) {
	straight := image.NewNRGBA(img.Bounds())
	draw.Draw(straight, straight.Bounds(), img, img.Bounds().Min, draw.Src)
	var buf bytes.Buffer
	if err := webp.Encode(&buf, straight, webp.Options{Quality: WebPQuality, Method: 6}); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// isWebP reports whether data starts with a RIFF/WEBP header.
func isWebP(data []byte) bool {
	return len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP"
}

// installVersion changes whenever InstallWebP's output would change for
// the same source (encoder settings), so cached pack files are redone.
const installVersion = "1"

// InstallWebP encodes the lossless image at src (PNG or WebP) into the
// pack's WebP at dst, unless cache says dst was already made from this
// very source: cache is keyed by dst and holds a fingerprint of the
// source bytes and the encoder, and the caller persists it. Returns
// whether an encode happened.
func InstallWebP(src, dst string, cache map[string]string) (bool, error) {
	data, err := os.ReadFile(src)
	if err != nil {
		return false, err
	}
	sum := sha256.Sum256(data)
	fp := hex.EncodeToString(sum[:8]) + "-q" + strconv.Itoa(WebPQuality) + "-v" + installVersion
	if cache[dst] == fp {
		if _, err := os.Stat(dst); err == nil {
			return false, nil
		}
	}
	img, err := Decode(data)
	if err != nil {
		return false, fmt.Errorf("%s: %w", src, err)
	}
	encoded, err := EncodeWebP(img)
	if err != nil {
		return false, err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return false, err
	}
	if err := os.WriteFile(dst, encoded, 0o644); err != nil {
		return false, err
	}
	cache[dst] = fp
	return true, nil
}
