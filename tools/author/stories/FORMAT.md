# Story format (intermediate, schema 1)

One folder per story, `tools/author/stories/<packID>/<storyID>/story.json`.
This is the authoring format: human-readable, bilingual, with everything
that happens around the words inline in the text — effect cues (sticker,
live animation, canvas, sound) in curly braces and the narrator's delivery (Eleven v3 audio
tags) in square brackets. Step 2 turns it into pack content; the app never
reads it.

```json
{
  "schema": 1,
  "id": "the-race-that-tied",
  "pack": "forest",
  "featured": [
    "fox",
    "rabbit",
    "flower"
  ],
  "supporting": [
    "butterfly"
  ],
  "tags": [
    "friendship",
    "funny",
    "race"
  ],
  "premise": "Fox and Rabbit race to the big flower; Fox tumbles into the leaves, Rabbit turns back, and the flower declares a tie.",
  "inspiration": "The Tortoise and the Hare (Aesop), turned around: nobody wins by leaving a friend behind, and the finish line is a flower who has been watching all along.",
  "lesson": "Friends finish together.",
  "learning": "",
  "languages": {
    "en-US": {
      "title": "The Race That Tied",
      "text": "[excited] {butterfly:float loop} Ready, steady, go! {fox:enter} {fox:hop} Fox and {rabbit:enter} {rabbit:hop} Rabbit raced across the meadow to the big pink {flower:enter} flower, where a {butterfly:enter} butterfly was waiting. Fox was fast, like a {fox:shake 0.8} whoosh of wind. Rabbit was bouncy, like a {rabbit:hop x3} spring. Halfway there, Fox {fox:wobble x2} tripped over his own fluffy tail and {fox:spin} rolled, tumble tumble tumble, into a crunchy pile of leaves. {sfx:leaves solo} Rabbit stopped. She looked at the flower. She looked at Fox. Then she {rabbit:hop x2} hopped all the way back and pulled him up by the paw. They crossed the finish line {fox:hearts} {rabbit:hearts} together, and the flower {flower:pulse} nodded her big pink head. Who won? Both of them, said the flower. That is how best {fox:pulse} {rabbit:pulse} friends race."
    },
    "es-ES": {
      "title": "La carrera empatada",
      "text": "{butterfly:float loop} Preparados, listos, ¡ya! {fox:enter} {fox:hop} Zorro y {rabbit:enter} {rabbit:hop} Coneja echaron una carrera por el prado hasta la gran {flower:enter} flor rosa, donde esperaba una {butterfly:enter} mariposa. Zorro era rápido, como un {fox:shake 0.8} soplo de viento. Coneja era saltarina, como un {rabbit:hop x3} muelle. A mitad de camino, Zorro {fox:wobble x2} tropezó con su propia cola esponjosa y {fox:spin} rodó, pumba pumba pumba, hasta un montón de hojas crujientes. {sfx:leaves solo} Coneja se paró. Miró la flor. Miró a Zorro. Y entonces {rabbit:hop x2} volvió dando saltos hasta él y lo levantó de la pata. Cruzaron la meta {fox:hearts} {rabbit:hearts} juntos, y la flor {flower:pulse} asintió con su gran cabeza rosa. ¿Quién ganó? Los dos, dijo la flor. Así corren los mejores {fox:pulse} {rabbit:pulse} amigos."
    }
  },
  "sounds": {
    "leaves": { "prompt": "a small animal tumbling into a crunchy pile of dry leaves, soft rustle and crackle", "seconds": 1.8 }
  },
  "sound": [
    {
      "cue": "whoosh",
      "note": "a soft, comic wind whoosh"
    }
  ]
}
```

## Fields

