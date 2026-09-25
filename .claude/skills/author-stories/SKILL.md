---
name: author-stories
description: Author a complete, validated set of bilingual kids' stories (50 per pack; sticker, canvas and sound cues, face changes and everyone-at-once cues plus Eleven v3 audio tags inline; setting-aware; about 40 % carry a small piece of learning) for a Sticker Stories sticker pack into tools/author/stories/<pack>/. Use when asked to write, create, generate or extend stories for a sticker pack, or to run/fix the story roster or storycheck.
---

# Author stories for a sticker pack

You are the pack's author. The bar is the best read-aloud picture books:
original stories with the depth of the classics, safe for unsupervised
four-year-olds, bilingual, and written for a narrator who performs — the
stickers react on their beats, every sticker comes alive in its own
action on the words that tell it (staying in its pause pose while the
story lingers there), stickers walk, hop, fly or sprout in as they are named, now and then the weather or light of the
whole scene changes, real sound effects play (sometimes instead of a sound
word), and the Eleven v3 voice takes your stage directions. About four
stories in ten quietly teach one true thing about the pack's world. Follow
`tools/author/stories/GUIDE.md` to the letter and `FORMAT.md` for the file
format. Professional results, not filler.

Arguments: `<packID> [count=50] [notes…]`. Default pack: the one named; if
none is given, ask.

## 1. Load the brief and the cast

Read, in this order, before writing anything:

1. `tools/author/stories/GUIDE.md` and `tools/author/stories/FORMAT.md`.
2. `packs/<packID>/manifest.json` — the pack's `languages`, every
   sticker's `id` and per-language `name` (the cast and the only IDs you
   may use), and its **`setting`** (`outdoors`, `indoors`, `space`,
   `underwater` or `none`; absent means `none`). The setting decides which canvas effects the stories may
   use — note it down before writing anything.   Every sticker declares `animations`: one **action** (what stories cue)
   and one **move** (its walk, hop, flight or sprout, played by its
   entrance). Run
   `cd tools && go run ./author/storycheck -pack ../packs/<packID> -plan`,
   which prints every action: what it shows, how long it plays and, for
   most, its **pause pose** (`hold:` — the snail hidden in its shell, the
   bear cub asleep) with the time to reach it and to come out of it. The
   sidecars (`packs/<packID>/anims/<sticker>.<id>.json`) hold the same
   `description` and `pause.shows`. Each action is one fixed sequence;
   stories choose when it happens and whether it stops on its pause pose.
   Note which stickers declare `expressions` (face variants: `happy`,
   `sad`, `sleeping`, `surprised`… plus their own `normal` face) — the
   `-plan` run lists them too. Faces are the cheapest way to make the
   stage feel alive; plan to use them in almost every story.   Note every sticker's **`stage`**: its `entrance` (`hop` for things
   that walk, hop, crawl or roll in — they play their move on the way —,
   `fly` for things that fly, `grow` for plants that sprout where they stand)
   and where it lands — the pack's `features` it goes `on` (the meadow,
   the sky, the pond, the trees' branches), in order of preference. A story brings in every sticker it names that the child has not
   placed, on the word that first names it (FORMAT "Entrance cues"), so
   the words should fit how and where it arrives. The `-plan` run lists
   the entrances and, per feature, its description and who lands there;
   a sticker with no stage grows in a default area — tell the user
   (stages and features are authored in `tools/author/art/<pack>/art.json`
   and installed by `stickerart`).
   **Look at every sticker's image** (`packs/<packID>/stickers/<id>.webp`;
   convert to PNG with `sips -s format png` to view it) and write down what
   the art actually shows: colours, anything countable (spots, petals,
   stripes, legs, wings), what it holds, and what it lacks
   (a fawn with no antlers, a ladybug with five spots, not seven). **Count from
   the picture, never from what the real animal or plant usually has** —
   the child is looking at the sticker while the narrator speaks. Put this
   in the roster's cast table.
3. **The scene.** Look at the pack's background and foreground
   (`packs/<packID>/art/background*.webp`, `foreground*.webp`; convert to
   PNG with `sips -s format png` and draw a grid over them) and read or
   write `tools/author/stories/<packID>/scene.md` (GUIDE "Match the
   scene"): every thing the picture shows with where it is (fractions of
   the base picture), everything a story might expect that it does **not**
   show (a hill, a stream, a path, a burrow…), and what each canvas effect
   the setting allows does and does not change (snow falls but the meadow
   stays green). If scene.md exists, check it against the art — the art
   may have changed. Every premise and every sentence must fit it.
4. `docs/effects/effects.json` — the exact library: the 12 sticker effects
   (`effects`) and the canvas effects (`canvasEffects`), what each means,
   which parameters each accepts, and which `settings` each canvas effect
   suits. Use only these names, exactly as spelled.
5. `tools/author/stories/<packID>/` — existing `plan.md` and stories, if
   any. Never duplicate an existing id or premise; continue the roster.

