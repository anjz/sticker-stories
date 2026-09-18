import Testing

@testable import StickerStoriesKit

struct ArtVariantTests {
    private let base = 4.0 / 3.0  // Forest base art
    private let wide = 2.0  // Forest wide art

    @Test func tallPhoneGetsWideArt() {
        #expect(ArtVariant.select(viewAspect: 874.0 / 402.0, baseAspect: base, wideAspect: wide) == .wide)
    }

    @Test func iPadLandscapeKeepsBaseArt() {
        #expect(ArtVariant.select(viewAspect: 1194.0 / 834.0, baseAspect: base, wideAspect: wide) == .base)  // 11"
        #expect(ArtVariant.select(viewAspect: 4.0 / 3.0, baseAspect: base, wideAspect: wide) == .base)  // 13"
    }

    @Test func portraitAndNarrowWindowsUseBaseArt() {
        #expect(ArtVariant.select(viewAspect: 834.0 / 1194.0, baseAspect: base, wideAspect: wide) == .base)
        #expect(ArtVariant.select(viewAspect: 597.0 / 834.0, baseAspect: base, wideAspect: wide) == .base)  // Split View half
    }

    @Test func windowsBetweenTheTwoGoToTheCloser() {
        #expect(ArtVariant.select(viewAspect: 1.9, baseAspect: base, wideAspect: wide) == .wide)
        #expect(ArtVariant.select(viewAspect: 1.5, baseAspect: base, wideAspect: wide) == .base)
    }

    @Test func noWideArtMeansBase() {
        #expect(ArtVariant.select(viewAspect: 3, baseAspect: base, wideAspect: nil) == .base)
    }
}
