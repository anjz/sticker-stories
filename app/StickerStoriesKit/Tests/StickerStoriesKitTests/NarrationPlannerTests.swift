import Testing

@testable import StickerStoriesKit

@Suite struct NarrationPlannerTests {
    let languages = ["en-US", "es-ES", "fr-FR"]

    @Test func thePreferredLanguageWhenItIsThere() {
        let choice = NarrationPlanner.choose(preferred: "es-ES", languages: languages, recent: ["en-US"]) { _ in true }
        #expect(choice == .init(language: "es-ES", isFallback: false))
    }

    @Test func elseTheLastOneUsedThatIsThere() {
        let local: Set = ["en-US", "fr-FR"]
        // French was used last: it plays while Spanish downloads.
        #expect(NarrationPlanner.choose(preferred: "es-ES", languages: languages, recent: ["fr-FR", "en-US"]) {
            local.contains($0)
        } == .init(language: "fr-FR", isFallback: true))
        // Nothing used yet (a fresh install): the pack's first language that is there.
        #expect(NarrationPlanner.choose(preferred: "es-ES", languages: languages, recent: []) {
            local.contains($0)
        } == .init(language: "en-US", isFallback: true))
        // A recent language this pack doesn't have is skipped.
        #expect(NarrationPlanner.choose(preferred: "es-ES", languages: ["en-US", "es-ES"], recent: ["fr-FR"]) {
            local.contains($0)
        } == .init(language: "en-US", isFallback: true))
    }

    @Test func nothingWhileNoLanguageHasArrived() {
        #expect(NarrationPlanner.choose(preferred: "es-ES", languages: languages, recent: ["en-US"]) { _ in false } == nil)
    }

    @Test func keepsWhatPlaysUntilTheNewLanguageIsAllThere() {
        let local: Set = ["en-US", "fr-FR"]
        #expect(NarrationPlanner.removable(
            current: "es-ES", local: local, currentComplete: false, recent: ["en-US"], roomToSpare: false).isEmpty)
    }

    @Test func thenKeepsThePreviousOneOnlyWithRoomToSpare() {
        let local: Set = ["en-US", "es-ES", "fr-FR"]
        let recent = ["es-ES", "en-US", "fr-FR"]
        #expect(NarrationPlanner.removable(
            current: "es-ES", local: local, currentComplete: true, recent: recent, roomToSpare: true) == ["fr-FR"])
        #expect(NarrationPlanner.removable(
            current: "es-ES", local: local, currentComplete: true, recent: recent, roomToSpare: false) == ["en-US", "fr-FR"])
    }

    @Test func usedMovesALanguageToTheFront() {
        #expect(NarrationPlanner.used("es-ES", recent: ["en-US", "es-ES", "fr-FR"]) == ["es-ES", "en-US", "fr-FR"])
        #expect(NarrationPlanner.used("de-DE", recent: ["en-US"]) == ["de-DE", "en-US"])
    }
}