| Field | Rules |
|---|---|
| `schema` | `1`. |
| `id` | Lowercase `a-z0-9-`, unique in the pack, **equal to the folder name**. Descriptive, not numbered. |
| `pack` | The pack's `id`. |
| `featured` | 0–4 sticker IDs the story is *about* (`requiredStickers`): the app prefers the story when all are on the canvas and may play it with one missing. 3–4 for most stories; **empty** for a "whole-forest" fallback story that works with any canvas. |
| `supporting` | 0–4 sticker IDs that make the story richer when present (`optionalStickers`). Disjoint from `featured`. |
| `tags` | 1–5 lowercase kebab-case mood/theme tags (`gentle`, `funny`, `bedtime`, `adventure`, `kindness`, `curiosity`, `seasons`, …). |
| `premise` | One sentence, for the roster and for reviewers. |
| `inspiration` | What classic structure or motif the story draws on and how it is transformed. Public-domain sources only; never a retelling. |
| `lesson` | One line, for reviewers. The story must never state it. |
| `learning` | Optional. The one small, true thing about the pack's world the story shows in passing ("Bees carry pollen from flower to flower"), for reviewers and the roster. About four stories in ten carry one (GUIDE "Learning"); the rest leave it empty or out. |
| `languages` | One entry per pack language, **all of them**. Each has `title` (≤ 6 words, parent-facing) and `text`. Each language is written natively, not translated word for word; the same beats carry the same cues. |
| `sounds` | Optional. The story's sound effects, by id: `prompt` describes the sound in plain words (concrete, "gentle rain tapping on big leaves"; for nature — wind, rain, water, birds — ask for the real thing, "realistic field recording", and keep "playful", "comic" and "cartoon" for comic sounds like a boing or a hiccup: "a playful breeze" and "a comic whoosh of wind" came back as a hum and a cartoon swoosh, not wind), `seconds` its length (0.5–30, default 2), `loop` true for an ambience bed. Cued in the text with `{sfx:id}` — see "Sound cues". |
| `sound` | The older hint form, still accepted: `cue` is a word in the text, `note` describes a sound played on it. Prefer `sounds` + `{sfx:…}`. |

## Text and length

- Narration read at a gentle pace runs ~130–150 words a minute. Target
  **80–140 words** per language (Spanish tends to run ~10 % longer for the
  same story); the validator rejects outside 65–160.
- Plain text: no Markdown, no stage directions, no emoji. Sound words
  (pitter-patter, whoosh, plic ploc) are welcome — they are what the cues
  and the sound effects hang on — but a real sound can also stand in for
  them (see "Sound cues").
- Punctuation is performance with Eleven v3: an ellipsis (…) is a beat of
  silence, a dash (—) a shorter one, ONE WORD IN CAPITALS is said louder,
  and short sentences read briskly. Use them; they are the most reliable
  pacing tools the model has (it does not support `<break>` tags).
- Cues and audio tags are not read aloud: step 2 strips the cues and hands
  the tags to the model as directions. Neither counts as a word.

## Cue grammar

A cue is `{sticker:effect}` with optional parameters separated by spaces:

```
{fox:wobble x3}          repeat 3 cycles
{bee:float loop 0.4}     loop until the story ends, intensity 0.4
{owl:tint #9AD0FF 1.2s}  colour and one-cycle duration in seconds
{bird:fade-out hold}     keep the end state
{fox:sparkle 0.9}        a bare number is intensity (0–1)
{fox:go to rabbit}       moves the fox beside the rabbit (see "Move cues")
{bear:live}              the bear's live action (see "Live cues"); {snail:live hold} … {snail:live resume}
{bear:face happy}        the bear's face from now on (see "Face cues")
{all:hop}                every sticker on the canvas (see "Everyone: all")
{fox:enter}              the fox enters here if not placed (see "Entrance cues")
```

- `sticker` is an ID from the manifest and must be in `featured` or
  `supporting` — or the reserved `all`. `effect` is one of the 12 names in `docs/effects/effects.json`
  (`effects`); which parameters each accepts is listed there (`repeat` is
  ignored by `fade-in`/`fade-out`, `color` only for `glow`/`tint`/`sparkle`
  and required by `tint`, `hold` only for the four that support it, a
  cycle `Ns` of 0.05–30 s).
- A cue fires on the **word that follows it**. Several cues in a row fire
  together on that word. Cues before the first word fire at the story's start
  (use this for scenery loops); a cue after the last word fires on the last
  word.
- Every story has at least one cue per language, and in practice a beat on
  most sentences: about one cue on the stickers (effects, faces, live
  animations) per 8–12 spoken words — the validator warns past 12. A
  `float` loop on butterflies, bees or birds at the start, a face change
  wherever a feeling changes and a reaction on each story beat is the
  usual shape.
