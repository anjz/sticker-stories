// Package localimage runs the art tools' image generation on this computer
// instead of the OpenAI Images API: a local server (author/localimage/
// server.py, a diffusion model on MLX) that speaks the same API, started on
// demand and left running until it has been idle a while. The tools' -local
// flag swaps their client for one that talks to it. Dev-time only.
package localimage

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"stickerstories/tools/internal/openai"
)

// DefaultConfig is where the tools look for the config, relative to tools/.
const DefaultConfig = "author/localimage/config.json"

// adaptVersion changes whenever the server changes how it turns a request
// into a picture (prompt wording, the matte, inpainting), so fingerprints
// redraw what an older server drew.
const adaptVersion = "1"

// Config is the part of config.json the tools read; the server reads the
// rest.
type Config struct {
	Listen string `json:"listen"`
	Model  struct {
		Name string `json:"name"`
		Path string `json:"path"`
	} `json:"model"`
	path string
	raw  map[string]json.RawMessage
}

// Load reads the config.
func Load(path string) (*Config, error) {
	if path == "" {
		path = DefaultConfig
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("local image config: %w", err)
	}
	c := &Config{}
	if err := json.Unmarshal(data, c); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if err := json.Unmarshal(data, &c.raw); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if c.Listen == "" {
		c.Listen = "127.0.0.1:7865"
	}
	if c.Model.Name == "" {
		return nil, fmt.Errorf("%s: model.name is required", path)
	}
	if c.path, err = filepath.Abs(path); err != nil {
		return nil, err
	}
	return c, nil
}

// ModelID names what draws at this quality, for the tools' fingerprints in
// place of the OpenAI model name: the model and every setting that changes
// its pictures (the quality's profile, the matte, inpainting, the model's
// own options) — not where the weights live or the server's port.
func (c *Config) ModelID(quality string) string {
	var model map[string]json.RawMessage
	json.Unmarshal(c.raw["model"], &model)
	delete(model, "path")
	var qualities map[string]json.RawMessage
	json.Unmarshal(c.raw["qualities"], &qualities)
	// The last entry was whether sprite sheets were drawn a frame at a
	// time (always, by default); it stays so the IDs, and with them the
	// fingerprints of art drawn locally, do not change.
	parts, _ := json.Marshal([]any{adaptVersion, model, qualities[quality], c.raw["references"], c.raw["matte"], c.raw["inpaint"], true})
	h := sha256.Sum256(parts)
	return "local:" + c.Model.Name + ":" + hex.EncodeToString(h[:])[:10]
}

func (c *Config) url() string { return "http://" + c.Listen }

func (c *Config) healthy(ctx context.Context) bool {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, c.url()+"/health", nil)
	resp, err := (&http.Client{Timeout: 2 * time.Second}).Do(req)
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

// LogPath is where a server the tools start writes its log.
func LogPath() string { return filepath.Join(os.TempDir(), "stickerstories-localimage.log") }

// Client returns an Images API client for the local server, starting the
// server first (uv run server.py, detached, so it outlives this run and
// the next run finds the model loaded) when nothing answers at the
// config's address.
func (c *Config) Client(ctx context.Context, say func(string)) (*openai.Client, error) {
	if !c.healthy(ctx) {
		if err := c.start(ctx, say); err != nil {
			return nil, err
		}
	}
	oc := openai.New("local")
	oc.BaseURL = c.url() + "/v1"
	oc.SendHints = true
	// Requests queue on one GPU: a run with -parallel waits its turn.
	oc.HTTP.Timeout = 2 * time.Hour
	return oc, nil
}

func (c *Config) start(ctx context.Context, say func(string)) error {
	uv, err := exec.LookPath("uv")
	if err != nil {
		return errors.New("the local server needs uv (brew install uv)")
	}
	script := filepath.Join(filepath.Dir(c.path), "server.py")
	if _, err := os.Stat(script); err != nil {
		return fmt.Errorf("local server: %w", err)
	}
	logf, err := os.OpenFile(LogPath(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer logf.Close()
	cmd := exec.Command(uv, "run", "-q", "--script", script, "--config", c.path)
	cmd.Stdout, cmd.Stderr = logf, logf
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("starting the local server: %w", err)
	}
	say(fmt.Sprintf("starting the local image server (%s; log %s)…", c.Model.Name, LogPath()))
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	deadline := time.After(15 * time.Minute) // the first run installs its Python packages
	for {
		select {
		case err := <-exited:
			return fmt.Errorf("the local server exited (%v); see %s", err, LogPath())
		case <-deadline:
			return fmt.Errorf("the local server did not come up; see %s", LogPath())
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
			if c.healthy(ctx) {
				return nil
			}
		}
	}
}
