# tts (stub)

Development-time pipeline that batch-renders story narration audio.
Not built yet — see `docs/roadmap.md` (iteration 2).

## Intended shape

- Input: a validated pack directory (stories carry their full `text` in the
  manifest — that is the source for synthesis).
- Engine: ElevenLabs API (dev-time only; never ships with the app).
- Processing: per-story rendering with a consistent, child-friendly voice;
  loudness normalisation across the pack; encode to AAC `.m4a` at the paths
  declared in `stories[].audio`.
- Output must pass `packager validate` (all audio files present).

Until this exists, `../placeholdergen` renders placeholder narration with the
macOS `say` command.
