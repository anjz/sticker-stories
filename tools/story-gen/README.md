# story-gen (stub)

Development-time pipeline that authors the pregenerated stories for a pack.
Not built yet — see `docs/roadmap.md` (iteration 2).

## Intended shape

- Input: a pack's theme, sticker list (IDs + names), and authoring guidelines
  (age band, tone, length ≈ 60–90 seconds spoken).
- Engine: Claude API (this tool never ships with the app; using dependencies
  and network access here is fine).
- Output: manifest-ready story JSON — `id`, `title`, `text`,
  `requiredStickers`, `optionalStickers`, `weight`, `tags` — for ~100 stories
  per pack, including several fallback stories (no required stickers).
- Coverage goal: every sticker appears as `requiredStickers` in multiple
  stories; common 2–3 sticker combinations get dedicated stories.
- Every batch must pass `packager validate` before audio rendering (`../tts`).

Until this exists, placeholder stories are hand-written in
`packs/<id>/manifest.json` and narrated by `../placeholdergen`.
