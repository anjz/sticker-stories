import Foundation

/// Maps pack IDs to App Store product IDs (see docs/commerce.md).
public struct ProductCatalog: Sendable, Equatable {
    /// e.g. "com.anj.stickerstories.pack." — pack product = prefix + packID.
    public let packProductPrefix: String
    /// The future "unlock everything" non-consumable.
    public let allAccessProductID: String

    public init(packProductPrefix: String, allAccessProductID: String) {
        self.packProductPrefix = packProductPrefix
        self.allAccessProductID = allAccessProductID
    }

    public func productID(forPackID packID: String) -> String {
        packProductPrefix + packID
    }

    public func packID(fromProductID productID: String) -> String? {
        guard productID.hasPrefix(packProductPrefix) else { return nil }
        return String(productID.dropFirst(packProductPrefix.count))
    }
}

/// One purchased pack: the product that unlocked it and the transaction that
/// proved it, persisted locally keyed by pack ID (docs/commerce.md).
public struct PackEntitlementRecord: Codable, Equatable, Sendable {
    public let productID: String
    public let transactionID: String

    public init(productID: String, transactionID: String) {
        self.productID = productID
        self.transactionID = transactionID
    }
}

/// Abstracts StoreKit for entitlement checks: the product IDs of currently
/// verified, unrevoked transactions. The app's implementation reads StoreKit
/// 2's `Transaction.currentEntitlements`; tests provide fixed sets.
public protocol TransactionProvider: Sendable {
    func currentEntitledProductIDs() async -> Set<String>
}

/// Persists purchased-pack records and reconciles them against the App Store
/// truth on every launch. Pure logic — no StoreKit import — so refund and
/// all-access behaviour is unit-testable.
///
/// Bundled packs never appear here: they are entitled by definition.
public struct EntitlementStore: Sendable {
    private let storageURL: URL
    private let catalog: ProductCatalog

    /// - Parameter directory: where `entitlements.json` lives (the app passes
    ///   Application Support; tests pass a temp directory).
    public init(directory: URL, catalog: ProductCatalog) {
        self.storageURL = directory.appendingPathComponent("entitlements.json")
        self.catalog = catalog
    }

    // MARK: Records

    /// packID → record. A missing or unreadable file is an empty store.
    public func records() -> [String: PackEntitlementRecord] {
        guard let data = try? Data(contentsOf: storageURL) else { return [:] }
        return (try? JSONDecoder().decode([String: PackEntitlementRecord].self, from: data)) ?? [:]
    }

    public func addRecord(_ record: PackEntitlementRecord, forPackID packID: String) throws {
        var all = records()
        all[packID] = record
        try save(all)
    }

    public func removeRecord(forPackID packID: String) throws {
        var all = records()
        all.removeValue(forKey: packID)
        try save(all)
    }

    private func save(_ records: [String: PackEntitlementRecord]) throws {
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: storageURL, options: .atomic)
    }

    // MARK: Reconciliation (the launch-time enforcement point)

    /// Compares stored records against the current App Store entitlements.
    /// Packs whose product is no longer entitled (refund, revocation, Family
    /// Sharing removal) have their records removed and are returned so the
    /// caller can delete their local assets. The all-access product, when
    /// entitled, keeps every pack.
    public func reconcile(against provider: any TransactionProvider) async -> [String] {
        let entitled = await provider.currentEntitledProductIDs()
        guard !entitled.contains(catalog.allAccessProductID) else { return [] }

        var all = records()
        let revoked = all.filter { !entitled.contains($0.value.productID) }.map(\.key)
        guard !revoked.isEmpty else { return [] }

        for packID in revoked {
            all.removeValue(forKey: packID)
        }
        try? save(all)
        return revoked.sorted()
    }
}
