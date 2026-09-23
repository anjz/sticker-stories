# Story format (intermediate, schema 1)

One folder per story, `tools/author/stories/<packID>/<storyID>/story.json`.
This is the authoring format: human-readable, bilingual, with everything
that happens around the words inline in the text — effect cues (sticker,
canvas, sound) in curly braces and the narrator's delivery (Eleven v3 audio
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
    "tree",
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
      "text": "[excited] {butterfly:float loop} Ready, steady, {fox:hop} {rabbit:hop} go! Fox and Rabbit raced across the meadow to the big pink flower. Fox was fast, like a {fox:shake 0.8} whoosh of wind. Rabbit was bouncy, like a {rabbit:hop x3} spring. Halfway there, Fox {fox:wobble x2} tripped over his own fluffy tail and {fox:spin} rolled, tumble tumble tumble, into a crunchy pile of leaves. {sfx:leaves solo} Rabbit stopped. She looked at the flower. She looked at Fox. Then she {rabbit:hop x2} hopped all the way back and pulled him up by the paw. They crossed the finish line {fox:hearts} {rabbit:hearts} together, and the flower {flower:pulse} nodded her big pink head. Who won? Both of them, said the flower. That is how best {fox:pulse} {rabbit:pulse} friends race."
    },
    "es-ES": {
      "title": "La carrera empatada",
      "text": "{butterfly:float loop} Preparados, listos, {fox:hop} {rabbit:hop} ¡ya! Zorro y Coneja echaron una carrera por el prado hasta la gran flor rosa. Zorro era rápido, como un {fox:shake 0.8} soplo de viento. Coneja era saltarina, como un {rabbit:hop x3} muelle. A mitad de camino, Zorro {fox:wobble x2} tropezó con su propia cola esponjosa y {fox:spin} rodó, pumba pumba pumba, hasta un montón de hojas crujientes. {sfx:leaves solo} Coneja se paró. Miró la flor. Miró a Zorro. Y entonces {rabbit:hop x2} volvió dando saltos hasta él y lo levantó de la pata. Cruzaron la meta {fox:hearts} {rabbit:hearts} juntos, y la flor {flower:pulse} asintió con su gran cabeza rosa. ¿Quién ganó? Los dos, dijo la flor. Así corren los mejores {fox:pulse} {rabbit:pulse} amigos."
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
| `sounds` | Optional. The story's sound effects, by id: `prompt` describes the sound in plain words (concrete, "gentle rain tapping on big leaves"), `seconds` its length (0.5–30, default 2), `loop` true for an ambience bed. Cued in the text with `{sfx:id}` — see "Sound cues". |
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
```

- `sticker` is an ID from the manifest and must be in `featured` or
  `supporting`. `effect` is one of the 12 names in `docs/effects/effects.json`
  (`effects`); which parameters each accepts is listed there (`repeat` is
  ignored by `fade-in`/`fade-out`, `color` only for `glow`/`tint`/`sparkle`
  and required by `tint`, `hold` only for the four that support it, a
  cycle `Ns` of 0.05–30 s).
- A cue fires on the **word that follows it**. Several cues in a row fire
  together on that word. Cues before the first word fire at the story's start
  (use this for scenery loops); a cue after the last word fires on the last
  word.
- Every story has at least one cue per language. Two to eight is typical;
  a `float` loop on butterflies, bees or birds at the start plus a cue on
  each story beat is the usual shape.
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
  `sunset`, `clouds`, `wind`, `fireflies`, `leaves` (outdoors packs); and
  `dimlight`, `windowlight`, `firelight`, `rainywindow` (indoors packs).
  The pack's `setting` in its manifest decides which are allowed; a `none`
  pack allows no canvas cues. Only an intensity and a duration (`Ns`) may
  follow — no `xN`, `loop`, `hold` or colour.
- A canvas cue fires on the word that follows it like any other, and the
  effect takes a moment to build up (fog ~2.5 s, rain ~1 s), so put it a
  beat before the words it illustrates. The duration is how long it stays,
  ramps included; it ends on its own.
- Canvas effects are **occasional**: at most one or two per story, only
  when the story's weather or light genuinely changes, and in well under
  half of a pack's stories. The validator warns past two per story and past
  40 % of the set.

## The roster (`plan.md`)

A table with one row per story: `id`, `featured`, `supporting`, `tags`,
`premise`, `inspiration`. Written before any story, checked with
`storycheck -plan`, and updated if stories change while writing. Coverage
rules the validator enforces on the finished set:

- every sticker in the pack is `featured` in at least 1 story (error) and in
  at least 5 (warning);
- at least 3 fallback stories (empty `featured`);
- no two stories with the same `featured` set *and* the same premise idea;
- canvas effects in well under half of the stories (warning past 40 %);
- about four stories in ten carry a `learning` fact (warning outside
  30–50 %);
- 50 stories per pack.

`storycheck` also prints how many stories use each effect, each audio tag,
sound effects (and solo sounds) and learning, so the set can be balanced
across the whole library rather than leaning on three names.
