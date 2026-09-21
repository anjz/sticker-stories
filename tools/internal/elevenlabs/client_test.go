package elevenlabs

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSpeechWithTimestampsAndRetry(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Header.Get("xi-api-key") != "k" {
			t.Errorf("missing api key header")
		}
		switch r.URL.Path {
		case "/v1/text-to-speech/v1/with-timestamps":
			if calls == 1 { // first attempt: transient failure, must be retried
				w.WriteHeader(503)
				return
			}
			if r.URL.Query().Get("output_format") != "pcm_24000" {
				t.Errorf("output_format = %q", r.URL.Query().Get("output_format"))
			}
			var body map[string]any
			json.NewDecoder(r.Body).Decode(&body)
			if body["model_id"] != "eleven_v3" || body["language_code"] != "es" || body["previous_text"] != "Before." || body["next_text"] != nil {
				t.Errorf("body = %v", body)
			}
			if settings, _ := body["voice_settings"].(map[string]any); settings["stability"] != 0.5 {
				t.Errorf("voice_settings = %v", body["voice_settings"])
			}
			json.NewEncoder(w).Encode(map[string]any{
				"audio_base64": base64.StdEncoding.EncodeToString([]byte{0, 0, 1, 0}),
				"alignment":    map[string]any{"characters": []string{"h", "i"}, "character_start_times_seconds": []float64{0, 0.2}, "character_end_times_seconds": []float64{0.2, 0.4}},
			})
		case "/v1/sound-generation":
			var body map[string]any
			json.NewDecoder(r.Body).Decode(&body)
			if body["model_id"] != SoundModel || body["loop"] != true || body["duration_seconds"] != 12.0 || body["prompt_influence"] != 0.3 {
				t.Errorf("sound body = %v", body)
			}
			w.WriteHeader(422)
			w.Write([]byte(`{"detail":"bad"}`))
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
		}
	}))
	defer srv.Close()
	c := New("k")
	c.BaseURL = srv.URL
	stability := StabilityNatural
	sp, err := c.SpeechWithTimestamps(context.Background(), SpeechRequest{
		VoiceID: "v1", Text: "hi", ModelID: "eleven_v3", LanguageCode: "es", OutputFormat: "pcm_24000",
		Settings: &VoiceSettings{Stability: &stability}, PreviousText: "Before."})
	if err != nil {
		t.Fatal(err)
	}
	if len(sp.Audio) != 4 || sp.Alignment == nil || sp.Alignment.Starts[1] != 0.2 {
		t.Errorf("speech = %+v", sp)
	}
	if _, err := c.SoundEffect(context.Background(), SoundRequest{Prompt: "x", Seconds: 12, Influence: 0.3, Loop: true, OutputFormat: "pcm_24000"}); !IsClientError(err) {
		t.Errorf("want 4xx client error, got %v", err)
	}
}
