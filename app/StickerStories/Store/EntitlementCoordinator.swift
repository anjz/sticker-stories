import Foundation
import StickerStoriesKit
import StoreKit

/// Production `TransactionProvider`: verified, unrevoked StoreKit 2
/// entitlements. Unverified transactions are ignored entirely.
struct StoreKitTransactionProvider: TransactionProvider {
    func currentEntitledProductIDs() async -> Set<String> {
        var productIDs = Set<String>()
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.revocationDate == nil {
                productIDs.insert(transaction.productID)
            }
        }
        return productIDs
    }
}

/// Owns the entitlement lifecycle:
/// - launch: reconcile stored records against StoreKit, deleting local assets
///   of revoked packs (the enforcement point — docs/commerce.md),
/// - runtime: apply `Transaction.updates` (purchases, refunds, Ask to Buy
///   approvals) with the same rules.
@MainActor
final class EntitlementCoordinator {
    private let store: EntitlementStore
    private let catalog = StoreConfiguration.catalog
    private var updatesTask: Task<Void, Never>?

    init() {
        store = EntitlementStore(
            directory: URL.applicationSupportDirectory, catalog: catalog)
    }

    /// Runs before pack discovery on every launch.
    func validateOnLaunch() async {
        let revoked = await store.reconcile(against: StoreKitTransactionProvider())
        for packID in revoked {
            deleteInstalledPack(packID)
        }
    }

    func startObservingTransactions() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.apply(update)
            }
        }
    }

    /// Records a verified purchase. Called by the purchase flow and the
    /// updates listener; finishing the transaction is the caller's job once
    /// delivery (asset install, when packs ship separately) has happened.
    func recordEntitlement(for transaction: Transaction) {
        guard let packID = catalog.packID(fromProductID: transaction.productID) else {
            return  // all-access needs no per-pack record
        }
        try? store.addRecord(
            PackEntitlementRecord(
                productID: transaction.productID,
                transactionID: String(transaction.id)),
            forPackID: packID)
    }

    private func apply(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        if transaction.revocationDate != nil {
            // Refund / revocation while running: same enforcement as launch.
            _ = await store.reconcile(against: StoreKitTransactionProvider())
            if let packID = catalog.packID(fromProductID: transaction.productID) {
                deleteInstalledPack(packID)
            }
        } else {
            recordEntitlement(for: transaction)
        }
        await transaction.finish()
    }

    private func deleteInstalledPack(_ packID: String) {
        let directory = PackLibrary.installedPacksDirectory.appendingPathComponent(packID)
        try? FileManager.default.removeItem(at: directory)
    }
}
