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

1. Strips the inline cues (`FORMAT.md`) to get the narration text and sends
   it to the text-to-speech **with timestamps** endpoint (`eleven_v3` by
   default; falls back to `eleven_multilingual_v2` if timestamps are refused).
2. Maps each cue's word to the returned character timings and writes the
   sticker-effect sidecar (`docs/effects.md`), strictly validated. Scenery
   loops stay at `0.0`; everything else is shifted by the music lead-in.
3. Turns each `sound` hint into a short clip via the sound-generation
   endpoint (cached by prompt in `_cache/sfx/`), placed on the hinted word,
   at most three per story, about 12 dB under the narrator.
4. Picks the story's mood music (see Music), loops it to the story length
   and fades it. The music
   plays alone for 3 s (`-lead`) at the intro level (`-intro-db`, −6 dB
   under the narrator's level), ramps down over the last second to the bed
   level (`-music-db`, −14 dB), and is ducked a little more while the
   narrator speaks.
5. Normalises the narration to a consistent level, limits peaks, and encodes
   AAC with macOS `afconvert` to `<id>/audio/<lang>.m4a` next to
   `<lang>.effects.json` and a `<lang>.render.json` fingerprint.

A story is skipped when its text, voice, model, hints and mix settings are
unchanged since the last render (`-force` overrides). `-only id,…` and
`-lang` narrow a run. Renditions are rendered `-parallel` at a time
(default 5); each shared asset (a mood's music, a sound effect) is still
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

`-sfx-db` (default −12), `-music-db` (default −14), `-intro-db` (default −6),
`-lead` (default 3 s), `-no-sfx`, `-no-music`, `-bitrate 96000`, `-rate 44100` (44.1 kHz PCM needs a
Pro plan; the tool drops to 24 kHz automatically if refused).

## Install

`install` copies each fully rendered story into `packs/<id>/audio/<lang>/`,
merges story entries into `manifest.json` (replacing entries with the same
id, `-prune` drops the rest, `-bump` increments the content version), and
validates the manifest. Rendered audio in the story folders is gitignored;
the pack copy is the one that is committed.

## Notes

- Eleven Music output is licensed per your ElevenLabs plan; check the terms
  before shipping a pack that includes it, or pass `-no-music`.
- Sound hints whose cue word is not found in the text are reported and
  skipped, never guessed.
