import Foundation
import Observation
import StickerStoriesKit
import StoreKit
import SwiftUI

/// Purchase flow for the Grown-Ups area. Only reachable behind the parental
/// gate — never from any child-facing surface (docs/compliance.md).
@MainActor
@Observable
final class StoreService {
    private(set) var products: [Product] = []
    private(set) var ownedProductIDs: Set<String> = []
    private(set) var isWorking = false
    /// A catalog key, not a resolved string, so the UI localizes it through
    /// the environment locale (which the parent language override can change).
    private(set) var lastMessage: LocalizedStringKey?

    private let entitlements: EntitlementCoordinator

    init(entitlements: EntitlementCoordinator) {
        self.entitlements = entitlements
    }

    func refresh() async {
        let ids = StoreConfiguration.purchasableProductIDs + [StoreConfiguration.catalog.allAccessProductID]
        // StoreKit returns products in no particular order; keep the catalogue's.
        let loaded = (try? await Product.products(for: ids)) ?? []
        products = loaded.sorted { (ids.firstIndex(of: $0.id) ?? .max) < (ids.firstIndex(of: $1.id) ?? .max) }
        ownedProductIDs = await StoreKitTransactionProvider().currentEntitledProductIDs()
    }

    func purchase(_ product: Product) async {
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    lastMessage = "Purchase could not be verified."
                    return
                }
                entitlements.recordEntitlement(for: transaction)
                // v1 ships only the bundled pack; purchased pack assets
                // install here once packs are delivered separately.
                await transaction.finish()
                ownedProductIDs.insert(transaction.productID)
                lastMessage = "Purchase complete."
            case .userCancelled:
                break
            case .pending:
                lastMessage = "Waiting for approval (Ask to Buy)."
            @unknown default:
                break
            }
        } catch {
            lastMessage = "Purchase failed. Please try again."
        }
    }

    /// Restore = re-sync with the App Store and re-run the same
    /// reconciliation used at launch.
    func restorePurchases() async {
        isWorking = true
        defer { isWorking = false }
        try? await AppStore.sync()
        await entitlements.validateOnLaunch()
        await refresh()
        lastMessage = "Purchases restored."
    }
}