- The same beats carry the same cues in every language.

### Sound cues

Sound effects use the reserved target `sfx` (a pack must not name a sticker
`sfx`) and refer to the story's `sounds` table:

```
{sfx:splash}              the sound plays under the next word
{sfx:splash solo}         the narration pauses; the sound plays instead
{sfx:rain-bed}            a sound with "loop": true starts an ambience bed
```

- `{sfx:id}` **under a word**: the narrator keeps reading and the sound
  colours the word it fires on — a whoosh as *whoosh* is said.
- `{sfx:id solo}` **instead of words**: the narrator stops for exactly the
  sound's `seconds` (plus a breath), the sound plays alone, then reading
  resumes. Put it **between sentences** (after a full stop; the validator
  warns otherwise), give it 1–3 s, and use at most two per story — a
  four-year-old's attention does not survive a long silence. The voice
  reads each stretch between solo sounds on its own, so leave at least a
  sentence or two (12+ words) on either side or its tone may shift.
- A sound with `"loop": true` is an **ambience bed**: from its cue it plays
  low under the narration for its `seconds`, faded in and out, ducked under
  the voice. Rain, wind, a stream, night crickets. One per story at most;
  it cannot play solo.
- The same sound id may be cued in several places. Every language should
  cue the same sounds on the same beats; the `sounds` table is shared.
- At most six sound effects per language (inline cues plus hints).

### Audio tags (the narrator's delivery)

Eleven v3 takes stage directions in square brackets, inline, right before
the words they colour. They are never read aloud and never count as words:

```
[whispers] Shhh, said Owl. Everyone is asleep.
[excited] Ready, steady, GO!
Snail took one step… [slowly] and then another.
[giggles] That tickles!
```

The allowed list (anything else is an error):

| Tag | Kind | Use |
|---|---|---|
| `[pause]` | delivery | a beat of silence (an ellipsis does the same) |
| `[whispers]` | delivery | a secret, a sleeping friend, a hush |
| `[softly]` | delivery | tender, close, bedtime |
| `[slowly]` | delivery | a snail, a sleepy voice, suspense |
| `[drawn out]` | delivery | stretches the next word (*sloooowly*) |
| `[rushed]` | delivery | hurry, excitement tumbling over itself |
| `[excited]` | emotion | big news, a game, a discovery |
| `[curious]` | emotion | a question, a peek, a wondering |
| `[happily]` | emotion | the warm ending, a reunion |
| `[surprised]` | emotion | a friend appears, a sneeze, a splash |
| `[sad]` | emotion | a small sorrow the story mends |
| `[laughs]` `[giggles]` | reaction | a good laugh; a small playful one |
| `[gasps]` | reaction | a surprise, a wonder |
| `[sighs]` `[exhales]` | reaction | relief, tiredness, calm |
| `[yawns]` `[sings]` | reaction, *experimental* | bedtime; a line sung — at most one per story |

- A tag colours what follows it until the delivery naturally changes; a
  reaction (`[giggles]`, `[gasps]`) is a sound the narrator makes at that
  point.
- **At most six per language**, one direction per spot (never
  `[excited] [whispers]`), and only where the words already carry the
  feeling — a tag on flat text reads as a tic, and an over-tagged script is
  what makes the model *say* a tag instead of performing it.
- Tags may differ between languages; the beats should still match.
- Step 2 keeps the tags for v3 and strips them if it ever has to fall back
  to the v2 model (which would read them aloud).

### Live cues

Every sticker carries a live action (`storycheck` lists each one with what
it shows, how long it plays and, for most, the pose it can pause on; the
pack's `anims/*.json` sidecars hold the same `description` and
`pause.shows`), brought alive with the reserved effect `live`:

```
Bear gave a {bear:live} great big yawn.          the whole action
{owl:live sleepy-blink}                          name one when a sticker has several
Snail {snail:live hold} hid in his shell…        up to the pause pose, and stay there
…then {snail:live resume} peeked out.            on from the pause pose to the end
```

- The sticker must be featured or supporting; `{sticker:live}` takes no
  parameters other than an animation id (needed only if the sticker has
  several) and `hold` or `resume`.
- It fires on the word that follows, like any cue. Whole, it plays for
  the action's length (2–4 s): cue it on the words that tell exactly that
  action, and start no other effect on that sticker until it ends.
