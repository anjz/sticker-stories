import Testing

@testable import StickerStoriesKit

struct ArtVariantTests {
    private let base = 4.0 / 3.0  // Forest base art
    private let wide = 2.0  // Forest wide art

    private func pick(_ viewAspect: Double, wide: Double? = 2.0) -> ArtVariant {
        ArtVariant.select(viewAspect: viewAspect, baseAspect: base, wideAspect: wide)
    }

    // Full-screen landscape never pans.
    @Test func tallPhoneGetsWideArtAndCropsALittle() {
        #expect(pick(874.0 / 402.0) == .wide)  // 19.5:9 → wide art, ~8% cropped
    }

    @Test func sixteenByNinePhoneCropsBaseArtRatherThanPanning() {
        #expect(pick(16.0 / 9.0) == .base)  // wide art would pan; base crops 25%
    }

    @Test func iPadLandscapeKeepsBaseArt() {
        #expect(pick(1194.0 / 834.0) == .base)  // 11": crops 7%
        #expect(pick(4.0 / 3.0) == .base)  // 13": exact
    }

    @Test func excessiveCropFallsBackToTheLeastPanning() {
        #expect(pick(1.95) == .wide)  // base would crop 32% (> 30%); wide pans 2.5%
        #expect(pick(3.0) == .wide)  // everything crops; wide crops least
        #expect(pick(3.0, wide: nil) == .base)  // no choice: base, cropped
    }

    // Narrower windows pan the least with the base art.
    @Test func portraitAndNarrowWindowsUseBaseArt() {
        #expect(pick(834.0 / 1194.0) == .base)
        #expect(pick(597.0 / 834.0) == .base)  // Split View half
        #expect(pick(1.2) == .base)  // just narrower than base: base pans 10%, wide 40%
    }
}
