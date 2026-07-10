import Testing
@testable import StickerStoriesKit

@Test func kitModuleLinksAndAgreesOnSchemaVersion() {
    #expect(StickerStoriesKitInfo.supportedSchemaVersion == 1)
}