- `hold` plays up to the action's pause pose (`hold:` in the listing —
  the snail hidden in its shell, the frog watching a fly) and stays there
  for as long as the story needs: a sentence, a page, or to the end. Cue
  it on the words that put the character in that pose; `resume` on the
  words that bring it out of it. A resume needs its hold first, and a
  held sticker takes no other live cue until it resumes (errors). Effects
  on a held sticker are fine; a face change waits until it resumes
  (warning).
- The words should match what the frames show, beat for beat: the
  narrator says "hid", the snail hides; says "peeked out", it peeks.
- At most five live actions per story and language (a hold and its
  resume count once; warning). The same beats carry the same live cues
  in every language.
- A sticker's **move** (its walk, hop, flight or sprout) is never cued:
  it plays by itself when the sticker enters (`{sticker:enter}`) or goes
  somewhere (`{sticker:go …}`), so the words around an entrance can say
  how it comes — hops in, flutters down, crawls up slowly. A sticker with
  more than one way to go comes in and goes its usual way unless the cue
  names another with `by` ("Move cues"). Leave a few words after an entrance before a
  live cue on the same sticker, so it has arrived.

### Move cues

A sticker that walks or flies (`storycheck -plan` lists who can move)
goes somewhere when the words say so, with the reserved effect `go`:

```
Fox {fox:go to rabbit} trotted over to Rabbit.     beside another character
Frog {frog:go to pond} hopped back to the pond.    to a place in the scene (a feature)
The bee {bee:go on flower} landed on the flower.   on top of another character
Mouse {mouse:go under mushroom} ducked under her cap.   under another character
Off {fox:go away} ran Fox, out of the meadow.      off the canvas
…and {fox:go back} back he came.                   back to its own spot
```

- Put it on the word that starts the movement; the move takes as long
  as the distance needs (1–5 s), so give it the words it happens in and
  keep other cues on that sticker until it arrives light (a face is fine).
- The mover and a target sticker must both be featured or supporting and
  on stage already: their `{x:enter}` comes earlier. A target place is
  one of the pack's features (`storycheck -plan` prints them).
- Only walkers and flyers move (never a flower or a mushroom); `go on`
  and `go under` shrink the mover to at most 65 % of the other sticker, so
  they suit a small one on or under a bigger one; several may share one
  (they stand side by side under it, overlapping a little).
- After `go away` a sticker is gone: cue nothing else on it until `go
  back` (a warning).
- **The way it goes must be the way the words say.** Some stickers get
  about more than one way (`storycheck -plan`, "ways to go": the ladybug
  crawls or flies, the bird flies or hops, the duckling waddles or swims,
  the firefly flies or walks). Without `by` they go their usual way (the
  first listed); when the words say the other, name it — on moves and
  entrances alike, and on each move (the next one is back to the usual
  way unless it names one too):

  ```
  Then she flew {ladybug:go on flower by fly} to the flower {ladybug:go back by fly} and back.
  Duckling {duckling:go to pond by swim} paddled across the pond.
  Along came {bird:enter by hop} Bird, hopping through the grass.
  ```

  Naming the usual way is a warning (drop the `by`); a way the sticker
  does not have is an error. If the words say a way the sticker has no
  move for (a fox that swims), change the words.
- The same beats carry the same moves in every language.

### Face cues

Stickers with expression variants (`stickers[].expressions` in the
manifest; `storycheck -plan` lists them) change face with the reserved
effect `face` and the expression's name:

```
Mouse {mouse:face sad} sighed.        from here on, the mouse looks sad
{mouse:face happy} Mouse smiled.      …until this
{all:face sleeping} Everyone slept.   every sticker on the canvas
{bear:face normal}                    the sticker's own face again
```

- No duration and no other parameters: a face stays until the next face
  cue for that sticker or `all`. The story's end resets every face.
- The expression must be one the sticker has, or `normal`; for `all`, one
  some sticker has (stickers without it keep their face).
- The validator warns when a story changes no face at all.

### Entrance cues

Every featured and supporting sticker marks its first mention with the
reserved effect `enter`:

```
Along came {fox:enter} Fox, hop, hop, hop.
{owl:enter} {owl:face sleeping} Owl was dozing on her branch.
```

