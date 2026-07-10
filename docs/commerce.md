# Commerce

## Model

- **Sticker packs are non-consumable IAPs**, ~£/$/€1.99 each.
  Product ID convention: `com.anj.stickerstories.pack.<packID>`.
- The **Forest pack ships bundled and free** — no product, always entitled.
- **Future: "unlock everything"** non-consumable (~12.99),
  `com.anj.stickerstories.allaccess`. Not built yet, but the entitlement layer
  understands it today: a pack is entitled if its own product is owned **or**
  the all-access product is owned.
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

## Purchase flow (behind the parental gate, Grown-Ups area)

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

## Testing

- `app/StickerStories.storekit` defines test products (a `meadow` pack and
  `allaccess`) for the StoreKit Testing environment; the shared scheme loads it.
- Refund simulation: Xcode → Debug → StoreKit → Manage Transactions → refund,
  then relaunch → assets for that pack must be gone.
- Unit tests cover the reconciliation logic in `StickerStoriesKit`.
