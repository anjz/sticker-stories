# Asset delivery — narration per language

Story narration is the part of a pack that grows with every language: the
Forest pack's art is ~48 MB in any language, its narration ~29 MB **per
language**. So narration is not in the app: each language of each pack is
an **Apple-hosted Background Assets asset pack** (iOS 27+), and a device
only downloads the languages it uses. Hosting is part of the Developer
Program (up to 200 GB); the downloads come from Apple through a system
framework — no server of ours, no third party (`docs/compliance.md`).

## What is where

| | Where | Why |
|---|---|---|
| The app, every bundled pack's manifest, art, stickers, animations | the app | the same in every language |
| Every language's **effect sidecars** (`audio/<lang>/<id>.effects.json`, ~0.4 MB a pack) | the app | tiny; story selection reads them |
| Each language's **narration** (`audio/<lang>/<id>.m4a`) | one asset pack per pack × language | what a language costs |

A pack's manifest names, per language, the asset pack that carries its
narration (`narrationPacks`, `docs/pack-format.md`):
`forest-narration-es-ca0747c8` — the pack, the language it is tagged with,
and a hash of the audio. **A new recording is a new asset pack**, so an app
version only ever reads the narration its own manifest names, timed to the
effect sidecars that ship beside it; an older app keeps its older packs.
Inside an asset pack each file sits at `<asset pack id>/<audio path>`
(`forest-narration-es-ca0747c8/audio/es-ES/bird-wakes-the-sun.m4a`), so two
recordings of a language on a device at once never share a path.

Each narration asset pack is **localized** (`language`: the primary subtag,
`en`, `es` — a region only when two of a pack's languages share a subtag)
and, for a pack that ships with the app, **essential** on first install and
on every update. The system then downloads, with the app, only the
language that best matches the user's preferred languages — falling back to
the app's primary language, English, when none matches — so a child's
first story plays offline in their language.

## Choosing the language

`LanguageResolver` (the parent's override in Settings, else the device's
preferred languages; exact tag, then primary subtag, then English) picks
the language, as before. The system picks its own at install and on
updates from the device's languages (or the app's language in iOS
Settings), and the app fetches the family's at launch when it is missing:
after the device language changed, or after an update re-recorded a
language the parent chose in Settings (the system brought the device's,
which plays until the chosen one arrives).

The parent's override is **not** mirrored into
`AssetPackManager.shared.resolvedLanguage`: setting it sets the app's own
preferred language (`AppleLanguages` in its defaults, the language iOS
Settings shows for the app), which hides the device's languages from
`Locale.preferredLanguages` — "System language" would then mean the last
language a parent picked.

## Switching language

Switching happens in Settings, behind the parental gate:

1. the new language is saved;
2. its narration packs — for every pack the family has — are requested in
   one batch (`ensureLocalAvailability(of:)` with a set);
3. Settings shows each language's state under its row, from
   `statusUpdates`: *on this device*, *downloading 45 %* (a progress
   ring), *not downloaded* (with its size), or *waiting to download* after
   a failure (the system retries).

`reconcilePreferredLanguages()` is **not** used: it would remove every
other language at once, and the previous one is what plays until the new
one has arrived.

## Playing while a language downloads

Per pack, the story plays in the chosen language when its narration is on
the device (`assetPackIsAvailableLocally(withID:)`); otherwise in the most
recently used language that is (`NarrationPlanner`, unit-tested in the
Kit). The story's title in the pill follows the
language it plays in, and a small **non-blocking banner** tells the parent
("Spanish stories are still downloading — playing in English for now"): a
four-year-old can't read a modal, and it would stand between them and the
story. If no language of a pack is on the device yet (an essential download
still arriving), its stories wait; nothing is downloaded from a child's
screen.

## Keeping languages

The system never removes an asset pack by itself; the app decides:

- the current language is always kept;
- until it is fully on the device, every language that is stays (one of them
  is playing);
- then the previous language is kept too when the device has room to
  spare (5 GB free for important use), so switching back needs no network,
  and removed otherwise; older languages are removed;
- at launch, narration packs no manifest names any more (a recording an app
  update replaced) are removed.

## Purchased packs (designed, not built: v1 ships only Forest)

A pack sold later is a **base asset pack** (manifest, art, stickers,
animations, sidecars) plus one narration pack per language, all
**on-demand**. After a purchase or a restore (grown-up screens), and at
launch when the entitlement check finds a pack owned but missing (a
reinstall), the app downloads its base pack and its narration in the
current language; a language switch downloads that language for every
owned pack in the same batch. Apple does not tie asset packs to purchases:
the app only asks for the packs its entitlements allow, and a revoked
purchase removes them (`docs/commerce.md`).

## Building and testing

- `storyaudio install` writes `narrationPacks`; `packager validate` fails
  when an ID no longer matches its audio.
- `packager assetpacks ../packs/forest` writes each narration pack's
  manifest and builds its archive with `xcrun ba-package` into
  `build/assetpacks/` (`-policy onDemand` for a pack sold later).
- Upload the archives to App Store Connect with the build whose manifest
  names them; the packs go through App Review with it.
- While debugging on a device, set the Run scheme's *Options → Background
  Asset Packs* folder to `build/assetpacks` and Xcode serves them (Xcode
  27+). `xcrun ba-serve` is the stand-alone mock server.
- Debug builds also carry the narration inside the pack, read only when no
  asset pack has it, so simulator runs (`-autoplay`) work offline;
  `-narrationFromAssetPacksOnly` ignores it to exercise downloads. Release
  builds leave it out (a build phase deletes the pack's `.m4a` files).
- In the simulator, and on a device without Xcode serving them, the
  download fails (Apple's hosting has no packs for an unpublished app):
  Settings shows *waiting to download*. To see the fallback banner, delete
  one language's `.m4a` files from the installed app and launch with
  `-autoplay -settings.languageOverride <that language>`.
