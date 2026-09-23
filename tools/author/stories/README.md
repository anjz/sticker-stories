# Story authoring

Stories for a sticker pack are made in two steps. This folder holds the
output of step 1 and the material both steps rely on.

```
tools/author/
  stories/
    README.md          this file: the process
    GUIDE.md           the authoring brief: audience, quality bar, safety, learning,
                       effects, voice performance, sound effects
    FORMAT.md          the intermediate story format (story.json), the cue grammar,
                       the allowed audio tags
    <packID>/
      plan.md          the roster: which stickers each of the 50 stories centres on
      <storyID>/
        story.json     one story, every language, with inline effect cues
  storycheck/          Go validator: format, cues (against the catalogue and the pack setting),
                       safety words, sticker coverage, effect usage
```

## Step 1 — write the stories (Claude skill)

```
/author-stories forest
```

The `author-stories` skill (`.claude/skills/author-stories/SKILL.md`) reads the
pack's manifest (sticker IDs and names — the graphic side of the pack must
already exist — and its `setting`, which decides the canvas effects the
stories may use), the effects catalogue (`docs/effects/effects.json`),
`GUIDE.md` and `FORMAT.md`, then:

1. builds a roster (`plan.md`) of 50 stories, each centred on 3–4 stickers,
   covering every sticker in the pack several times plus a few
   "whole-forest" stories that need no particular sticker;
2. writes the stories in small batches — bilingual (every pack language),
   80–140 words per language, with effect cues, a few Eleven v3 audio tags
   for the narrator, sound effects (some in place of sound words), a canvas
   effect wherever the words describe weather or light, and a
   small true fact in about four stories in ten — into
   `<packID>/<storyID>/story.json`;
3. validates after every batch with `storycheck` and fixes what it flags.

Run the validator yourself any time:

```sh
cd tools && go run ./author/storycheck -pack ../packs/forest
```

It reports format problems, invalid cues (including canvas effects that do
not suit the pack's setting, unknown sounds, tags outside the allowed
list), forbidden words, word counts, a sticker coverage table, effect /
audio-tag / sound usage and the learning share, and exits non-zero on
errors.

## Step 2 — produce audio and pack content (`storyaudio`)

```
cd tools && go run ./author/storyaudio render -pack ../packs/forest
cd tools && go run ./author/storyaudio install -pack ../packs/forest -prune -bump
```

`storyaudio` (`tools/author/storyaudio/README.md`) takes each `story.json`,
takes the text apart (words, cues, audio tags, solo sounds), renders it
with ElevenLabs (Eleven v3 narration with character timestamps and the
tags performed, the story's sound effects — under words, in gaps the
narrator leaves for them, or as ambience — and a calm background loop),
aligns the cues — sticker and canvas — to the spoken words, and emits the
`.m4a` per language plus the `.effects.json` sidecar per language
(`docs/pack-format.md`, `docs/effects.md`) into `<storyID>/audio/`.
`install`
copies them into the pack and merges the manifest story entries. Nothing in
step 1 depends on how step 2 is built; the contract between them is
`FORMAT.md`.
