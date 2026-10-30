import Testing

@testable import StickerStoriesKit

@Suite struct LanguageResolverTests {
    private let packLanguages = ["en-US", "es-ES"]

    @Test func exactMatchWins() {
        let resolver = LanguageResolver(preferredLanguages: ["es-ES", "en-US"])
        #expect(resolver.resolve(from: packLanguages) == "es-ES")
    }

    @Test func exactMatchIsCaseInsensitive() {
        let resolver = LanguageResolver(preferredLanguages: ["ES-es"])
        #expect(resolver.resolve(from: packLanguages) == "es-ES")
    }

    @Test func primarySubtagMatchesRegionalVariant() {
        // A Mexican-Spanish device gets the pack's Spain Spanish.
        let resolver = LanguageResolver(preferredLanguages: ["es-MX", "en-US"])
        #expect(resolver.resolve(from: packLanguages) == "es-ES")
    }

    @Test func preferenceOrderIsRespected() {
        // French isn't available; the device's second preference wins.
        let resolver = LanguageResolver(preferredLanguages: ["fr-FR", "es-ES"])
        #expect(resolver.resolve(from: packLanguages) == "es-ES")
    }

    @Test func fallsBackToFirstDeclaredLanguage() {
        let resolver = LanguageResolver(preferredLanguages: ["ja-JP", "ko-KR"])
        #expect(resolver.resolve(from: packLanguages) == "en-US")
    }

    @Test func bareLanguageTagMatchesRegionalDeclaration() {
        let resolver = LanguageResolver(preferredLanguages: ["es"])
        #expect(resolver.resolve(from: packLanguages) == "es-ES")
    }

    @Test func chineseGoesByScriptAndRegion() {
        let pack = ["en-US", "ja-JP", "zh-TW", "zh-HK"]
        #expect(LanguageResolver(preferredLanguages: ["zh-Hant-TW"]).resolve(from: pack) == "zh-TW")
        #expect(LanguageResolver(preferredLanguages: ["zh-Hant"]).resolve(from: pack) == "zh-TW")
        #expect(LanguageResolver(preferredLanguages: ["zh-Hant-HK"]).resolve(from: pack) == "zh-HK")
        #expect(LanguageResolver(preferredLanguages: ["zh-Hant-MO"]).resolve(from: pack) == "zh-HK")
        #expect(LanguageResolver(preferredLanguages: ["yue-Hant-HK"]).resolve(from: pack) == "zh-HK")
        #expect(LanguageResolver(preferredLanguages: ["zh-HK"]).resolve(from: pack) == "zh-HK")
    }

    @Test func simplifiedChineseTakesNoTraditionalPack() {
        // A Simplified device goes on to its next language, else the fallback.
        let pack = ["en-US", "zh-TW", "zh-HK"]
        #expect(LanguageResolver(preferredLanguages: ["zh-Hans-CN", "ja-JP"]).resolve(from: pack) == "en-US")
        #expect(LanguageResolver(preferredLanguages: ["zh-Hans-CN", "zh-Hant-HK"]).resolve(from: pack) == "zh-HK")
    }

    @Test func otherLanguagesStillMatchByPrimarySubtag() {
        let pack = ["en-US", "es-ES", "de-DE", "fr-FR", "it-IT", "ja-JP"]
        #expect(LanguageResolver(preferredLanguages: ["de-AT"]).resolve(from: pack) == "de-DE")
        #expect(LanguageResolver(preferredLanguages: ["fr-CA"]).resolve(from: pack) == "fr-FR")
        #expect(LanguageResolver(preferredLanguages: ["ja"]).resolve(from: pack) == "ja-JP")
    }
}
