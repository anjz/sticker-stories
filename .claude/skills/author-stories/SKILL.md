---
name: author-stories
description: Author a complete, validated set of bilingual kids' stories (50 per pack, sticker and canvas effect cues inline, setting-aware) for a Sticker Stories sticker pack into tools/author/stories/<pack>/. Use when asked to write, create, generate or extend stories for a sticker pack, or to run/fix the story roster or storycheck.
---

# Author stories for a sticker pack

You are the pack's author. The bar is the best read-aloud picture books:
original stories with the depth of the classics, safe for unsupervised
four-year-olds, bilingual, and cued with the app's effects — the stickers
reacting on their beats, and now and then the weather or light of the
whole scene. Follow `tools/author/stories/GUIDE.md` to the letter and
`FORMAT.md` for the file format. Professional results, not filler.

Arguments: `<packID> [count=50] [notes…]`. Default pack: the one named; if
none is given, ask.

## 1. Load the brief and the cast

Read, in this order, before writing anything:

1. `tools/author/stories/GUIDE.md` and `tools/author/stories/FORMAT.md`.
2. `packs/<packID>/manifest.json` — the pack's `languages`, every
   sticker's `id` and per-language `name` (the cast and the only IDs you
   may use), and its **`setting`** (`outdoors`, `indoors` or `none`; absent
   means `none`). The setting decides which canvas effects the stories may
   use — note it down before writing anything.
3. `docs/effects/effects.json` — the exact library: the 12 sticker effects
   (`effects`) and the 5 canvas effects (`canvasEffects`), what each means,
   which parameters each accepts, and which `settings` each canvas effect
   suits. Use only these names, exactly as spelled.
4. `tools/author/stories/<packID>/` — existing `plan.md` and stories, if
   any. Never duplicate an existing id or premise; continue the roster.

## 2. Build the roster (`plan.md`)

Before writing any story, produce `tools/author/stories/<packID>/plan.md`: a
table with one row per story — `id`, `featured` (3–4 stickers, or none for a
fallback), `supporting`, `tags`, one-line `premise`, `inspiration`, and
`canvas` (the canvas effect the story will use, or `—` for most rows).

Constraints (the validator checks them on the finished set):

- every sticker is featured in **at least 5** stories; spread pairings so
  the same trio does not recur;
- **at least 3 fallback** stories (no featured stickers) about the place
  itself;
- moods and shapes vary across the set (see GUIDE "Variety"); no two
  premises alike; every sticker is the hero of at least one story;
- canvas effects planned for a **minority** of stories (aim for roughly one
  in four or five, never more than 40 %), only where the premise has weather
  or light in it, spread across the effects the pack's setting allows —
  none at all when the setting is `none`;
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
- at least one cue, typically 2–8: a `float` loop on anything airborne at
  the start, a cue on each beat, only on featured/supporting stickers,
  parameters valid for the effect; reach for the less obvious effects
  (`glow`, `tint`, `spin`, `fade-in`, `shake`) when a beat wants them, so
  the set uses the whole library rather than `hop`/`pulse`/`wobble` alone —
  but never force one in;
- a canvas cue (`{canvas:rain 0.8 14s}` — see FORMAT "Canvas cues") only in
  the stories the roster marked for one: at most one or two, an effect the
  pack's setting allows, cued a beat before the words it illustrates, with
  the weather or light written into the words themselves so the story reads
  fine without it;
- `premise`, `inspiration` (public-domain source and how it is turned),
  `lesson`, `tags`; optional `sound` hints for step 2.

After each batch run:

```
cd tools && go run ./author/storycheck -pack ../packs/<packID>
```

Fix every error and read every warning before the next batch. Word counts,
forbidden words, invalid cues (including a canvas effect the pack's setting
does not allow) and coverage are mechanical; the safety and quality rules in
the GUIDE are yours to hold. Watch the "effects used" table it prints: a
library-wide spread with canvas effects in a clear minority is the target.

## 4. Finish

When the count is reached: run `storycheck` once more, make sure it exits
clean with full coverage, and report to the user: how many stories, the
coverage table, the effects-used table (sticker and canvas), the mood mix,
and anything you chose not to write and why. Do not build step 2 (audio);
it is a separate tool.

## Never

- Never write anything scary, harmful, mocking or exclusionary; never
  romance, bodies, brands, religion, politics. If unsure, cut.
- Never retell a copyrighted story or use its characters.
- Never state the moral. Never mention a sticker that is not featured or
  supporting. Never rely on an effect — sticker or canvas — for the story
  to make sense.
- Never use an effect name that is not in `docs/effects/effects.json`, a
  canvas effect the pack's setting does not allow, or a canvas effect as
  routine decoration.
- Never pad to hit a word count; cut a weaker story and write a better one.
