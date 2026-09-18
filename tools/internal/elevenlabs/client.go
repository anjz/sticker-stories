// Package elevenlabs is a minimal client for the ElevenLabs endpoints the
// story audio pipeline needs: speech with character timestamps, sound
// effects, music, and voice-library lookup. Dev-time only; it never ships
// with the app.
package elevenlabs

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const DefaultBaseURL = "https://api.elevenlabs.io"

// Client talks to the ElevenLabs REST API.
type Client struct {
	APIKey  string
	BaseURL string
	HTTP    *http.Client
	// Log, when set, receives one line per request (method, path, status).
	Log func(string)
}

// New returns a client with sensible timeouts.
func New(apiKey string) *Client {
	return &Client{APIKey: apiKey, BaseURL: DefaultBaseURL, HTTP: &http.Client{Timeout: 5 * time.Minute}}
}

// APIError is a non-2xx response.
type APIError struct {
	Status int
	Body   string
}

func (e *APIError) Error() string {
	b := e.Body
	if len(b) > 400 {
		b = b[:400] + "…"
	}
	return fmt.Sprintf("elevenlabs: HTTP %d: %s", e.Status, b)
}

// IsClientError reports whether err is a 4xx that will not succeed on retry.
func IsClientError(err error) bool {
	if e, ok := err.(*APIError); ok {
		return e.Status >= 400 && e.Status < 500 && e.Status != 429
	}
	return false
}

func (c *Client) do(ctx context.Context, method, path string, query url.Values, body any, accept string) ([]byte, error) {
	var payload []byte
	if body != nil {
		var err error
		if payload, err = json.Marshal(body); err != nil {
			return nil, err
		}
	}
	u := strings.TrimRight(c.BaseURL, "/") + path
	if len(query) > 0 {
		u += "?" + query.Encode()
	}
	var last error
	for attempt := 0; attempt < 4; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(time.Duration(attempt*attempt) * 2 * time.Second):
			}
		}
		req, err := http.NewRequestWithContext(ctx, method, u, bytes.NewReader(payload))
		if err != nil {
			return nil, err
		}
		req.Header.Set("xi-api-key", c.APIKey)
		req.Header.Set("Accept", accept)
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		resp, err := c.HTTP.Do(req)
		if err != nil {
			last = err
			continue
		}
		data, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if c.Log != nil {
			c.Log(fmt.Sprintf("%s %s → %d (%d bytes)", method, path, resp.StatusCode, len(data)))
		}
		if err != nil {
			last = err
			continue
		}
		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			return data, nil
		}
		last = &APIError{Status: resp.StatusCode, Body: string(data)}
		if resp.StatusCode == 429 || resp.StatusCode >= 500 {
			continue
		}
		return nil, last
	}
	return nil, last
}

// Alignment is per-character timing for a synthesised text.
type Alignment struct {
	Characters []string  `json:"characters"`
	Starts     []float64 `json:"character_start_times_seconds"`
	Ends       []float64 `json:"character_end_times_seconds"`
}

// VoiceSettings tunes a voice; zero values are omitted (server defaults).
type VoiceSettings struct {
	Stability       *float64 `json:"stability,omitempty"`
	SimilarityBoost *float64 `json:"similarity_boost,omitempty"`
	Style           *float64 `json:"style,omitempty"`
	Speed           *float64 `json:"speed,omitempty"`
	UseSpeakerBoost *bool    `json:"use_speaker_boost,omitempty"`
}

// SpeechRequest is the input to SpeechWithTimestamps.
type SpeechRequest struct {
	VoiceID      string
	Text         string
	ModelID      string // e.g. eleven_v3, eleven_multilingual_v2
	LanguageCode string // ISO 639-1, e.g. "en"
	OutputFormat string // e.g. pcm_44100
	Settings     *VoiceSettings
	Seed         *int
}

// Speech is synthesised audio plus its alignment.
type Speech struct {
	Audio     []byte // raw in the requested output format
	Alignment *Alignment
}

