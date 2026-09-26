import Foundation
import Testing

@testable import StickerStoriesKit

/// In-memory recents store for tests; `newSession()` is the app relaunched.
final class MemoryRecents: RecentStoriesStore, @unchecked Sendable {
    private var played: [String: [String]] = [:]  // packID → most recent first
    private var session: [String: [String]] = [:]

    func recentStoryIDs(forPackID packID: String) -> [String] {
        played[packID] ?? []
    }

    func sessionStoryIDs(forPackID packID: String) -> [String] {
        session[packID] ?? []
    }

    func recordPlayed(storyID: String, packID: String) {
        for store in [\MemoryRecents.played, \MemoryRecents.session] {
            var list = self[keyPath: store][packID] ?? []
            list.removeAll { $0 == storyID }
            list.insert(storyID, at: 0)
            self[keyPath: store][packID] = list
        }
    }

    func newSession() { session = [:] }
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
    @Test func aStoryAboutWhatIsPlacedBeatsOneNeedingNoVisitors() async throws {
        let pack = makePack(stories: [
            story("needs-owl", required: ["owl"]),
            story("fallback"),
            story("needs-fox-rabbit-owl", required: ["fox", "rabbit", "owl"]),
        ])
        // Only fox on canvas: the trio is about it (two visitors come in),
        // so it beats the fallback, which beats the owl story (about
        // nothing placed).
        let recents = MemoryRecents()
        var heard: [String] = []
        for _ in 0..<3 {
            heard.append(try await deterministicProvider(recents: recents).story(for: canvas(["fox"]), in: pack, language: "en-US").id)
        }
        #expect(heard == ["needs-fox-rabbit-owl", "fallback", "needs-owl"])
        // Fox and rabbit: the trio is missing only the owl → a candidate,
        // and about the canvas, so it beats the fallback.
        let partial = try await deterministicProvider().story(
            for: canvas(["fox", "rabbit"]), in: pack, language: "en-US")
        #expect(partial.id == "needs-fox-rabbit-owl")
    }

    @Test func aSupportingPartBeatsAFallbackHoweverManyVisitors() async throws {
        let pack = makePack(stories: [
            story("fallback"),
            // The fox only supports; three featured visitors would score it
            // under the fallback (0.5 - 0.75), but it is about the fox.
            story("fox-helps", required: ["bird", "owl", "flower"], optional: ["fox"]),
        ])
        let chosen = try await deterministicProvider().story(for: canvas(["fox"]), in: pack, language: "en-US")
        #expect(chosen.id == "fox-helps")
    }

    @Test func fullMatchBeatsAStoryMissingASticker() async throws {
        let pack = makePack(stories: [
            story("missing-tree", required: ["fox", "rabbit", "tree"], optional: ["owl"]),
            story("all-here", required: ["fox", "rabbit", "owl"]),
        ])
        let chosen = try await deterministicProvider().story(
            for: canvas(["fox", "rabbit", "owl"]), in: pack, language: "en-US")
        #expect(chosen.id == "all-here")
    }

    @Test func recentStoriesAreLeftOutWhileThereIsAChoice() async throws {
        let recents = MemoryRecents()
        let provider = deterministicProvider(recents: recents)
        let pack = makePack(stories: (1...6).map { story("fox-\($0)", required: ["fox"]) })
        var heard: [String] = []
        for _ in 0..<6 {
            heard.append(try await provider.story(for: canvas(["fox"]), in: pack, language: "en-US").id)
        }
        // Six equal candidates, six plays: every one of them, none twice.
        #expect(Set(heard).count == 6)
        // The next round starts again from the one played longest ago.
        let seventh = try await provider.story(for: canvas(["fox"]), in: pack, language: "en-US").id
        #expect(seventh == heard[0])
    }

