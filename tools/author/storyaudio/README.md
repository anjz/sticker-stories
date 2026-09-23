# storyaudio — step 2 of story authoring

Renders every authored story (`tools/author/stories/<pack>/<id>/story.json`)
into the pack's per-language narration and effect sidecars with ElevenLabs,
then installs them into the pack manifest. Dev-time only; nothing here ships
with the app, and the app never talks to ElevenLabs.

```sh
cp tools/.env.example tools/.env      # add ELEVENLABS_API_KEY
cd tools
go run ./author/storyaudio render  -pack ../packs/forest -dry-run   # cost preview, no API calls
go run ./author/storyaudio voices  -pack ../packs/forest            # candidate voices per language
go run ./author/storyaudio render  -pack ../packs/forest            # synthesise, align, mix, encode
go run ./author/storyaudio install -pack ../packs/forest -prune -bump
go run ./packager validate ../packs/forest
```

## What `render` does, per story and language

1. Takes the text apart (`FORMAT.md`): the spoken words, the effect cues,
   the Eleven v3 **audio tags** (`[whispers]`, `[giggles]`, …) and the
   **solo sound cues**. The narration is read in segments — one per stretch
   between solo sounds — each sent to the text-to-speech **with
   timestamps** endpoint with its tags kept in (v3 does not yet accept
   `previous_text` / `next_text`, so each stretch is read on its own —
   keep them a sentence or two long; the validator warns below 12 words).
   Model `eleven_v3` at `-stability natural` (creative | natural |
   robust — v3's three settings; natural follows tags without reading them
   aloud); if timestamps are refused it falls back to
   `eleven_multilingual_v2` with the tags stripped (v2 would say them).
2. Maps each cue's word to the returned character timings — tags are
   characters the model times too, so cues land on the words — and writes
   the effects sidecar (`docs/effects.md`) — sticker triggers, canvas
   triggers (`{canvas:rain …}` cues become entries with no `sticker`) and
   live-animation triggers (`{bear:live}` becomes `"animation": "yawn"`)
   in one list — strictly validated against the pack's stickers, their
   animations and its `setting`. A sticker effect that starts while that
   sticker's live animation is still playing is reported in the log and
   the render record (`liveOverlaps`). Cues on the first word stay at `0.0`; everything else is
   shifted by the music lead-in. Sound cues are not triggers.
3. Generates the story's `sounds` with the sound-generation model
   (`eleven_text_to_sound_v2`, cached by prompt/length in `_cache/sfx/`)
   and mixes them: `{sfx:id}` under its word, `{sfx:id solo}` in the gap
   the narrator left for it (the sound's `seconds` plus a breath either
   side), a `"loop": true` sound as a seamless ambience bed from its cue,
   faded and ducked under the voice at `-ambience-db` (−18). One-shots sit
   at `-sfx-db` (−12). Older `sound` hints still play on their word. At
   most six sounds per story.
4. Picks the story's mood music (see Music), loops it to the story length
   and fades it. The music
   plays alone for 3 s (`-lead`) at the intro level (`-intro-db`, −6 dB
   under the narrator's level), ramps down over the last second to the bed
   level (`-music-db`, −14 dB), and is ducked a little more while the
   narrator speaks.
5. Normalises the narration to a consistent level, limits peaks, and encodes
   AAC (64 kbps mono, `-bitrate`) with macOS `afconvert` to `<id>/audio/<lang>.m4a` next to
   `<lang>.effects.json` and a `<lang>.render.json` fingerprint.

A story is skipped when its text, voice, model, stability, sounds and mix
settings are unchanged since the last render (`-force` re-mixes anyway).
The synthesised narration itself is cached in `_cache/tts/` per segment,
keyed by its text (tags included), its neighbours, voice, model, stability
and sample rate, so changing levels, music, sounds or bitrate only re-mixes
and costs nothing; a text, tag, voice or stability change calls the API
again for the segments it touches. v3 performs a little differently every
time: `-retake` (with `-only …`) throws the cached take away and asks for
another performance of just those stories — the way to shop for the best
read of a story you are not happy with. `-only id,…` and
`-lang` narrow a run. Renditions are rendered `-parallel` at a time
(default 10); each shared asset (a mood's music, a sound effect) is still
generated exactly once. A failed rendition does not stop the others; the
run ends with the list, and rerunning retries only those.

## Voices

Without `-voice`, the tool searches the public voice library for the most
used storytelling voices in each pack language, takes the top male and the
top female, adds them to your account, and records both in
`<pack>/voices.json`. Stories are shared out across a language's voices
in a fixed order (story ids sorted, round robin), so half the pack is read
by each voice, a story keeps its voice across runs, and it has the same
gender in every language.

Pin your own with `-voice en-US=<id>,es-ES=<id>` (one voice per language)
or `-voice en-US=<id>+<id>,es-ES=<id>+<id>` (several, shared out the same
way); a bare id applies to every language. Choices are saved to
`voices.json`; edit or delete that file to start over. `voices` lists the
top candidates with their gender.

## Music

`<pack>/music.json` holds one Eleven Music prompt per mood tag plus a
default; the tool writes it with sensible defaults the first time and you
can edit it. A story uses the first of its tags that has a prompt, so
`bedtime` stories get a hushed music-box piece and `funny` ones something
bouncy. Each distinct prompt is composed once (60 s) and cached in
`_cache/music/`. `-music-prompt "…"` forces one prompt for every story.

## Mix controls

`-sfx-db` (default −12), `-ambience-db` (default −18), `-music-db`
(default −14), `-intro-db` (default −6), `-lead` (default 3 s),
`-stability natural`, `-no-sfx`, `-no-music`, `-bitrate 96000`,
`-rate 44100` (44.1 kHz PCM needs a Pro plan; the tool drops to 24 kHz
automatically if refused).

## Install

`install` copies each fully rendered story into `packs/<id>/audio/<lang>/`,
merges story entries into `manifest.json` (replacing entries with the same
id, `-prune` drops the rest and deletes their audio and sidecars from the
pack, `-bump` increments the content version), and validates the manifest. Rendered audio in the story folders is gitignored;
the pack copy is the one that is committed.

## Notes

- Eleven Music output is licensed per your ElevenLabs plan; check the terms
  before shipping a pack that includes it, or pass `-no-music`.
- Sound hints whose cue word is not found in the text are reported and
  skipped, never guessed.