## 2. Build the roster (`plan.md`)

Before writing any story, produce `tools/author/stories/<packID>/plan.md`: a
table with one row per story — `id`, `featured` (3–4 stickers, or none for a
fallback), `supporting`, `tags`, one-line `premise`, `inspiration`,
`learning` (the one fact the story shows, or `—`), `canvas` (the canvas
effects the story will use — every weather or light moment in its premise —
or `—`), and `live` (the stickers whose actions the story plays, marking
the ones it holds on their pause pose: `snail (hold), frog` — two to four
is typical, five at most — or `—`).

Constraints (the validator checks them on the finished set):

- every sticker is featured in **at least 5** stories; spread pairings so
  the same trio does not recur;
- **at least 3 fallback** stories (no featured stickers) about the place
  itself;
- moods and shapes vary across the set (see GUIDE "Variety"); no two
  premises alike; every sticker is the hero of at least one story;
- canvas effects planned for **every story whose premise has weather or
  light in it** (a snowy day, a rainy morning, dusk, a windy hill, a party),
  up to three per story, spread across the effects the pack's setting allows
  — and none at all when the setting is `none`; think about weather when
  shaping premises, since it is one of the things the child sees;
- **every sticker's action plays in at least three stories**, mostly
  ones where it is featured and whose premise grows from it (the raccoon's
  peekaboo, the snail hiding in its shell, the flower closing at night);
  most stories play two to four actions, on the words that tell them, and
  hold one on its pause pose where the story lingers in it (a hiding
  snail, a sleeping bear, a wishing acorn) — about half the stories use a
  hold;
- **about 40 % of the rows carry a `learning` fact** (GUIDE "Learning"):
  one concrete, true, observable thing about how the pack's world works,
  each fact used once, spread across the cast; the other rows stay pure
  story;
