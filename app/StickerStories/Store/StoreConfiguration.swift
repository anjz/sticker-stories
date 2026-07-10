import Foundation
import StickerStoriesKit

/// Product ID conventions for this app (docs/commerce.md).
enum StoreConfiguration {
    static let catalog = ProductCatalog(
        packProductPrefix: "com.anj.stickerstories.pack.",
        allAccessProductID: "com.anj.stickerstories.allaccess")

    /// Purchasable pack products for the Grown-Ups catalogue. Matches the
    /// StoreKit testing configuration; App Store Connect later.
    static let purchasableProductIDs: [String] = [
        catalog.productID(forPackID: "meadow")
    ]
}
