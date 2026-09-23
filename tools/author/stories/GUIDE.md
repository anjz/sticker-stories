# Authoring brief

Read this before writing a single story. It is the standard every story is
held to, and the validator (`storycheck`) enforces the parts that can be
checked mechanically.

## What these stories are

Sticker Stories is an app for children aged four and up. A child drags
stickers onto a scene and presses play; the app picks a story that matches
what they placed and narrates it while the stickers react with small
effects (a wobble, a hop, sparkles), some stickers come alive for a moment
in their own animation (the bear cub yawns, the frog backflips) and, now and
then, the weather or the light changes over the whole scene (rain, fog, sunshine, a rainbow, night
falling, the lights going low). Stories are:

- **30–60 seconds** of narration (80–140 words per language), read by an
  Eleven v3 voice that takes stage directions and plays real sound
  effects — you write those in too (see "Voice performance" and "Sound
  effects");
- **bilingual from day one** (currently en-US and es-ES), each language
  written natively;
- **self-contained**: no series, no cliffhangers, no "next time";
- **played many times**: the same child will hear a story dozens of times,
  so it must reward repetition (rhythm, a callback, a line the child will
  say along) and never grate.

## Quality bar

Write at the level of the best read-aloud picture books, not app filler.
Every story must have:

1. **A real shape.** Setup → a small, concrete problem or wish → an attempt
   → a surprise or turn → a warm resolution. In 100 words. If nothing turns,
   it is not a story yet.
2. **One idea, held all the way through.** A story about the shy mushroom
   is about shyness from the first line to the last.
3. **Depth borrowed from the classics, transformed.** Draw on public-domain
   structures and motifs — Aesop and La Fontaine, Grimm and Perrault's
   gentlest tales, Kipling's *Just So* "how the X got its Y", Andersen's
   kindness stories, folk-tale patterns (three tries, the smallest helps
   the biggest, the boast undone) — and *turn* them: a different ending, a
   different lesson, a twist a four-year-old can feel. Name the source in
   `inspiration`. Never retell; never use a character or line that belongs
   to someone (no Pooh, no Peter Rabbit, no Disney).
4. **A lesson that is never said.** Kindness, courage, patience, curiosity,
   sharing, being small and still mattering — shown by what happens, not
   stated. No "and so she learned that…". Put the lesson in the `lesson`
   field for reviewers and keep it out of the text.
5. **Read-aloud craft.** Short sentences. Present-tense action or simple
   past. Concrete nouns and verbs. Rhythm and repetition (three of
   something; a refrain). Sound words that a narrator can perform (*drip
   drop*, *rustle rustle*, *whoo-hoo*). A question to the listener now and
   then. An ending line that lands — quiet, funny or warm — and would work
   as the last line a parent reads at bedtime.
6. **Warmth and humour.** Gentle, physical, kind humour (a tumble into
   leaves, a hedgehog covered in leaves, a snail's grand expedition).
   Never mockery.
7. **Variety across the set.** Mix moods (`gentle`, `funny`, `bedtime`,
   `adventure`, `curiosity`, `kindness`, `seasons`, `weather`, `music`,
   `counting`, `learning`…), times of day, weather, and story shapes. No
   two stories with the same premise. Every sticker gets to be the hero
   somewhere, not only a sidekick.

## Learning (about four stories in ten)

Roughly 40 % of a pack's stories carry **one small, true thing about how
the pack's world works**, shown in passing. In a forest: bees carry pollen
from flower to flower and that is how fruit begins; owls see at night and
sleep by day; a snail carries its house and leaves a silver trail; leaves
turn colour and fall in autumn; mushrooms grow after rain; a squirrel
buries acorns and forgets some, and those become trees; birds build nests
from twigs; a hedgehog rolls into a ball; rain fills puddles and the sun
dries them. Aim for the wonder a four-year-old feels at a real fact.

- **One fact per story, concrete and observable**, something the child
  could notice outside. No numbers, no big words, no "did you know".
- **The story stays a story.** The fact is what a character does or finds
  out on the way to the turn, never a lesson read out; if the plot would
  survive deleting the fact, it is bolted on.
- **True.** Gentle simplification is fine; a cute falsehood is not.
- Put the fact in the `learning` field so reviewers and the roster can see
  it, add the `learning` tag, and keep the other six stories in ten free of
  it — a set that teaches in every story stops feeling like stories.
  `storycheck` warns outside 30–50 %.

## Safety — absolute rules

Kids Category. The app is used unsupervised by four-year-olds. If in doubt,
cut it.

- **Nothing scary.** No predators hunting, no being chased, no getting
  lost without an immediate friendly resolution, no darkness as threat, no
  storms as danger, no monsters, ghosts, witches, wolves at the door.
- **No harm.** No death, injury, illness, blood, weapons, fighting,
  violence, cruelty, or characters being left out or laughed at without a
  mend inside the story.
- **No fear as a device.** Surprise, yes; fright, never. A "surprise" is a
  friend appearing, not a jump scare.
- **No romance, no bodies, no bathroom humour.**
- **No brands, products, screens, money, religion, politics, holidays
  tied to one faith.**
- **No insults**, even mild (*stupid*, *dumb*, *ugly*, *fat*, *shut up*).
- **Inclusive by default.** Animals are *he*, *she* or *they* in a
  balanced mix; no gendered roles; nobody is "the pretty one".
- **Emotionally safe endings.** Every story ends with everyone safe, warm,
  included, and calm enough for a bedtime listener.

The validator rejects a list of forbidden words in both languages. Passing
it is necessary, not sufficient: the rules above are the standard.

## Using the sticker pack

- Read the manifest: sticker IDs and their names in each language are the
  cast. Use each sticker as what it is (a snail is slow, a bee buzzes, a
  tree stands still and shelters) and give each one a personality that
  stays consistent across the pack.
- A story is centred on **3–4 featured stickers** (the app prefers it when
  all of them are on the canvas and may still play it with one missing) and
  may use up to 4 **supporting** ones (present or not; the story must read
  fine without them — never make a beat depend on a supporting sticker).
- Write **at least 3 fallback stories** with no featured stickers: they
  are about the place itself (the forest waking up, the evening, the wind)
  and must work with an empty canvas.
- Do not mention stickers that are neither featured nor supporting.
- Only refer to what a sticker *is*; never to its position on the screen.

## Using sticker effects

The app has exactly 12 sticker effects (`docs/effects/effects.json`,
`effects`; human reference in `docs/effects.md`) — read the catalogue, not
this list, for what each means and accepts:

| Effect | Cue it on |
|---|---|
| `pulse` | the sticker being introduced or talked about ("look at this one") |
| `wobble` | a reaction: surprise, a laugh, a sneeze, being bumped |
| `shake` | shivering, nerves, giggling, buzzing |
| `hop` | joy, a jump, hello; `x2`–`x3` for bouncing |
| `spin` | a twirl, dizziness, a tumble |
| `float` | anything airborne or afloat; `loop` at the start for quiet life |
| `fade-in` / `fade-out` | arriving / leaving, waking / falling asleep; `hold` to stay gone |
| `glow` | magic, warmth, a wish, the sun on something |
| `tint #RRGGBB` | blushing (pink), cold (blue), cross (red); colour required |
| `sparkle` | delight, magic, treasure, a good idea |
| `hearts` | friendship, a hug, kindness |

Cue grammar is in `FORMAT.md`.

- **Effects illustrate the words.** Put a cue on the beat it belongs to:
  `hop` on *jump*, `wobble` on *sneeze*, `sparkle` on *magic*, `spin` on
  *tumble*, `tint #…` on *blushed*, `fade-out hold` on *flew away*,
  `hearts` on a hug.
- **A float loop at the start** on anything airborne gives the canvas life
  for the whole story: `{butterfly:float loop}`, `{bee:float loop 0.4}`.
  Keep loops at low intensity (≤ 0.5). Trees and flowers do not move on
  their own; give them a `wobble` or `pulse` on a beat instead.
- **At least one cue per language, typically two to eight.** More than
  one sticker can react at once; cues in a row fire together.
- **Use the whole library across the set, not the same three names.**
  `storycheck` prints how many stories use each effect; if `hop`, `pulse`
  and `wobble` carry everything while `glow`, `tint`, `spin`, `fade-in` sit
  unused, look for the beats that want them. Never force one in.
- **Never rely on an effect.** The sticker may not be on the canvas and
  the story must still make sense.
- **Restraint.** Prefer defaults. One effect per beat, on the sticker the
  sentence is about. Never more than three flashes (white `tint`) in a
  second.
- Cue only featured and supporting stickers.

## Live stickers

Some stickers carry a **live animation**: a few seconds of their own
frames, drawn from the sticker's art — the bear cub yawns and stretches,
the frog does a backflip and catches a fly, the raccoon plays peekaboo.
Each is one fixed action; you cannot change what it does, only *when* it
happens. `storycheck` lists every one — the sticker, what the animation
shows and how long it plays (3–6 s) — and each sidecar in
`packs/<pack>/anims/*.json` carries the same `description`. Read them
before planning the roster: they are the cast's signature moves.

- **Write the moment, then cue it.** `{bear:live}` goes on the words that
  tell exactly what the animation shows: *Bear gave a {bear:live} great big
  yawn, stretched up high and rubbed his eyes.* Never on words it
  contradicts — no backflip cued on "the frog sat very still", no yawn on
  "the bear jumped". A child sees the sticker do what the narrator says.
- **Let the words cover its length.** The animation runs 3–6 s, about
  8–14 spoken words at a gentle pace. Give it the sentence it belongs to
  and the next one, and cue nothing else on that sticker until it is done
  (`storyaudio` warns when a sticker effect starts on top of it). Other
  stickers may react meanwhile.
- **A signature, not a tic.** At most two live animations in a story, each
  sticker once (the validator warns past that). Across the set, every
  animated sticker should come alive in **at least three stories** —
  mostly ones where it is featured and the premise grows from its move (a
  peekaboo game for the raccoon, a nap for the hedgehog, a tapping
  rhythm for the woodpecker) — but not in every story it appears in.
- **Mostly on featured stickers.** A supporting sticker may come alive
  too, but the story must read fine if it is not on the canvas.
- **Never rely on it.** The sticker may be missing, and under Reduce
  Motion or calm mode the animation does not play: the words alone must
  tell the moment.
- A live animation takes no parameters: `{frog:live}`. If a sticker ever
  has several, name one: `{owl:live sleepy-blink}`.

## Using canvas effects

Canvas effects change the whole scene — the weather or the light — rather
than one sticker (`docs/effects/effects.json`, `canvasEffects`). Which ones
a pack may use is decided by its **`setting`** in `manifest.json`:

| Setting | Canvas effects available | Cue it on |
|---|---|---|
| `outdoors` | `fog` (early morning, hush, something hidden), `rain` (pitter-patter, puddles, sheltering), `sunshine` (the sun comes out, a warm afternoon), `rainbow` (the wonder after rain, a wish come true), `night` (evening, the moon coming up, settling to sleep; never darkness as a threat), `snow` (winter, a snow day, the first flakes, a hush), `sunset` (the end of the day, going home; before night for a gentle bedtime), `clouds` (a cloudy day, a cloud shaped like something, the grey before rain), `wind` (a windy day, a kite, something blown away, a whoosh), `fireflies` (a summer evening, a little magic in the dark; over night or sunset), `leaves` (autumn, a gust in the trees, a leaf pile; only where there are trees), `confetti` (a birthday, a party, a hooray, a happy ending), `bubbles` (bath time, blowing bubbles, a party; under the sea, something bubbling up) | the sentence where the weather or the light changes |
| `indoors` | `dimlight` (bedtime, a lamp turned low, a whispered secret; never darkness as a threat), `windowlight` (morning, waking up, a lazy sunny afternoon), `firelight` (a fireplace, birthday candles, a cosy evening; never a fire as a danger), `rainywindow` (a rainy day indoors, waiting for the rain to stop), `confetti` (a birthday, a party, a hooray, a happy ending), `bubbles` (bath time, blowing bubbles, a party; under the sea, something bubbling up) | the sentence where the light changes |
| `space` | `confetti` (a birthday, a party, a hooray, a happy ending), `bubbles` (bath time, blowing bubbles, a party; under the sea, something bubbling up), `shootingstars` (making a wish, wonder, look!), `nebula` (a magical place, wonder, a dreamy moment), `warp` (blast-off, zooming to a new planet, whoosh), `comet` (a visitor, following something, a slow wonder) | the sentence where something appears or changes in the sky |
| `underwater` | `bubbles` (bath time, blowing bubbles, a party; under the sea, something bubbling up), `sunrays` (a bright day under the sea, swimming up towards the light), `ripples` (shallow water, a sunny lagoon, calm and playful), `deepwater` (diving deeper, exploring, bedtime under the sea; never darkness as a threat), `glowplankton` (a little magic in the dark sea; over deepwater), `current` (swimming along, being carried away, a whoosh), `sandcloud` (something stirs, hide and seek, digging in the sand) | the sentence where the water or the light changes |
| `none` | nothing — the pack's stories use sticker effects only | — |

Grammar: `{canvas:rain}`, `{canvas:rain 0.8 14s}` (intensity, then how long
it stays). See `FORMAT.md`, "Canvas cues".

- **Occasional, never routine.** A canvas effect is a big moment; a pack
  where every story rains is a pack where rain means nothing. Most stories
  have none. Use one — at most two — only in a story whose weather or
  light genuinely changes, in well under half of the set (the validator
  warns past 40 %), and vary which: not every outdoors story that uses one
  should use rain.
- **The story leads, the effect follows.** Write the rain into the words
  (*plip, plop; pitter-patter*) and cue `{canvas:rain}` a beat before them:
  it takes a moment to build up (fog longest). Let the duration cover the
  beats it belongs to and no more; it clears on its own.
- **Classic shapes** that earn one: rain → sunshine → rainbow as a story
  resolves; fog that lifts as something is found; sunshine as the forest
  wakes; night or dimlight as the story settles to sleep.
- **Stickers still react.** A canvas effect is never a substitute for the
  cast doing something; a story with only canvas cues is a warning.
- **Never rely on it.** The story must read fine if the weather never
  came (calm mode damps it; an older app skips it).

## Voice performance

The narrator is an Eleven v3 voice: it acts what you write, and it takes
stage directions in square brackets (FORMAT.md, "Audio tags"). Use them the
way a good reader marks up a picture book:

- **Punctuation first.** An ellipsis (…) is a held breath, a dash (—) a
  snag, a short sentence a quick step, ONE WORD IN CAPITALS a shout. This
  is the most reliable control there is — write the rhythm into the text
  before reaching for a tag.
- **A tag where the feeling changes**, right before the words it colours:
  `[whispers]` for a secret or a sleeping friend, `[excited]` when the game
  starts, `[curious]` for a peek, `[softly]` as the story settles,
  `[slowly]` / `[drawn out]` for a snail or a *sloooow* word, `[happily]`
  for the ending. Reactions are sounds the narrator makes: `[giggles]`,
  `[gasps]`, `[sighs]`, `[laughs]`, `[yawns]` (bedtime, experimental).
- **Few and true.** Two to five per story is plenty, six is the limit, one
  direction per spot (never `[excited] [whispers]`), and only where the
  words already carry the feeling. Over-tagged text is what makes the
  model read a tag aloud instead of performing it.
- **The same beats, not the same tags.** Each language gets the tags its
  own phrasing wants.
- The narration is read in one go unless a solo sound splits it (below), so
  the voice stays consistent; the tool keeps a natural stability and
  handles the rest.

## Sound effects

Real sounds are generated from your descriptions and mixed into the
narration (FORMAT.md, "Sound cues"). Three ways to use them:

- **Instead of the word — `{sfx:id solo}`.** The narrator stops, the sound
  plays, the narrator goes on. *The rain was loud on the leaves.
  {sfx:rain solo} Everyone squeezed under the mushroom.* — the rain itself
  says "tap, tap". Use it when a real sound tells it better than the word:
  rain, a splash, a knock, a sneeze, a rustle of leaves, a distant owl.
  Between sentences, 1–3 s, at most two per story.
- **Under the word — `{sfx:id}`.** The narrator says *whoosh* and a whoosh
  plays. For the sound words a child loves to say along with (and will):
  keep those in the text and let the sound double them.
- **Ambience — a sound with `"loop": true`.** Rain, wind, a stream, night
  crickets: a soft bed under the whole scene from its cue, at most one per
  story. Pairs naturally with a canvas effect (rain with `{canvas:rain}`).

Keep the balance: **not every sound word becomes a sound effect** — the
rhythm of *pitter-patter, pitter-patter* read aloud is part of the craft,
and a story that stops every other line for a sound is a story that stops.
Two or three sounds is typical, six the limit. Write prompts as a sound
designer would brief a foley artist: concrete, one sound, its character
("a small animal tumbling into a crunchy pile of dry leaves, soft rustle
and crackle"); the tool adds "gentle, for a children's story, no music,
no voices". Never a scary sound: no roars, growls, thunder claps, bangs.

## Both languages

- Write each language as a native author would: idiom, rhythm, sound
  words (*whoosh* / *fiu*, *pitter-patter* / *tip-tap*), names of things.
  Not a translation.
- Spanish is Castilian (es-ES), *vosotros* where a plural "you" appears,
  child-friendly vocabulary.
- Same beats, same cues, same lesson. Titles may differ in wording.

## Process discipline

- Plan the roster first (including which stories bring which live
  stickers alive); write in batches of five; validate after every batch;
  fix before continuing.
- Reread each story aloud in your head as a parent at bedtime. If you
  would skip a line, cut it.