    @Test func bestMatchComesFirstAndTheWholeSetComesRound() async throws {
        let recents = MemoryRecents()
        let provider = deterministicProvider(recents: recents)
        let pack = makePack(stories: [
            story("fallback"),
            story("about-fox", required: ["fox"]),
            story("fox-and-owl", required: ["fox", "owl"]),
        ])
        // Fresh canvas: the story about what is placed comes first.
        let first = try await provider.story(for: canvas(["fox"]), in: pack, language: "en-US").id
        #expect(first == "about-fox")
        // Then the rest before anything repeats.
        let second = try await provider.story(for: canvas(["fox"]), in: pack, language: "en-US").id
        let third = try await provider.story(for: canvas(["fox"]), in: pack, language: "en-US").id
        #expect(Set([first, second, third]).count == 3)
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

    @Test func anEmptyCanvasComesRoundEveryStoryBeforeARepeat() async throws {
        let recents = MemoryRecents()
        let provider = BundledStoryProvider(recents: recents)  // real randomness
        let pack = makePack(stories: [
            story("fallback-1"), story("fallback-2"),
            story("fox", required: ["fox"]), story("owl", required: ["owl"]),
            story("fox-rabbit", required: ["fox", "rabbit"]), story("tree", required: ["tree"], optional: ["owl"]),
        ])
        var heard: [String] = []
        for _ in 0..<6 { heard.append(try await provider.story(for: canvas([]), in: pack, language: "en-US").id) }
        #expect(Set(heard).count == 6)
        // Fewest visitors first: the fallbacks, then the one-sticker stories, then the pair.
        #expect(Set(heard.prefix(2)) == ["fallback-1", "fallback-2"])
        #expect(heard.last == "fox-rabbit")
    }

    @Test func whatIsPlacedFirstThenStoriesNotHeard() async throws {
        let recents = MemoryRecents()
        let provider = deterministicProvider(recents: recents)
        let pack = makePack(stories: [
            story("owl"), story("fox-owl", required: ["fox", "owl"]),
            story("fox-rabbit", required: ["fox", "rabbit"]), story("tree", required: ["tree"]),
            story("fox", required: ["fox"]), story("rabbit", required: ["rabbit"]),
        ])
        var heard: [String] = []
        for _ in 0..<6 { heard.append(try await provider.story(for: canvas(["fox", "rabbit"]), in: pack, language: "en-US").id) }
        // Both placed, then one of them (fewest visitors first), then the
        // rest — every story, none twice.
        #expect(heard[0] == "fox-rabbit")
        #expect(Set(heard[1...2]) == ["fox", "rabbit"])
        #expect(heard[3] == "fox-owl")
        #expect(Set(heard) .count == 6)
        // A new session: the best match leads again.
        recents.newSession()
        #expect(try await provider.story(for: canvas(["fox", "rabbit"]), in: pack, language: "en-US").id == "fox-rabbit")
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

    @Test func throwsOnlyWhenThePackHasNoStories() async throws {
        // Any story plays on any canvas (visitors come in): a pack with no
        // fallback still plays; only an empty one cannot.
        let owl = try await deterministicProvider().story(
            for: canvas(["fox"]), in: makePack(stories: [story("needs-owl", required: ["owl"])]), language: "en-US")
        #expect(owl.id == "needs-owl")
        await #expect(throws: StoryProviderError.noPlayableStory) {
            _ = try await deterministicProvider().story(for: canvas(["fox"]), in: makePack(stories: []), language: "en-US")
        }
    }

    @Test func theRandomPickStaysAmongTheBest() async throws {
        // Force the "random" pick to the upper bound: it takes the last of the
        // tied best, never a worse match.
        let provider = BundledStoryProvider(recents: MemoryRecents(), random: { $0.upperBound })
        let pack = makePack(stories: [
            story("fox-a", required: ["fox"]),
            story("fox-b", required: ["fox"]),
            story("needs-owl", required: ["owl"]),
            story("fallback"),
        ])
        var heard: [String] = []
        for _ in 0..<4 { heard.append(try await provider.story(for: canvas(["fox"]), in: pack, language: "en-US").id) }
        #expect(heard == ["fox-b", "fox-a", "fallback", "needs-owl"])
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

@Suite struct EffectsSidecarSelectionTests {
    private func packWithSidecars(_ contents: [String: String?], includeFallback: Bool = true) throws -> LoadedPack {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("audio/en-US"), withIntermediateDirectories: true)
        var stories: [StoryDefinition] = []
        for (id, sidecar) in contents {
            var localizations: [String: StoryLocalization] = [:]
            for lang in ["en-US", "es-ES"] {
                localizations[lang] = StoryLocalization(
                    title: id, text: "Text of \(id).", audio: "audio/\(lang)/\(id).m4a",
                    effects: sidecar == nil ? nil : "audio/\(lang)/\(id).effects.json")
            }
            if let sidecar {
                try Data(sidecar.utf8).write(to: dir.appendingPathComponent("audio/en-US/\(id).effects.json"))
            }
            stories.append(StoryDefinition(id: id, requiredStickers: ["fox"], localizations: localizations))
        }
        if includeFallback { stories.append(story("fallback")) }
        let manifest = PackManifest(
            schemaVersion: 2, id: "forest", version: 1, languages: ["en-US", "es-ES"],
            displayName: localized("Forest", "Bosque"), theme: "forest",
            background: "art/b.png", foreground: "art/f.png",
            stickers: [StickerDefinition(id: "fox", name: localized("Fox", "Zorro"), image: "stickers/fox.png")],
            stories: stories)
        return LoadedPack(manifest: manifest, baseURL: dir, source: .bundled)
    }

    @Test func storyWithMalformedSidecarIsExcluded() async throws {
        let pack = try packWithSidecars(["broken": "{ not json", "fine": "{\"schema\": 1, \"triggers\": []}"])
        // Both score identically (fox required); with the deterministic pick
        // the first in pool order wins — the broken one must never be it.
        for _ in 0..<5 {
            let chosen = try await deterministicProvider().story(for: canvas(["fox"]), in: pack, language: "en-US")
            #expect(chosen.id != "broken")
        }
    }

    @Test func brokenSidecarLosesToAValidFallback() async throws {
        let pack = try packWithSidecars(["broken": "{ not json"])
        let chosen = try await deterministicProvider().story(for: canvas(["fox"]), in: pack, language: "en-US")
        #expect(chosen.id == "fallback")
    }

    @Test func playStillWorksWhenEverySidecarIsBroken() async throws {
        let pack = try packWithSidecars(["broken": "{ not json"], includeFallback: false)
        let chosen = try await deterministicProvider().story(for: canvas(["fox"]), in: pack, language: "en-US")
        #expect(chosen.id == "broken")  // played without effects rather than failing
    }
}

@Suite struct ForestSelectionTests {
    func forest() throws -> LoadedPack? {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let dir = repoRoot.appendingPathComponent("packs/forest")
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) else { return nil }
        return try PackLoader().loadPack(at: dir, source: .bundled)
    }

    @Test func aWholeSessionOnAnEmptyCanvasPlaysEveryStoryOnce() async throws {
        guard let pack = try forest() else { return }
        let provider = BundledStoryProvider(recents: MemoryRecents())
        var heard: [String] = []
        for _ in pack.manifest.stories {
            heard.append(try await provider.story(for: canvas([]), in: pack, language: "en-US").id)
        }
        #expect(Set(heard).count == pack.manifest.stories.count)
    }

    @Test func storiesAboutWhatIsPlacedComeFirst() async throws {
        guard let pack = try forest() else { return }
        let provider = BundledStoryProvider(recents: MemoryRecents())
        let placed: Set<String> = ["fox", "rabbit"]
        // Featuring them, or with them as supporting characters.
        let about = pack.manifest.stories.filter { !Set($0.requiredStickers + $0.optionalStickers).isDisjoint(with: placed) }
        var heard: [StoryDefinition] = []
        for _ in pack.manifest.stories {
            let id = try await provider.story(for: canvas(Array(placed)), in: pack, language: "en-US").id
            heard.append(pack.manifest.stories.first { $0.id == id }!)
        }
        // Every story once; every one with the fox or the rabbit in it before
        // any other.
        #expect(Set(heard.map(\.id)).count == pack.manifest.stories.count)
        #expect(Set(heard.prefix(about.count).map(\.id)) == Set(about.map(\.id)))
    }
}
