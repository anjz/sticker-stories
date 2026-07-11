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
}