// SpeechWithTimestamps synthesises text and returns character timings.
func (c *Client) SpeechWithTimestamps(ctx context.Context, r SpeechRequest) (*Speech, error) {
	body := map[string]any{"text": r.Text}
	if r.ModelID != "" {
		body["model_id"] = r.ModelID
	}
	if r.LanguageCode != "" {
		body["language_code"] = r.LanguageCode
	}
	if r.Settings != nil {
		body["voice_settings"] = r.Settings
	}
	if r.Seed != nil {
		body["seed"] = *r.Seed
	}
	q := url.Values{}
	if r.OutputFormat != "" {
		q.Set("output_format", r.OutputFormat)
	}
	data, err := c.do(ctx, http.MethodPost, "/v1/text-to-speech/"+url.PathEscape(r.VoiceID)+"/with-timestamps", q, body, "application/json")
	if err != nil {
		return nil, err
	}
	var out struct {
		AudioBase64         string     `json:"audio_base64"`
		Alignment           *Alignment `json:"alignment"`
		NormalizedAlignment *Alignment `json:"normalized_alignment"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, fmt.Errorf("decoding speech response: %w", err)
	}
	audio, err := base64.StdEncoding.DecodeString(out.AudioBase64)
	if err != nil {
		return nil, fmt.Errorf("decoding audio: %w", err)
	}
	al := out.Alignment
	if al == nil {
		al = out.NormalizedAlignment
	}
	return &Speech{Audio: audio, Alignment: al}, nil
}

// SoundEffect generates a short sound from a text prompt.
func (c *Client) SoundEffect(ctx context.Context, prompt string, seconds float64, influence float64, outputFormat string) ([]byte, error) {
	body := map[string]any{"text": prompt}
	if seconds > 0 {
		body["duration_seconds"] = seconds
	}
	if influence > 0 {
		body["prompt_influence"] = influence
	}
	q := url.Values{}
	if outputFormat != "" {
		q.Set("output_format", outputFormat)
	}
	return c.do(ctx, http.MethodPost, "/v1/sound-generation", q, body, "audio/*")
}

// Music composes an instrumental track from a prompt.
func (c *Client) Music(ctx context.Context, prompt string, lengthMS int, modelID string, outputFormat string) ([]byte, error) {
	body := map[string]any{"prompt": prompt, "force_instrumental": true}
	if lengthMS > 0 {
		body["music_length_ms"] = lengthMS
	}
	if modelID != "" {
		body["model_id"] = modelID
	}
	q := url.Values{}
	if outputFormat != "" {
		q.Set("output_format", outputFormat)
	}
	return c.do(ctx, http.MethodPost, "/v1/music", q, body, "audio/*")
}

// SharedVoice is one entry of the public voice library.
type SharedVoice struct {
	VoiceID          string `json:"voice_id"`
	PublicOwnerID    string `json:"public_owner_id"`
	Name             string `json:"name"`
	Language         string `json:"language"`
	Locale           string `json:"locale"`
	Accent           string `json:"accent"`
	Gender           string `json:"gender"`
	Age              string `json:"age"`
	UseCase          string `json:"use_case"`
	Category         string `json:"category"`
	ClonedByCount    int    `json:"cloned_by_count"`
	UsageChars1Y     int64  `json:"usage_character_count_1y"`
	FreeUsersAllowed bool   `json:"free_users_allowed"`
}

// SharedVoicesQuery filters the public voice library.
type SharedVoicesQuery struct {
	Language string // ISO 639-1
	Locale   string // e.g. en-US
	UseCases []string
	Sort     string // created_date | usage_character_count_1y | trending | cloned_by_count
	PageSize int
}

// SharedVoices lists public library voices.
func (c *Client) SharedVoices(ctx context.Context, sq SharedVoicesQuery) ([]SharedVoice, error) {
	q := url.Values{}
	if sq.Language != "" {
		q.Set("language", sq.Language)
	}
	if sq.Locale != "" {
		q.Set("locale", sq.Locale)
	}
	for _, u := range sq.UseCases {
		q.Add("use_cases", u)
	}
	if sq.Sort != "" {
		q.Set("sort", sq.Sort)
	}
	if sq.PageSize > 0 {
		q.Set("page_size", fmt.Sprint(sq.PageSize))
	}
	data, err := c.do(ctx, http.MethodGet, "/v1/shared-voices", q, nil, "application/json")
	if err != nil {
		return nil, err
	}
	var out struct {
		Voices []SharedVoice `json:"voices"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, fmt.Errorf("decoding shared voices: %w", err)
	}
	return out.Voices, nil
}

// AddSharedVoice copies a public library voice into the account so it can
// be used for synthesis. Returns the voice ID to synthesise with.
func (c *Client) AddSharedVoice(ctx context.Context, publicOwnerID, voiceID, name string) (string, error) {
	data, err := c.do(ctx, http.MethodPost, "/v1/voices/add/"+url.PathEscape(publicOwnerID)+"/"+url.PathEscape(voiceID), nil, map[string]any{"new_name": name}, "application/json")
	if err != nil {
		return "", err
	}
	var out struct {
		VoiceID string `json:"voice_id"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return "", err
	}
	if out.VoiceID == "" {
		out.VoiceID = voiceID
	}
	return out.VoiceID, nil
}

// Voice is one voice in the account's own library.
type Voice struct {
	VoiceID  string            `json:"voice_id"`
	Name     string            `json:"name"`
	Category string            `json:"category"`
	Labels   map[string]string `json:"labels"`
}

// Voices lists the account's voices.
func (c *Client) Voices(ctx context.Context) ([]Voice, error) {
	data, err := c.do(ctx, http.MethodGet, "/v1/voices", nil, nil, "application/json")
	if err != nil {
		return nil, err
	}
	var out struct {
		Voices []Voice `json:"voices"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, err
	}
	return out.Voices, nil
}
