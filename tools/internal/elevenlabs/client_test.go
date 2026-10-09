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
			if body["model_id"] != "eleven_v4" || body["language_code"] != "es" || body["previous_text"] != "Before." || body["next_text"] != nil {
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
	stability := 0.5
	sp, err := c.SpeechWithTimestamps(context.Background(), SpeechRequest{
		VoiceID: "v1", Text: "hi", ModelID: "eleven_v4", LanguageCode: "es", OutputFormat: "pcm_24000",
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

func TestVoiceAdditionConflictIsRetried(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			w.WriteHeader(409)
			w.Write([]byte(`{"detail":{"type":"conflict","code":"already_running","message":"Multiple voice additions/deletions for the same voice were called at the same time. Please retry shortly."}}`))
			return
		}
		w.Write([]byte(`{"audio_base64":"AAAA","alignment":{"characters":["h"],"character_start_times_seconds":[0],"character_end_times_seconds":[0.1]}}`))
	}))
	defer srv.Close()
	c := New("k")
	c.BaseURL = srv.URL
	if _, err := c.SpeechWithTimestamps(context.Background(), SpeechRequest{VoiceID: "v", Text: "h"}); err != nil {
		t.Fatalf("a voice-addition conflict should be retried: %v", err)
	}
	if calls != 2 {
		t.Errorf("calls = %d, want 2", calls)
	}
	if IsClientError(&APIError{Status: 409, Body: `{"detail":{"code":"already_running"}}`}) {
		t.Error("already_running is transient, not a client error")
	}
}

func TestDialogueWithTimestamps(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/text-to-dialogue/with-timestamps" || r.URL.Query().Get("output_format") != "mp3_44100_192" {
			t.Errorf("request %s?%s", r.URL.Path, r.URL.RawQuery)
		}
		var body struct {
			Inputs   []DialogueInput    `json:"inputs"`
			Model    string             `json:"model_id"`
			Settings map[string]float64 `json:"settings"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		if len(body.Inputs) != 2 || body.Inputs[1].VoiceID != "fox" || body.Model != "eleven_v4" || body.Settings["stability"] != 0.5 {
			t.Errorf("body = %+v", body)
		}
		w.Write([]byte(`{"audio_base64":"AAAA","alignment":{"characters":["a","b"],"character_start_times_seconds":[0,0.1],"character_end_times_seconds":[0.1,0.2]},"voice_segments":[]}`))
	}))
	defer srv.Close()
	c := New("k")
	c.BaseURL = srv.URL
	st := 0.5
	sp, err := c.DialogueWithTimestamps(context.Background(), DialogueRequest{
		Inputs:  []DialogueInput{{"a", "narrator"}, {"b", "fox"}},
		ModelID: "eleven_v4", OutputFormat: "mp3_44100_192", Stability: &st})
	if err != nil || len(sp.Audio) != 3 || len(sp.Alignment.Characters) != 2 {
		t.Fatalf("dialogue = %+v, %v", sp, err)
	}
}
