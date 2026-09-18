package openai

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestEditMultipartAndRetry(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			w.WriteHeader(500)
			return
		}
		if r.Header.Get("Authorization") != "Bearer k" || r.URL.Path != "/images/edits" {
			t.Errorf("bad request %s %s", r.URL.Path, r.Header.Get("Authorization"))
		}
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			t.Fatal(err)
		}
		if r.FormValue("background") != "transparent" || r.FormValue("size") != "1024x1024" {
			t.Errorf("fields = %v", r.MultipartForm.Value)
		}
		if n := len(r.MultipartForm.File["image[]"]); n != 2 {
			t.Errorf("want 2 reference images, got %d", n)
		}
		if len(r.MultipartForm.File["mask"]) != 1 {
			t.Errorf("mask missing")
		}
		json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString([]byte("PNG!"))}}, "usage": map[string]int{"total_tokens": 7}})
	}))
	defer srv.Close()
	c := New("k")
	c.BaseURL = srv.URL
	img, err := c.Edit(context.Background(), ImageRequest{Model: "m", Prompt: "p", Size: "1024x1024", Background: "transparent", References: [][]byte{[]byte("a"), []byte("b")}, Mask: []byte("m")})
	if err != nil {
		t.Fatal(err)
	}
	if string(img.PNG) != "PNG!" || img.Usage.TotalTokens != 7 || calls != 2 {
		t.Errorf("img = %+v calls %d", img, calls)
	}
}