- Exactly one per featured and supporting sticker in every language,
  right before the word that first names it and before any other cue on
  that word; never on `all`. Its only parameter is another way in than
  the usual one (`{ladybug:enter by fly} Ladybug flew in`, "Move cues"),
  when the words say so. The same stickers enter in every language (the
  words they sit on may differ), the same way.
- In play, a sticker the child has not placed comes into the scene on
  that word — hopping in, flying in or growing, as its manifest `stage`
  says (or the way `by` names) — and leaves when the story ends. For a
  placed sticker it does nothing.
- The validator errors on a missing, repeated or parameterised entrance
  and warns when the sticker is named before it (by its manifest name) or
  has a cue before it (a `loop` or a face before it is fine). Entrances
  do not count toward the cue density.
- `storyaudio` turns it into a trigger `{ "at", "cue", "sticker",
  "enter": true, "by"? }` (`docs/effects.md`, "Entrances").

### Everyone: `all`

The reserved target `all` means every sticker on the canvas: `{all:hop}`,
`{all:hearts}`, `{all:face happy}`. Any sticker effect or a face; not a
live animation. Use it on words about everyone ("everyone laughed", "they
all fell asleep"); it is how fallback stories reach whatever the child
placed.

### Canvas cues

Weather and light over the whole scene use the reserved target `canvas`
(a pack must not name a sticker `canvas`):

```
{canvas:rain}             default intensity and duration
{canvas:rain 0.8 14s}     intensity 0.8, stays on for 14 s (1–120 s)
{canvas:fog 0.4}          thin mist
{canvas:sunshine} {canvas:rainbow 10s}
```

- `effect` is one of the names in `docs/effects/effects.json` under
  `canvasEffects`: `fog`, `rain`, `sunshine`, `rainbow`, `night`, `snow`,
  `sunset`, `clouds`, `wind`, `fireflies`, `leaves`, `confetti`, `bubbles`
  (outdoors packs); `dimlight`, `windowlight`, `firelight`, `rainywindow`,
  `confetti`, `bubbles` (indoors packs); `confetti`, `bubbles`,
  `shootingstars`, `nebula`, `warp`, `comet` (space packs);
  and `bubbles`, `sunrays`, `ripples`, `deepwater`, `glowplankton`,
  `current`, `sandcloud` (underwater packs). The pack's
  `setting` in its manifest decides which are allowed; a `none` pack
  allows no canvas cues. Only an intensity and a duration (`Ns`) may
  follow — no `xN`, `loop`, `hold` or colour.
- A canvas cue fires on the word that follows it like any other, and the
  effect takes a moment to build up (fog ~2.5 s, rain ~1 s), so put it a
  beat before the words it illustrates. The duration is how long it stays,
  ramps included; it ends on its own.
- Canvas effects **follow the words**: whenever the text puts weather or
  light the setting can show into the scene (snow, rain, fog, sunset,
  night, clouds, wind, autumn leaves, fireflies, a party, bubbles,
  sunshine), cue it; never cue one the words don't mention. The validator
  warns when the text mentions one (by keyword, in each language) that is
  never cued, and past three per story.

## The roster (`plan.md`)

A cast table first — each sticker's pronoun, personality, live move and
what its art actually shows (colours and counted features, checked against
the sticker image) — then a table with one row per story: `id`, `featured`, `supporting`, `tags`,
`premise`, `inspiration`, `learning`, `canvas` and `live` (the stickers the
story brings alive, or `—`). Written before any story, checked with
`storycheck -plan`, and updated if stories change while writing. Coverage
rules the validator enforces on the finished set:

- every sticker in the pack is `featured` in at least 1 story (error) and in
  at least 5 (warning);
- at least 3 fallback stories (empty `featured`);
- no two stories with the same `featured` set *and* the same premise idea;
- about four stories in ten carry a `learning` fact (warning outside
  30–50 %);
- every sticker with a live animation, once featured enough, is brought
  alive in at least one story (warning; aim for three or more);
- 50 stories per pack.

`storycheck` also prints how many stories use each effect, each audio tag,
sound effects (and solo sounds), learning and each live sticker, so the set can be balanced
across the whole library rather than leaning on three names.
