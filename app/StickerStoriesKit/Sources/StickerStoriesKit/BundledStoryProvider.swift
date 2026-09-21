import Foundation

/// Remembers which stories played recently so they can be deprioritised.
/// The app implementation persists to UserDefaults; tests use an in-memory one.
public protocol RecentStoriesStore: Sendable {
    /// Most recent first.
    func recentStoryIDs(forPackID packID: String) -> [String]
    func recordPlayed(storyID: String, packID: String)
}

/// v1 `StoryProvider`: scores the pack's pregenerated stories against the
/// canvas (docs/architecture.md §"Key design decisions").
///
/// - Candidates: stories with at most one of their `requiredStickers`
///   missing from the canvas (and at least one present). Stories are written
///   to read fine without any particular sticker — a cue for a missing one
///   simply never fires — and requiring every featured sticker left most of
///   a pack unreachable from an ordinary canvas. Fallback stories (no
///   required stickers) are always candidates, so play never fails.
/// - Score: present required + optional sticker matches, times the story's
///   weight; a story with a sticker missing scores well under a full match.
/// - Pick: candidates are ranked by staleness first — never played, then
///   longest ago — and score second, and a weighted random is drawn among
///   the top few. So the best match is likely first on a fresh canvas, every
///   candidate is heard before any repeats, and the last one played is
///   always last in line.
public struct BundledStoryProvider: StoryProvider {
    /// How many top candidates the random pick draws from.
    private static let topPool = 3
    /// How many required stickers a candidate may be missing.
    private static let maxMissingRequired = 1
    /// Score factor for a candidate missing a required sticker.
    private static let missingPenalty = 0.6

    private let recents: RecentStoriesStore
    private let random: @Sendable (ClosedRange<Double>) -> Double

    public init(
        recents: RecentStoriesStore,
        random: @escaping @Sendable (ClosedRange<Double>) -> Double = { .random(in: $0) }
    ) {
        self.recents = recents
        self.random = random
    }

    public func story(for canvas: CanvasState, in pack: LoadedPack, language: String) async throws -> Story {
        let placed = canvas.stickerIDs
        let recentIDs = recents.recentStoryIDs(forPackID: pack.id)  // most recent first

        var scored: [(story: StoryDefinition, score: Double)] = []
        for story in pack.manifest.stories {
            let required = Set(story.requiredStickers)
            let present = required.intersection(placed).count
            let missing = required.count - present
            guard missing <= Self.maxMissingRequired, required.isEmpty || present > 0 else { continue }

            let optionalMatches = story.optionalStickers.filter(placed.contains).count
            // Present required matches count too: a story specifically about
            // what's on the canvas beats a generic fallback.
            var score = (1.0 + Double(present) + Double(optionalMatches)) * story.weight
            if missing > 0 { score *= Self.missingPenalty }
            scored.append((story, score))
        }

        guard !scored.isEmpty else { throw StoryProviderError.noPlayableStory }

        // Stalest first (never played counts as stalest), best score among
        // equals; a stable sort keeps manifest order for full ties.
        func staleness(_ story: StoryDefinition) -> Int {
            recentIDs.firstIndex(of: story.id) ?? .max  // index 0 = played last
        }
        let ranked = scored.sorted { a, b in
            let sa = staleness(a.story), sb = staleness(b.story)
            return sa != sb ? sa > sb : a.score > b.score
        }
        // A story whose effects sidecar is unusable is excluded rather than
        // played broken (docs/effects.md) — unless nothing else is left, in
        // which case it plays with no effects; play must never fail.
        var pool = Array(ranked.lazy.filter { Self.hasUsableEffects($0.story, language: language, in: pack) }.prefix(Self.topPool))
        if pool.isEmpty { pool = Array(ranked.prefix(Self.topPool)) }
        let total = pool.reduce(0) { $0 + $1.score }
        var pick = random(0...max(total, .ulpOfOne))
        var chosen = pool[pool.count - 1].story
        for entry in pool {
            pick -= entry.score
            if pick <= 0 {
                chosen = entry.story
                break
            }
        }

        recents.recordPlayed(storyID: chosen.id, packID: pack.id)
        return Story(chosen, language: language, fallbackOrder: pack.manifest.languages)
    }

    private static func hasUsableEffects(_ story: StoryDefinition, language: String, in pack: LoadedPack) -> Bool {
        guard let path = story.localization(for: language, fallbackOrder: pack.manifest.languages)?.effects else {
            return true
        }
        return (try? EffectTriggerFile.load(from: pack.url(forAssetPath: path))) != nil
    }
}
