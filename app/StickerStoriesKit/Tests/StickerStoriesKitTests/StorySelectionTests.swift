import Foundation
import Testing

@testable import StickerStoriesKit

/// In-memory recents store for tests.
final class MemoryRecents: RecentStoriesStore, @unchecked Sendable {
    private var played: [String: [String]] = [:]  // packID → most recent first

    func recentStoryIDs(forPackID packID: String) -> [String] {
        played[packID] ?? []
    }

    func recordPlayed(storyID: String, packID: String) {
        var list = played[packID] ?? []
        list.removeAll { $0 == storyID }
        list.insert(storyID, at: 0)
        played[packID] = list
    }
}

private func makePack(stories: [StoryDefinition]) -> LoadedPack {
    let stickers = ["mushroom", "fox", "rabbit", "tree", "owl"].map {
        StickerDefinition(id: $0, name: localized($0.capitalized, $0.capitalized), image: "stickers/\($0).png")
    }
    let manifest = PackManifest(
        schemaVersion: 2, id: "forest", version: 1,
        languages: ["en-US", "es-ES"],
        displayName: localized("Forest", "Bosque"),
        theme: "forest", background: "art/b.png", foreground: "art/f.png",
        stickers: stickers, stories: stories)
    return LoadedPack(manifest: manifest, baseURL: URL(fileURLWithPath: "/tmp/forest"), source: .bundled)
}

private func story(
    _ id: String, required: [String] = [], optional: [String] = [], weight: Double = 1.0
) -> StoryDefinition {
    StoryDefinition(
        id: id, requiredStickers: required, optionalStickers: optional, weight: weight,
        localizations: [
            "en-US": StoryLocalization(
                title: "Title of \(id)", text: "Text of \(id).", audio: "audio/en-US/\(id).m4a"),
            "es-ES": StoryLocalization(
                title: "Título de \(id)", text: "Texto de \(id).", audio: "audio/es-ES/\(id).m4a"),
        ])
}

private func canvas(_ stickerIDs: [String]) -> CanvasState {
    CanvasState(
        packID: "forest",
        stickers: stickerIDs.map {
            PlacedSticker(stickerID: $0, position: NormalizedPoint(x: 0.5, y: 0.5))
        })
}

/// A provider whose "random" pick is deterministic: always the lower bound,
/// which selects the highest-scoring candidate.
private func deterministicProvider(recents: RecentStoriesStore = MemoryRecents()) -> BundledStoryProvider {
    BundledStoryProvider(recents: recents, random: { $0.lowerBound })
}

@Suite struct StorySelectionTests {
    @Test func requiredSubsetGatesCandidacy() async throws {
        let pack = makePack(stories: [
            story("needs-fox-and-rabbit", required: ["fox", "rabbit"]),
            story("needs-owl", required: ["owl"]),
            story("fallback"),
        ])
        // Only fox on canvas: neither required set is satisfied → fallback.
        let chosen = try await deterministicProvider().story(
            for: canvas(["fox"]), in: pack, language: "en-US")
        #expect(chosen.id == "fallback")
    }

    @Test func specificStoryBeatsFallback() async throws {
        let pack = makePack(stories: [
            story("fallback"),
            story("fox-story", required: ["fox"]),
        ])
        let chosen = try await deterministicProvider().story(
            for: canvas(["fox"]), in: pack, language: "en-US")
        #expect(chosen.id == "fox-story")
    }

    @Test func optionalMatchesRaiseTheScore() async throws {
        let pack = makePack(stories: [
            story("fox-alone", required: ["fox"]),
            story("fox-friends", required: ["fox"], optional: ["rabbit", "tree"]),
        ])
        let chosen = try await deterministicProvider()
            .story(for: canvas(["fox", "rabbit", "tree"]), in: pack, language: "en-US")
        #expect(chosen.id == "fox-friends")
    }

    @Test func weightBreaksTies() async throws {
        let pack = makePack(stories: [
            story("light", required: ["fox"], weight: 1.0),
            story("heavy", required: ["fox"], weight: 3.0),
        ])
        let chosen = try await deterministicProvider().story(
            for: canvas(["fox"]), in: pack, language: "en-US")
        #expect(chosen.id == "heavy")
    }

    @Test func recentlyPlayedIsDeprioritised() async throws {
        let recents = MemoryRecents()
        let provider = deterministicProvider(recents: recents)
        let pack = makePack(stories: [
            story("a", required: ["fox"]),
            story("b", required: ["fox"]),
        ])
        // Equal scores: deterministic pick chooses "a" (stable sort keeps
        // manifest order), which then carries the recency penalty…
        let first = try await provider.story(for: canvas(["fox"]), in: pack, language: "en-US")
        #expect(first.id == "a")
        // …so the next play must choose "b".
        let second = try await provider.story(for: canvas(["fox"]), in: pack, language: "en-US")
        #expect(second.id == "b")
    }

    @Test func playNeverFailsOnEmptyCanvas() async throws {
        let pack = makePack(stories: [
            story("needs-owl", required: ["owl"]),
            story("fallback-1"),
            story("fallback-2"),
        ])
        let chosen = try await deterministicProvider().story(
            for: canvas([]), in: pack, language: "en-US")
        #expect(chosen.id.hasPrefix("fallback"))
    }

    @Test func throwsOnlyWhenNothingIsPlayable() async throws {
        // A pack with no fallback (invalid by validation rules, but the
        // provider still guards).
        let pack = makePack(stories: [story("needs-owl", required: ["owl"])])
        await #expect(throws: StoryProviderError.noPlayableStory) {
            _ = try await deterministicProvider().story(
                for: canvas(["fox"]), in: pack, language: "en-US")
        }
    }

    @Test func randomPickStaysWithinTopCandidates() async throws {
        // Force the "random" pick to the upper bound: the weakest candidate in
        // the top pool must still satisfy the required-subset rule.
        let provider = BundledStoryProvider(recents: MemoryRecents(), random: { $0.upperBound })
        let pack = makePack(stories: [
            story("fox-a", required: ["fox"]),
            story("fox-b", required: ["fox"]),
            story("needs-owl", required: ["owl"]),
            story("fallback"),
        ])
        for _ in 0..<10 {
            let chosen = try await provider.story(
                for: canvas(["fox"]), in: pack, language: "en-US")
            #expect(chosen.id != "needs-owl")
        }
    }

    @Test func storyCarriesLanguageResolvedContent() async throws {
        let pack = makePack(stories: [story("fallback")])

        let english = try await deterministicProvider().story(
            for: canvas([]), in: pack, language: "en-US")
        #expect(english.title == "Title of fallback")
        #expect(english.text == "Text of fallback.")
        #expect(english.audioPath == "audio/en-US/fallback.m4a")

        let spanish = try await deterministicProvider().story(
            for: canvas([]), in: pack, language: "es-ES")
        #expect(spanish.title == "Título de fallback")
        #expect(spanish.text == "Texto de fallback.")
        #expect(spanish.audioPath == "audio/es-ES/fallback.m4a")

        // An unsupported language falls back to the first declared one.
        let japanese = try await deterministicProvider().story(
            for: canvas([]), in: pack, language: "ja-JP")
        #expect(japanese.audioPath == "audio/en-US/fallback.m4a")
    }
}
