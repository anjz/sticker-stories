# Writing a pack's other languages

A pack is written and reviewed in **English only** (`en-US`). Once the user
has approved it, its stories are **transcreated** from the English into
each of the app's other languages:

| tag | language | narration | quotes |
|---|---|---|---|
| `es-ES` | Spanish (Spain) | Spanish | «…» |
| `de-DE` | German (Germany) | German | „…“ |
| `fr-FR` | French (France) | French | «…» |
| `it-IT` | Italian (Italy) | Italian | «…» |
| `ja-JP` | Japanese | Japanese | 「…」 |
| `zh-TW` | Chinese, Taiwan (Traditional) | Mandarin | 「…」 |
| `zh-HK` | Chinese, Hong Kong (Traditional) | Cantonese | 「…」 |

Read `GUIDE.md` (audience, safety, tone) and `FORMAT.md` (the cue syntax)
first, then the pack's `scene.md`. This file only adds what is different
when the story already exists in English.

## Transcreation, not translation

Write each story as a native author of the language would have written it
for a child of the pack's age, from the English story's **beats**: the same
events in the same order, the same characters on stage, the same facts (a
story's `learning` stays true), the same joke or surprise. Everything else
is yours to rephrase: sentence shapes, rhythm, rhymes and refrains (make
new ones that work in the language rather than keep a broken English one),
sound words (German *platsch*, French *plouf*, Italian *splash*, Japanese
*ぴょん*, *ざぶーん*, Chinese *撲通*), idioms, and small cultural details —
a song, a game, a food, a counting rhyme, a name for a sweet — adapted to
what a child of that language knows. Never add or drop a beat, a character
or a fact. A parent who reads both versions should find the same story,
told well twice.

The Spanish (`es-ES`) is a sister transcreation made the same way: look at
it to see how freely a beat can be retold.

## What must match the English

- **Every cue, on the same beat.** The same stickers, effects, parameters,
  moves (`go to …`, `by …`), live actions (`hold`/`resume` pairs), faces,
  `{all:…}` cues, canvas effects and stops, sounds (`{sfx:id}`, the same
  ids: they are shared), entrances and `{x:says}` lines (same speakers),
  in the same order. Put each cue right before the word in *your*
  sentence that carries that beat — not at the same word position.
- **Entrances on the first mention.** `{x:enter}` goes right before the
  first word that names the sticker. Name it the first time with its name
  in this language exactly as `author/art/<pack>/art.json` gives it
  (`"name"`, your language): that is how the checker finds it. Afterwards
  use pronouns or other words freely.
- **Places by their words.** When a sentence puts a character in a place
  of the scene, use one of that place's `words` in your language (in
  `art.json`, `scene.features`), and keep the move cue that takes it there.
- **Length by narration time**, within about 10 % of the English (the
  checker counts it: words, or for Japanese and Chinese, characters).
- **Audio tags** (`[excited]`, `[whispers]`, …) stay in English, as in
  FORMAT.md; place them where your sentences need them, at most six.
- **Character names** of people stay: Lola is Lola, Nico is Nico, written
  in your script (ローラ, ニコ; 蘿拉, 尼可).

## Per language

- **German** — warm, simple Präteritum narration with direct speech in
  „…“; *du* between characters. Nouns as names: "der Fuchs", "das Reh" —
  the checker ignores the article. Avoid long compound nouns a child
  cannot follow.
- **French** — passé composé and imparfait (the passé simple sounds like
  a book for older readers); «…» quotes with spaces inside
  (`« Bonjour ! »`); *tu* between characters.
- **Italian** — passato prossimo and imperfetto (or passato remoto only if
  it reads naturally for a fairy-tale opening); «…» quotes.
- **Japanese** — picture-book です・ます narration, mostly hiragana with
  the simple kanji a child sees in books; animal names in katakana as
  given. Rich onomatopoeia. Cues sit inside the text with no spaces
  around them (`キツネは{fox:live jump}ジャンプしました。`). A quoted line
  is 「…」; after its closing 」, leave a space before the narration
  runs on (`{fox:says} 「やった！」 とキツネ。`). About 250–375 characters.
- **Chinese (Taiwan)** — Traditional characters, Taiwan Mandarin words
  (腳踏車, 冰淇淋, 好棒), full-width punctuation, 「…」 quotes with the
  same space rule as Japanese. Narration read in Mandarin. About 200–300
  characters.
- **Chinese (Hong Kong)** — Traditional characters, Hong Kong words (雪糕,
  單車, 士多啤梨), read aloud in **Cantonese**: the narration in written
  Chinese that sounds natural read in Cantonese, the characters' quoted
  lines in natural spoken Cantonese (佢、係、唔、咗、啲、嘅、喺、嘩). Not a
  copy of the Taiwan text: write it for a Hong Kong child. About 200–300
  characters.

## Titles

At most six words' worth (about 15 Japanese or 12 Chinese characters),
natural for the language: a parent sees it in the app.

## Files and checking

Write each story's language to `<story>/i18n/<lang>.json`:

```json
{ "title": "…", "text": "…" }
```

Never edit `story.json` (several languages are written at once; they are
merged in when the language is recorded). Check with:

```sh
cd tools && go run ./author/storycheck -pack ../packs/<pack> -lang <lang>
```

No errors may remain. Fix every warning that points at a real problem — a
name mentioned before its entrance, a place named with no move to it, a
length off target, a cue shape that differs from the English.

## Pack names

| | Forest | Beach |
|---|---|---|
| de-DE | Waldfreunde — Kuschelige Waldfreunde und ihre Abenteuer. | Strand — Ein Tag am Strand: Gezeitentümpel, Boote, Drachen und Sandburgen. |
| fr-FR | Les amis de la forêt — De petits amis des bois et leurs aventures. | La plage — Une journée à la plage : flaques, bateaux, cerfs-volants et châteaux de sable. |
| it-IT | Amici del bosco — Teneri amici del bosco e le loro avventure. | La spiaggia — Una giornata al mare: pozze, barche, aquiloni e castelli di sabbia. |
| ja-JP | もりのなかまたち — 森のなかよしたちと、そのぼうけん。 | うみべ — うみべの一日：潮だまり、ボート、たこあげ、砂のお城。 |
| zh-TW | 森林好朋友 — 可愛的森林小動物和牠們的冒險。 | 海灘 — 海灘的一天：潮池、小船、風箏和沙堡。 |
| zh-HK | 森林好朋友 — 可愛的森林小動物和牠們的歷險。 | 沙灘 — 沙灘的一天：石池、小船、風箏和沙堡。 |

(`displayName` — `description` in the manifest, added with the language.)
