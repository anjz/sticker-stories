# Kids Category compliance

The app targets Apple's Kids Category (age band **5 and under**). We take the
strictest reading of guideline 1.3 (Kids Category), 5.1.4 (Kids' privacy),
COPPA, and GDPR-K. Compliance shapes architecture: it is not a checklist to
pass review, it is a product constraint.

## Standing rules (never weaken)

- [x] **No data collection.** No analytics or attribution SDKs (first- or
      third-party), no crash reporters that phone home, no identifiers, no
      server of our own. Nothing personally identifiable ever leaves the device.
- [x] **No network calls from child-facing flows.** The only networking in the
      entire v1 app is StoreKit itself, and purchase UI is only reachable behind
      the parental gate. Story playback, canvas, pack loading: 100% local.
- [x] **No ads.** Ever.
- [x] **No external links** outside the parental gate.
- [x] **Purchases only behind the parental gate** (guideline 1.3: parental
      permission or gate before commerce or link-out).
- [x] **Privacy manifest** (`PrivacyInfo.xcprivacy`): no tracking, empty
      collection list; declares UserDefaults required-reason API (CA92.1 —
      app's own settings only: recently-played story IDs, active pack).
- [x] **Privacy nutrition label**: "Data Not Collected" (must stay true).

## Parental gate

- Challenge: **three different digits spelled out as words** in the app's
  language ("seven · two · four", "siete · dos · cuatro"; the system spells
  them, digits 2–9 only) to type on a digit pad. A reading adult needs a
  few seconds and no arithmetic; a pre-reader can't read the words; a random
  tap sequence passes one time in a thousand. A wrong answer poses a fresh
  challenge. Product decision (2026-09-23, replacing single-digit
  addition, which random tapping could pass about one time in 25): keep it
  friction-light for parents.
- **Three wrong answers in a row pause the gate for 20 seconds** (keypad
  disabled, countdown shown), so button-mashing gets nowhere. The count
  and the pause live in memory only, shared across openings of the gate so
  closing and reopening it doesn't reset them; nothing about failed
  attempts is ever written to disk.
- Gates: the Grown-Ups area (purchases, restore, parent settings, future
  links), reached only via the main menu's "More stories" card. Nothing else
  in the app leads out of the child experience; the story screen has no
  grown-ups access at all.
- Review expectation: gate must not be defeatable by random tapping and must be
  presented every time (no "remember me").

## App Store setup notes (for App Store Connect, later)

- Category: Kids / 5 & under. Age rating questionnaire: everything "None".
- Made-for-Kids apps cannot request IDFA/tracking; we don't.
- **Mac availability: opt out.** v1 ships iPad + iPhone only. When creating the
  app record, uncheck "Make this app available on Mac" (Designed for iPad on
  Apple silicon). If we later opt in: verify parental-gate UX with
  pointer/keyboard, IAP + Ask to Buy behaviour on macOS, and that Kids Category
  policies apply identically on the Mac App Store.
- If a future version adds accounts/messaging/etc. (unlikely), re-run the full
  COPPA analysis. Today there is no consent flow because there is no collection.

## Engineering checklist for every change

1. Does it add any network call reachable without the parental gate? → reject.
2. Does it add any SDK or data write that could count as collection? → reject.
3. Does it add UI that leads out of the app? → must sit behind the gate.
4. Does it touch the gate itself? → re-test that random tapping cannot pass it.
