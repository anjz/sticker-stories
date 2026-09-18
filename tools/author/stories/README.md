# Story authoring

Stories for a sticker pack are made in two steps. This folder holds the
output of step 1 and the material both steps rely on.

```
tools/author/
  stories/
    README.md          this file: the process
    GUIDE.md           the authoring brief: audience, quality bar, safety, effects
    FORMAT.md          the intermediate story format (story.json) and the cue grammar
    <packID>/
      plan.md          the roster: which stickers each of the 50 stories centres on
      <storyID>/
        story.json     one story, every language, with inline effect cues
  storycheck/          Go validator: format, cues, safety words, sticker coverage
```

## Step 1 — write the stories (Claude skill)

```
/author-stories forest
```

The `author-stories` skill (`.claude/skills/author-stories/SKILL.md`) reads the
pack's manifest (sticker IDs and names — the graphic side of the pack must
already exist), the effects catalogue (`docs/effects/effects.json`), `GUIDE.md`
and `FORMAT.md`, then:

1. builds a roster (`plan.md`) of 50 stories, each centred on 3–4 stickers,
   covering every sticker in the pack several times plus a few
   "whole-forest" stories that need no particular sticker;
2. writes the stories in small batches — bilingual (every pack language),
   80–140 words per language, with at least one effect cue each — into
   `<packID>/<storyID>/story.json`;
3. validates after every batch with `storycheck` and fixes what it flags.

Run the validator yourself any time:

```sh
cd tools && go run ./author/storycheck -pack ../packs/forest
```

It reports format problems, invalid cues, forbidden words, word counts, and a
sticker coverage table, and exits non-zero on errors.

## Step 2 — produce audio and pack content (not built yet)

A second tool will take each `story.json`, strip the cues to get the
narration text, render it with ElevenLabs (narration plus the sound effects
hinted in the story), align the cues to word timestamps, and emit the
manifest story entry, the `.m4a` per language and the `.effects.json`
sidecar per language (`docs/pack-format.md`, `docs/effects.md`). Its output
lands next to the story (`<storyID>/audio/…`) and is then copied into the
pack by the packager. Nothing in step 1 depends on how step 2 is built; the
contract between them is `FORMAT.md`.
