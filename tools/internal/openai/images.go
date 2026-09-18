// Package openai is a minimal client for the OpenAI Images API (generations
// and edits) used by the sticker art pipeline. Dev-time only.
package openai

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"strings"
	"time"
)

const DefaultBaseURL = "https://api.openai.com/v1"

// Client talks to the OpenAI REST API.
type Client struct {
	APIKey  string
	BaseURL string
	HTTP    *http.Client
	Log     func(string)
}

// New returns a client with a generous timeout (large images take a while).
func New(apiKey string) *Client {
	return &Client{APIKey: apiKey, BaseURL: DefaultBaseURL, HTTP: &http.Client{Timeout: 10 * time.Minute}}
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
	return fmt.Sprintf("openai: HTTP %d: %s", e.Status, b)
}

// IsClientError reports whether err is a 4xx that will not succeed on retry.
func IsClientError(err error) bool {
	if e, ok := err.(*APIError); ok {
		return e.Status >= 400 && e.Status < 500 && e.Status != 429
	}
	return false
}

// ImageRequest describes one image to produce.
type ImageRequest struct {
	Model      string // e.g. gpt-image-2.5-flare (generate) / gpt-image-2.5-sunburst (edit)
	Prompt     string
	Size       string // "1024x1024", "2048x1536", …
	Quality    string // low | medium | high | xhigh | max | auto
	Background string // transparent | opaque | auto
	// Edits only:
	References [][]byte // PNG reference/input images, first is the primary
	Mask       []byte   // PNG with alpha; transparent areas are painted
	Fidelity   string   // input_fidelity: high | low
}

// Usage is the token accounting the API returns.
type Usage struct {
	InputTokens  int `json:"input_tokens"`
	OutputTokens int `json:"output_tokens"`
	TotalTokens  int `json:"total_tokens"`
	InputDetails struct {
		ImageTokens int `json:"image_tokens"`
		TextTokens  int `json:"text_tokens"`
	} `json:"input_tokens_details"`
}

// Prices are USD per 1M tokens for the gpt-image-2.5 models (pricing page,
// September 2026); update when the price list changes.
type Prices struct{ TextIn, ImageIn, Out float64 }

// DefaultPrices is the standard (non-batch) tier.
var DefaultPrices = Prices{TextIn: 5, ImageIn: 8, Out: 30}

// Cost estimates the USD cost of a call. When the input split is not
// reported, all input is priced as image tokens (the higher rate).
func (u Usage) Cost(p Prices) float64 {
	img, txt := u.InputDetails.ImageTokens, u.InputDetails.TextTokens
	if img+txt == 0 {
		img = u.InputTokens
	}
	return (float64(txt)*p.TextIn + float64(img)*p.ImageIn + float64(u.OutputTokens)*p.Out) / 1e6
}

// Add sums usage.
func (u *Usage) Add(o Usage) {
	u.InputTokens += o.InputTokens
	u.OutputTokens += o.OutputTokens
	u.TotalTokens += o.TotalTokens
	u.InputDetails.ImageTokens += o.InputDetails.ImageTokens
	u.InputDetails.TextTokens += o.InputDetails.TextTokens
}

// Image is one produced image.
type Image struct {
	PNG   []byte
	Usage Usage
}

// Generate calls /images/generations.
func (c *Client) Generate(ctx context.Context, r ImageRequest) (*Image, error) {
	body := map[string]any{"model": r.Model, "prompt": r.Prompt, "n": 1, "output_format": "png"}
	if r.Size != "" {
		body["size"] = r.Size
	}
	if r.Quality != "" {
		body["quality"] = r.Quality
	}
	if r.Background != "" {
		body["background"] = r.Background
	}
	payload, _ := json.Marshal(body)
	return c.do(ctx, "/images/generations", "application/json", bytes.NewReader(payload))
}

// Edit calls /images/edits with reference images and an optional mask.
func (c *Client) Edit(ctx context.Context, r ImageRequest) (*Image, error) {
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	field := func(k, v string) {
		if v != "" {
			w.WriteField(k, v)
		}
	}
	field("model", r.Model)
	field("prompt", r.Prompt)
	field("n", "1")
	field("output_format", "png")
	field("size", r.Size)
	field("quality", r.Quality)
	field("background", r.Background)
	field("input_fidelity", r.Fidelity)
	for i, img := range r.References {
		if err := pngPart(w, "image[]", fmt.Sprintf("ref%d.png", i), img); err != nil {
			return nil, err
		}
	}
	if r.Mask != nil {
		if err := pngPart(w, "mask", "mask.png", r.Mask); err != nil {
			return nil, err
		}
	}
	w.Close()
	return c.do(ctx, "/images/edits", w.FormDataContentType(), bytes.NewReader(buf.Bytes()))
}

// pngPart adds a file part with an explicit image/png content type; the
// API rejects the application/octet-stream that CreateFormFile would send.
func pngPart(w *multipart.Writer, field, filename string, data []byte) error {
	h := make(textproto.MIMEHeader)
	h.Set("Content-Disposition", fmt.Sprintf(`form-data; name="%s"; filename="%s"`, field, filename))
	h.Set("Content-Type", "image/png")
	part, err := w.CreatePart(h)
	if err != nil {
		return err
	}
	_, err = part.Write(data)
	return err
}

func (c *Client) do(ctx context.Context, path, contentType string, body *bytes.Reader) (*Image, error) {
	u := strings.TrimRight(c.BaseURL, "/") + path
	var last error
	for attempt := 0; attempt < 4; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(time.Duration(attempt*attempt) * 3 * time.Second):
			}
			body.Seek(0, io.SeekStart)
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, body)
		if err != nil {
			return nil, err
		}
		req.Header.Set("Authorization", "Bearer "+c.APIKey)
		req.Header.Set("Content-Type", contentType)
		resp, err := c.HTTP.Do(req)
		if err != nil {
			last = err
			continue
		}
		data, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if c.Log != nil {
			c.Log(fmt.Sprintf("POST %s → %d (%d bytes)", path, resp.StatusCode, len(data)))
		}
		if err != nil {
			last = err
			continue
		}
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			last = &APIError{Status: resp.StatusCode, Body: string(data)}
			if resp.StatusCode == 429 || resp.StatusCode >= 500 {
				continue
			}
			return nil, last
		}
		var out struct {
			Data []struct {
				B64 string `json:"b64_json"`
			} `json:"data"`
			Usage Usage `json:"usage"`
		}
		if err := json.Unmarshal(data, &out); err != nil {
			return nil, fmt.Errorf("decoding image response: %w", err)
		}
		if len(out.Data) == 0 || out.Data[0].B64 == "" {
			return nil, fmt.Errorf("no image in response")
		}
		png, err := base64.StdEncoding.DecodeString(out.Data[0].B64)
		if err != nil {
			return nil, fmt.Errorf("decoding image: %w", err)
		}
		return &Image{PNG: png, Usage: out.Usage}, nil
	}
	return nil, last
}
