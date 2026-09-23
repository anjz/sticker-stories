import Foundation
import StickerStoriesKit

/// Product ID conventions for this app (docs/commerce.md).
enum StoreConfiguration {
    static let catalog = ProductCatalog(
        packProductPrefix: "com.anj.stickerstories.pack.",
        allAccessProductID: "com.anj.stickerstories.allaccess")

    /// Purchasable pack products for the store, in the order it shows them.
    /// Matches the StoreKit testing configuration; App Store Connect later.
    static let purchasableProductIDs: [String] = {
        var packIDs = ["meadow"]
        #if DEBUG
        // Placeholder packs that exist only in the StoreKit test
        // configuration (app/StickerStories.storekit), so the store can be
        // seen full and tried out; release builds never ask for them.
        packIDs += ["ocean", "farm", "space", "dinos", "home"]
        #endif
        return packIDs.map(catalog.productID(forPackID:))
    }()
}
