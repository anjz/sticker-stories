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
   the **audio tags** (`[whispers]`, `[giggles]`, …) and the **solo sound
   cues**. The whole narration is read in **one take** — one request to the
   text-to-speech **with timestamps** endpoint, tags kept in — so the
   voice, pace and mood carry from the first word to the last. Each solo
   sound then opens a gap in the take at its place: the take is cut at
   the quietest moment between the last word before the cue and the first
   after it (the narrator's own pause; a sentence should end there), and
   the stretches are laid out with the sound between them. Model
   `eleven_v4` (`-model`) at `-stability 0.5` (0–1: lower is more
   expressive and varies more between takes, higher is steadier; v3's
   names creative / natural / robust still mean 0 / 0.5 / 1). There is no
   fallback to another model: a rendition the model refuses fails, and
   the run lists it. A take holds up to 10,000 characters — about ten
   stories' worth.
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
The synthesised narration itself is cached in `_cache/tts/`, one take per
story and language, keyed by its text (tags included), voice, model,
stability and sample rate, so changing levels, music, sounds, bitrate or
where a solo sound goes only re-mixes and costs nothing; a text, tag, voice
or stability change reads the story again. The model performs a little
differently every time: `-retake` (with `-only …`) throws the cached take away and asks for
another performance of just those stories — the way to shop for the best
read of a story you are not happy with. `-only id,…` and
`-lang` narrow a run. Renditions are rendered `-parallel` at a time
(default 10); each shared asset (a mood's music, a sound effect) is still
generated exactly once. A failed rendition does not stop the others; the
run ends with the list, and rerunning retries only those. The first use of a library voice
adds it to the account, and parallel requests doing so collide (HTTP 409
"already_running"): the client retries those like a rate limit.

## Voices

Without `-voice`, the tool searches the public voice library for the most
used storytelling voices in each pack language, takes the top male and the
top female, adds them to your account, and records both in
`<pack>/voices.json`. Stories are shared out across a language's voices
in a fixed order (story ids sorted, round robin), so half the pack is read
by each voice and a story has the same gender in every language. A story
that has been rendered keeps the voice its `<lang>.render.json` names, so
adding, removing or renaming other stories never moves a narrator (and
never re-renders a story that did not change).

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

## Character voices

`{woman:says} "Look, a comet!"` in a story (FORMAT.md, "Character lines")
has that line read by the sticker's character voice, cast once per pack in
`<stories>/character-voices.json`:

```json
{
  "woman": {
    "en-US": { "voiceId": "…", "name": "…", "gender": "female", "source": "library" },
    "es-ES": { "voiceId": "…", "name": "…", "gender": "female", "source": "library" }
  }
}
```

A story with lines is read as one multi-voice take (the text-to-dialogue
**with timestamps** endpoint, `eleven_v4`): the narration in the story's
narrator's voice, each line in its speaker's, every speaker hearing the
others — then cut for solo sounds and aligned like any take. The same
voice in every story, so a character always sounds like itself. A
character's voice must not be the story's narrator (the render says which
story), and the take holds at most 2,000 characters. Changing a character
voice re-reads only the stories it speaks in.

## Audition

```sh
go run ./author/storyaudio audition -pack ../packs/forest -only woodpecker-drums-hello,the-meadow-lullaby \
  -stability 0.3,0.5,0.7 [-all-voices] [-lang en-US] [-dry-run]
```

Reads a few stories once per stability value — and with `-all-voices`
once per voice of each language, not only each story's own narrator —
into `<stories>/_audition/<id>.<lang>.s<stability>[.<voice>].m4a`, fully
mixed, to choose by ear. Nothing in the stories or the pack changes, and
each take lands in the same cache as a render, so rendering a story with
the setting you picked costs nothing more. Try it whenever a pack gets new
voices or the model changes.

## Mix controls

`-sfx-db` (default −12), `-ambience-db` (default −18), `-music-db`
(default −14), `-intro-db` (default −6), `-lead` (default 3 s),
`-stability 0.5`, `-no-sfx`, `-no-music`, `-bitrate 96000`,
`-rate 44100`. Uncompressed 44.1 kHz audio needs a Pro plan; when the plan
refuses it (Creator), every request — narration, sounds, music — asks for
MP3 at 44.1 kHz / 192 kbps instead and decodes it, which keeps the full
bandwidth (24 kHz PCM would lose the top of the voice). The MP3 decoder
shifts timing by under 30 ms, well inside a frame.

## Install

`install` copies each fully rendered story into `packs/<id>/audio/<lang>/`,
merges story entries into `manifest.json` (replacing entries with the same
id, `-prune` drops the rest and deletes their audio and sidecars from the
pack, `-bump` increments the content version), and validates the manifest. Rendered audio in the story folders is gitignored;
the pack copy is the one that is committed. A pack's narration is one
recording: `install` refuses to run while any rendition was read by a
model other than `-model` (default `eleven_v4`), listing them — render them
again, or pass `-model eleven_v3` to reinstall an older recording as it is.

## Notes

- Eleven Music output is licensed per your ElevenLabs plan; check the terms
  before shipping a pack that includes it, or pass `-no-music`.
- Sound hints whose cue word is not found in the text are reported and
  skipped, never guessed.
