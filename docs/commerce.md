# Commerce

## Model

- **Sticker packs are non-consumable IAPs**, ~£/$/€1.99 each.
  Product ID convention: `com.anj.stickerstories.pack.<packID>`.
- The **Forest pack ships bundled and free** — no product, always entitled.
- **"All Sticker Story Packs"** non-consumable (~9.99),
  `com.anj.stickerstories.allaccess`, offered in the banner at the top of the
  store screen. The entitlement layer understands it: a pack is entitled if
  its own product is owned **or** the all-access product is owned.
- StoreKit 2 only. No server of our own in v1; no receipt server.

## Entitlement data

`EntitlementStore` (in `StickerStoriesKit`) persists a JSON file in Application
Support:

```json
{
  "packs": {
    "meadow": { "productID": "com.anj.stickerstories.pack.meadow",
                "transactionID": "200000123456789" }
  }
}
```

- Keyed by pack ID; records the original transaction ID at purchase time.
- Bundled packs never appear here — they are entitled by definition
  (`PackLibrary` marks packs found in the app bundle as `.bundled`).

## Launch-time validation (the enforcement point)

On every app launch, before pack discovery completes:

1. Ask the `TransactionProvider` (production: StoreKit 2
   `Transaction.currentEntitlements`) for all **verified** transactions with
   `revocationDate == nil`. Unverified transactions are ignored entirely.
2. For each stored pack record, check its product ID is among the current
   entitlements. Missing or revoked (refunded / Family Sharing removal) →
   **delete the pack's local assets** and remove its record.
3. If the all-access product is entitled, all known packs pass step 2.
4. While running, a `Transaction.updates` listener applies the same logic
   incrementally (delivers purchases, revocations, Ask to Buy approvals).

Design note: `EntitlementStore` is pure logic over the `TransactionProvider`
protocol; the StoreKit adapter lives in the app target. Tests simulate
purchase/refund/all-access without StoreKit.

## Purchase flow (behind the parental gate, store screen)

1. `Product.products(for:)` for the catalogue of pack product IDs.
2. `product.purchase()` → verify result → record transaction ID keyed by pack ID
   → `transaction.finish()` **after** assets are in place.
3. Restore = re-running the launch reconciliation (`currentEntitlements` covers
   it); a "Restore purchases" button simply triggers it with `AppStore.sync()`.
4. **Ask to Buy** (deferred transactions) arrive via `Transaction.updates` — the
   listener handles them with no special UI.

v1 note: purchasable pack downloads don't exist yet (only the bundled pack
ships). The scaffolding — products in the StoreKit Testing config, purchase
service, entitlement reconciliation, gate — is in place so adding the first
purchasable pack is content work, not architecture work.

## Product copy

What parents read about packs, in the store and on the App Store, follows
one vocabulary and fits App Store Connect's limits in **every** language.

**The product term.** A pack is a **Sticker Story Pack** — stickers *and*
the stories that come with them, echoing the app's name. Parent-facing copy
uses it (capitalised, as a product name); pack titles stay short ("Forest
Friends", not "Forest Friends Sticker Story Pack") because the store frames
them. Code, docs and the tools keep saying "pack".

| Language | Term | Bundle name | Bundle description |
|---|---|---|---|
| en | Sticker Story Pack | All Sticker Story Packs (23) | Every Sticker Story Pack in the app. (36) |
| es | pack de cuentos (con pegatinas) | Todos los packs de cuentos (26) | Todos los packs de cuentos con pegatinas. (41) |

The Spanish bundle name drops "con pegatinas": the literal "Todos los packs
de cuentos con pegatinas" is 40 characters, so "pegatinas" lives in the
description instead.

**App Store Connect limits, per localization of each in-app purchase:**

- **Display name: at most 30 characters.** For a pack product it is the
  pack's name, so a manifest `displayName` must fit too
  (`docs/pack-format.md`).
- **Description: at most 45 characters.** One short sentence. A pack's
  manifest `description` (what the store shows once the pack is on the
  device, and for the bundled pack) should say the same thing.
- Keep `app/StickerStories.storekit` (the StoreKit test configuration) in
  step with App Store Connect: the store shows StoreKit's name, description
  and price verbatim, so the test copy is the copy parents see in testing.
- The app never promises future content ("now and in the future"): the
  bundle is every pack in the app.

**Adding a language** (see also `docs/architecture.md`, "Localization"):

1. Pick the language's term for a Sticker Story Pack first, and add a row to
   the table above.
2. Write the bundle's name and description, and every pack product's, and
   **count the characters** against the limits — translations often run
   longer than English; shorten rather than abbreviate.
3. Add the localization to each product in App Store Connect and in
   `app/StickerStories.storekit`.
4. Translate the store's own strings in `Localizable.xcstrings`.

## Testing

- `app/StickerStories.storekit` defines test products (a `meadow` pack and
  `allaccess`) for the StoreKit Testing environment; the shared scheme loads it.
  It also holds five placeholder packs (`ocean`, `farm`, `space`, `dinos`,
  `home`) that only debug builds ask for (`StoreConfiguration`), so the store
  can be seen full and test-bought; they have no content and never reach
  App Store Connect.
- Refund simulation: Xcode → Debug → StoreKit → Manage Transactions → refund,
  then relaunch → assets for that pack must be gone.
- Unit tests cover the reconciliation logic in `StickerStoriesKit`.