- **every premise happens in the scene** (scene.md): the action on the
  meadow, at the pond, in or under the two trees, among the far bushes —
  never on a hill, by a stream or down a path the picture does not have;
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
- **a living stage** (GUIDE "Keep the stage alive", "Faces", "Everyone at
  once"): a beat on most sentences — about one cue on the stickers per
  8–12 spoken words (storycheck warns past 12). Face cues
  (`{bear:face happy}`) wherever a feeling changes, two to five per story
  and put back when the feeling passes (they have no duration; the end
  resets them); `{all:…}` — `{all:face sleeping}`, `{all:hop}`,
  `{all:hearts}` — when the words are about everyone ("everyone laughed",
  "the whole forest fell asleep"), which is what brings the fallback
  stories to life; one beat per moment, never a pile-up;
- **an entrance for every featured and supporting sticker**
  (`{fox:enter}`, FORMAT "Entrance cues", GUIDE "Entrances"), in every
  language, right before the word that **first names it** — before any
  other cue on that word — so a sticker the child has not placed hops,
  flies or sprouts into the scene, playing its move, as the narrator
  says its name. Name every
  one of them in the words (a sticker that is never named has nowhere to
  enter); where the story allows, make the first mention an arrival
  ("along trotted Fox", "Frog came hopping", "Snail crawled up slowly")
  that suits its move and where it lands (the bee buzzing up in the air,
  the owl flying down onto a branch, the frog hopping to the pond, the
  mushroom popping up on the meadow), but it must also read fine when the
  sticker was on the canvas all along; leave a few words before an
  action on a sticker that just entered (it takes 1–6 s to arrive). Cue nothing on a sticker before its entrance except
  a `float` loop or a face;
- **move cues** (`{fox:go to rabbit}`, `{bee:go on flower}`, `{mouse:go
  under mushroom}`, `{frog:go to pond}`, `{fox:go away}` … `{fox:go back}`
  — FORMAT "Move cues", GUIDE "Movement") wherever the words have a
  character go somewhere: to another character (on stage already), onto
  or under one, to a place the scene has, off the canvas and back; only
  walkers and flyers move; most stories have one to four; **the way it
  goes matches the words** — a sticker with two ways to go
  (`storycheck -plan`, "ways to go": the ladybug crawls or flies, the
  bird flies or hops, the duckling waddles or swims, the firefly flies or
  walks) needs `by` when the words say the other one (`{ladybug:go on
  flower by fly}`, `{ladybug:enter by fly}`), on each such move; never
  write a way the sticker has no move for;
- live cues (`{bear:live}`, `{snail:live hold}` … `{snail:live resume}` —
  see FORMAT "Live cues", GUIDE "Live stickers") as the roster planned
  them: on the words that tell exactly what that action shows, in the
  frames' order, with the next 6–10 words free of other effects on that
  sticker; a hold on the words that put it in its pause pose, its resume
  (if any) on the words that bring it out, no face change on it while it
  is held; the words alone must still tell the moment;
- a canvas cue (`{canvas:rain 0.8 14s}` — see FORMAT "Canvas cues") for
  **every** weather or light moment the words describe that the pack's
  setting has an effect for — snow falling, rain, fog, sunset, night and
  the moon, clouds, a gust, autumn leaves, fireflies, a party, bubbles, the
  sun coming out — up to three per story, cued a beat before the words it
  illustrates, lasting as long as those beats; the weather stays written
  into the words so the story reads fine without it. `storycheck` warns
  when the text mentions one and never cues it: fix every such warning by
  adding the cue, or, if the word is only a comparison ("faster than the
  wind"), by rewording;
- every place the text puts the action is one the picture shows
  (scene.md): no hill, stream, path, burrow or house the art lacks, no
  weather that repaints the scene (snow covering the meadow, trees turning
  gold), places off stage only in passing (GUIDE "Match the scene");
- every number, colour or visible feature the text gives a sticker (her
  five spots, the eight yellow petals, his stripy tail) matches the art as
  recorded in the cast table; if a premise needs a feature the sticker
  doesn't show (antlers on the fawn, blossom on the oak), change the
  premise, not the fact;
- **the narrator's performance** (GUIDE "Voice performance"): rhythm in the
  punctuation first (… — CAPITALS, short sentences), then two to five audio
  tags from the allowed list in FORMAT "Audio tags", each right before the
  words it colours, where the feeling genuinely changes — never stacked,
  never more than six;
- **sound effects** (GUIDE "Sound effects", FORMAT "Sound cues"): two or
  three per story in a `sounds` table, cued inline — `{sfx:id solo}`
  between sentences where a real sound tells it better than the sound word
  (rain, a splash, a knock), `{sfx:id}` under a sound word the child will
  say along with, one `"loop": true` ambience at most; keep some sound
  words spoken for read-aloud rhythm; never a scary sound;
- for the roster's learning rows, the fact shown by what a character does
  or finds, stated in the `learning` field and tagged `learning`, never
  read out as a lesson;
- `premise`, `inspiration` (public-domain source and how it is turned),
  `lesson`, `tags`.

After each batch run:

```
cd tools && go run ./author/storycheck -pack ../packs/<packID>
```

Fix every error and read every warning before the next batch. Word counts,
forbidden words, invalid cues (including a canvas effect the pack's setting
does not allow, an unknown sound id, a tag outside the allowed list) and
coverage are mechanical; the safety and quality rules in the GUIDE are
yours to hold. Watch the tables it prints: effects spread across the whole
library, every weather mention cued, faces changing in almost every
story, every sticker's action in several stories and holds in about
half, audio tags and sounds in most stories but never
crowding one, and learning at about 40 %.

## 4. Finish

When the count is reached: run `storycheck` once more, make sure it exits
clean with full coverage, and report to the user: how many stories, the
coverage table, the effects-used, faces, live-sticker, audio-tag and sound
tables, that every story's entrances are clean, the learning share, the mood mix, and anything you chose not to write and why. Do not
build step 2 (audio); it is a separate tool.

## Never

- Never write anything scary, harmful, mocking or exclusionary; never
  romance, bodies, brands, religion, politics. If unsure, cut.
- Never retell a copyrighted story or use its characters.
- Never state the moral. Never mention a sticker that is not featured or
  supporting. Never rely on an effect — sticker or canvas — for the story
  to make sense.
- Never set a story, or any moment of it, in a place the scene does not
  show (a hill, a stream, a path, a cave), make a weather effect claim to
  repaint the picture (a white meadow, golden trees), or end a story on
  something that never appears on screen.
- Never give a sticker a count, colour or feature its art contradicts —
  a ladybug counting seven spots when the sticker shows five is a mistake
  every child will catch.
- Never give a sticker a face it doesn't have, a face the words contradict
  (sleeping while it talks), or a sad face that the story doesn't mend.
- Never use `{all:…}` for a live animation or on words that aren't about
  everyone.
- Never leave a featured or supporting sticker without its `{id:enter}`
  on its first mention, put the entrance later than the first mention,
  or describe a sticker where its stage cannot put it (a fox up in the
  clouds, a woodpecker hopping across the meadow).
- Never move a sticker that stays put (a flower, a mushroom), move one
  before its entrance or to one that is not on stage yet, put a big
  character on or under a small one, or cue anything on a sticker that
  has gone away before it comes back.
- Never cue a live action on words it contradicts or out of the frames'
  order, resume one that is not held, hold one without a pause pose, or
  pile more than five into a story.
- Never use an effect name that is not in `docs/effects/effects.json`, a
  canvas effect the pack's setting does not allow, a canvas effect the
  words don't describe, a described snowfall (or rain, sunset…) left
  without its effect, or an audio tag outside FORMAT's allowed list.
- Never state the learning fact as a lesson, invent a fact, or put one in
  more than about half the stories.
- Never a scary sound effect, a solo sound mid-sentence, or a story that
  stops for sounds more than twice.
- Never pad to hit a word count; cut a weaker story and write a better one.
