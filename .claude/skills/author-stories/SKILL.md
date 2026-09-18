---
name: author-stories
description: Author a complete, validated set of bilingual kids' stories (50 per pack, effect cues inline) for a Sticker Stories sticker pack into tools/author/stories/<pack>/. Use when asked to write, create, generate or extend stories for a sticker pack, or to run/fix the story roster or storycheck.
---

# Author stories for a sticker pack

You are the pack's author. The bar is the best read-aloud picture books:
original stories with the depth of the classics, safe for unsupervised
four-year-olds, bilingual, and cued with the app's sticker effects. Follow
`tools/author/stories/GUIDE.md` to the letter and `FORMAT.md` for the file
format. Professional results, not filler.

Arguments: `<packID> [count=50] [notes…]`. Default pack: the one named; if
none is given, ask.

## 1. Load the brief and the cast

Read, in this order, before writing anything:

1. `tools/author/stories/GUIDE.md` and `tools/author/stories/FORMAT.md`.
2. `packs/<packID>/manifest.json` — the pack's `languages`, and every
   sticker's `id` and per-language `name`. These are the cast and the only
   IDs you may use.
3. `docs/effects/effects.json` — the 15 effects, what each means and which
   parameters it accepts.
4. `tools/author/stories/<packID>/` — existing `plan.md` and stories, if
   any. Never duplicate an existing id or premise; continue the roster.

## 2. Build the roster (`plan.md`)

Before writing any story, produce `tools/author/stories/<packID>/plan.md`: a
table with one row per story — `id`, `featured` (3–4 stickers, or none for a
fallback), `supporting`, `tags`, one-line `premise`, `inspiration`.

Constraints (the validator checks them on the finished set):

- every sticker is featured in **at least 5** stories; spread pairings so
  the same trio does not recur;
- **at least 3 fallback** stories (no featured stickers) about the place
  itself;
- moods and shapes vary across the set (see GUIDE "Variety"); no two
  premises alike; every sticker is the hero of at least one story;
- ids are descriptive kebab-case, unique.

Check the roster: `cd tools && go run ./author/storycheck -pack ../packs/<packID> -plan`.
Show the user the coverage summary and proceed.

## 3. Write in batches of five

For each story, create `tools/author/stories/<packID>/<id>/story.json`
exactly per `FORMAT.md`:

- every pack language, written natively, 80–140 words each, same beats and
  cues in each;
- a real shape (setup → wish/problem → try → turn → warm ending), one
  idea, the lesson **shown, never stated**;
- read-aloud craft: short sentences, rhythm, sound words, a landing line;
- at least one cue, typically 2–8: scenery loops at the start, a cue on
  each beat, only on featured/supporting stickers, parameters valid for
  the effect;
- `premise`, `inspiration` (public-domain source and how it is turned),
  `lesson`, `tags`; optional `sound` hints for step 2.

After each batch run:

```
cd tools && go run ./author/storycheck -pack ../packs/<packID>
```

Fix every error and read every warning before the next batch. Word counts,
forbidden words, invalid cues and coverage are mechanical; the safety and
quality rules in the GUIDE are yours to hold.

## 4. Finish

When the count is reached: run `storycheck` once more, make sure it exits
clean with full coverage, and report to the user: how many stories, the
coverage table, the mood mix, and anything you chose not to write and why.
Do not build step 2 (audio); it is a separate tool.

## Never

- Never write anything scary, harmful, mocking or exclusionary; never
  romance, bodies, brands, religion, politics. If unsure, cut.
- Never retell a copyrighted story or use its characters.
- Never state the moral. Never mention a sticker that is not featured or
  supporting. Never rely on an effect for the story to make sense.
- Never pad to hit a word count; cut a weaker story and write a better one.
