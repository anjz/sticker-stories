import Foundation
import Testing

@testable import StickerStoriesKit

private struct FixedTransactions: TransactionProvider {
    let productIDs: Set<String>
    func currentEntitledProductIDs() async -> Set<String> { productIDs }
}

private let catalog = ProductCatalog(
    packProductPrefix: "com.anj.stickerstories.pack.",
    allAccessProductID: "com.anj.stickerstories.allaccess")

private func makeStore() -> EntitlementStore {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("entitlements-\(UUID().uuidString)")
    return EntitlementStore(directory: dir, catalog: catalog)
}

@Suite struct ProductCatalogTests {
    @Test func mapsPackIDsBothWays() {
        #expect(catalog.productID(forPackID: "meadow") == "com.anj.stickerstories.pack.meadow")
        #expect(catalog.packID(fromProductID: "com.anj.stickerstories.pack.meadow") == "meadow")
        #expect(catalog.packID(fromProductID: "com.anj.stickerstories.allaccess") == nil)
        #expect(catalog.packID(fromProductID: "com.other.app.pack.meadow") == nil)
    }
}

@Suite struct EntitlementStoreTests {
    @Test func startsEmptyAndPersistsRecords() throws {
        let store = makeStore()
        #expect(store.records().isEmpty)

        let record = PackEntitlementRecord(
            productID: catalog.productID(forPackID: "meadow"), transactionID: "2000000123")
        try store.addRecord(record, forPackID: "meadow")
        #expect(store.records() == ["meadow": record])

        try store.removeRecord(forPackID: "meadow")
        #expect(store.records().isEmpty)
    }

    @Test func reconcileKeepsEntitledPacks() async throws {
        let store = makeStore()
        try store.addRecord(
            PackEntitlementRecord(
                productID: catalog.productID(forPackID: "meadow"), transactionID: "1"),
            forPackID: "meadow")

        let revoked = await store.reconcile(
            against: FixedTransactions(productIDs: [catalog.productID(forPackID: "meadow")]))
        #expect(revoked.isEmpty)
        #expect(store.records().count == 1)
    }

    @Test func reconcileRemovesRevokedPacksAndReportsThem() async throws {
        let store = makeStore()
        try store.addRecord(
            PackEntitlementRecord(
                productID: catalog.productID(forPackID: "meadow"), transactionID: "1"),
            forPackID: "meadow")
        try store.addRecord(
            PackEntitlementRecord(
                productID: catalog.productID(forPackID: "ocean"), transactionID: "2"),
            forPackID: "ocean")

        // Only ocean is still entitled: meadow was refunded.
        let revoked = await store.reconcile(
            against: FixedTransactions(productIDs: [catalog.productID(forPackID: "ocean")]))
        #expect(revoked == ["meadow"])
        #expect(store.records().keys.sorted() == ["ocean"])
    }

    @Test func allAccessKeepsEverything() async throws {
        let store = makeStore()
        try store.addRecord(
            PackEntitlementRecord(
                productID: catalog.productID(forPackID: "meadow"), transactionID: "1"),
            forPackID: "meadow")

        // No individual pack entitlements, but all-access is owned.
        let revoked = await store.reconcile(
            against: FixedTransactions(productIDs: [catalog.allAccessProductID]))
        #expect(revoked.isEmpty)
        #expect(store.records().count == 1)
    }

    @Test func everythingRevokedWhenNoEntitlementsRemain() async throws {
        let store = makeStore()
        try store.addRecord(
            PackEntitlementRecord(
                productID: catalog.productID(forPackID: "meadow"), transactionID: "1"),
            forPackID: "meadow")

        let revoked = await store.reconcile(against: FixedTransactions(productIDs: []))
        #expect(revoked == ["meadow"])
        #expect(store.records().isEmpty)
    }

    @Test func corruptStorageIsTreatedAsEmpty() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("entitlements-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("entitlements.json"))

        let store = EntitlementStore(directory: dir, catalog: catalog)
        #expect(store.records().isEmpty)
    }
}
