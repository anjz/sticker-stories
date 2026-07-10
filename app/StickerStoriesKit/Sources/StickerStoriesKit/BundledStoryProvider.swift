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
/// - Candidates: stories whose `requiredStickers` are all on the canvas.
///   Fallback stories (no required stickers) are always candidates, so play
///   never fails.
/// - Score: required + optional sticker matches, times the story's weight,
///   damped for recently played stories.
/// - Pick: weighted random among the top candidates, so the same canvas can
///   tell a different story next time.
public struct BundledStoryProvider: StoryProvider {
    /// How many recent stories carry a penalty.
    private static let recentWindow = 5
    /// How many top candidates the random pick draws from.
    private static let topPool = 3

    private let recents: RecentStoriesStore
    private let random: @Sendable (ClosedRange<Double>) -> Double

    public init(
        recents: RecentStoriesStore,
        random: @escaping @Sendable (ClosedRange<Double>) -> Double = { .random(in: $0) }
    ) {
        self.recents = recents
        self.random = random
    }

    public func story(for canvas: CanvasState, in pack: LoadedPack) async throws -> Story {
        let placed = canvas.stickerIDs
        let recentIDs = recents.recentStoryIDs(forPackID: pack.id)

        var scored: [(story: StoryDefinition, score: Double)] = []
        for story in pack.manifest.stories {
            let required = Set(story.requiredStickers)
            guard required.isSubset(of: placed) else { continue }

            let optionalMatches = story.optionalStickers.filter(placed.contains).count
            // Required matches count too: a story specifically about what's on
            // the canvas beats a generic fallback.
            var score = (1.0 + Double(required.count) + Double(optionalMatches)) * story.weight

            if let recency = recentIDs.prefix(Self.recentWindow).firstIndex(of: story.id) {
                // Played most recently → strongest damping (index 0).
                score *= 0.2 + 0.8 * (Double(recency) / Double(Self.recentWindow))
            }
            scored.append((story, score))
        }

        guard !scored.isEmpty else { throw StoryProviderError.noPlayableStory }

        scored.sort { $0.score > $1.score }
        let pool = Array(scored.prefix(Self.topPool))
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
        return Story(chosen)
    }
}
