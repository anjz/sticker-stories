import Foundation

/// Remembers which stories played, so selection brings new ones. The app
/// implementation persists the long-term list to UserDefaults and keeps the
/// session's in memory; tests use an in-memory one.
public protocol RecentStoriesStore: Sendable {
    /// Every story played before, most recent first (across launches).
    func recentStoryIDs(forPackID packID: String) -> [String]
    /// The stories played since the app was opened, most recent first.
    func sessionStoryIDs(forPackID packID: String) -> [String]
    func recordPlayed(storyID: String, packID: String)
}

/// v1 `StoryProvider`: picks one of the pack's pregenerated stories for the
/// canvas (docs/architecture.md §"Key design decisions"). Every story is
/// playable on any canvas — a character the child has not placed comes in
/// as a visitor — so the pick is an order, not a filter:
///
/// 1. **Not heard this session** before anything already played since the
///    app opened: nothing repeats until the whole pack has played (then the
///    one played longest ago comes first).
/// 2. **About what the child placed**: any story with a placed sticker in
///    it — featured or supporting — before any story without one (a fallback
///    included), however many visitors it needs.
/// 3. **Best match to the canvas**: each featured sticker on it counts 1,
///    each supporting one 0.5, each featured one missing −0.25 (it has to come
///    in as a visitor) — needing as few visitors as possible; then fewer
///    visitors among equals.
/// 4. **Never heard**, then heard longest ago (across launches).
/// 5. The story's `weight`, then a random pick among exact ties, so an empty
///    canvas still varies.
public struct BundledStoryProvider: StoryProvider {
    /// Match points for a featured sticker on the canvas, a supporting one,
    /// and a featured one that has to come in.
    static let featuredPoint = 1.0
    static let supportingPoint = 0.5
    static let visitorPoint = -0.25

    private let recents: RecentStoriesStore
    private let random: @Sendable (ClosedRange<Double>) -> Double

    public init(
        recents: RecentStoriesStore,
        random: @escaping @Sendable (ClosedRange<Double>) -> Double = { .random(in: $0) }
    ) {
        self.recents = recents
        self.random = random
    }

    /// How well a story fits the canvas, and how many visitors it needs.
    static func match(_ story: StoryDefinition, placed: Set<String>) -> (score: Double, visitors: Int) {
        let required = Set(story.requiredStickers)
        let present = required.intersection(placed).count
        let missing = required.count - present
        let supporting = Set(story.optionalStickers).intersection(placed).count
        let score = Double(present) * featuredPoint + Double(supporting) * supportingPoint + Double(missing) * visitorPoint
        return (score, missing)
    }

    public func story(for canvas: CanvasState, in pack: LoadedPack, language: String) async throws -> Story {
        let placed = canvas.stickerIDs
        let recentIDs = recents.recentStoryIDs(forPackID: pack.id)
        let sessionIDs = recents.sessionStoryIDs(forPackID: pack.id)
        guard !pack.manifest.stories.isEmpty else { throw StoryProviderError.noPlayableStory }

        struct Rank: Comparable {
            // Each "smaller comes first".
            var heardThisSession: Int  // -1 not heard; else how long ago, negated (oldest first)
            var about: Int  // 0 with a placed sticker in it, else 1
            var match: Double  // negated
            var visitors: Int
            var heardBefore: Int  // -1 never; else recency index negated (oldest first)
            var weight: Double  // negated
            static func < (a: Rank, b: Rank) -> Bool {
                (a.heardThisSession, a.about, a.match, a.visitors, a.heardBefore, a.weight)
                    < (b.heardThisSession, b.about, b.match, b.visitors, b.heardBefore, b.weight)
            }
        }
        func rank(_ story: StoryDefinition) -> Rank {
            let fit = Self.match(story, placed: placed)
            return Rank(
                heardThisSession: sessionIDs.firstIndex(of: story.id).map { -$0 } ?? Int.min,
                about: Set(story.requiredStickers + story.optionalStickers).isDisjoint(with: placed) ? 1 : 0,
                match: -fit.score, visitors: fit.visitors,
                heardBefore: recentIDs.firstIndex(of: story.id).map { -$0 } ?? Int.min,
                weight: -story.weight)
        }
        // A story whose effects sidecar is unusable is excluded rather than
        // played broken (docs/effects.md) — unless nothing else is left, in
        // which case it plays with no effects; play must never fail.
        let usable = pack.manifest.stories.filter { Self.hasUsableEffects($0, language: language, in: pack) }
        let ranked = (usable.isEmpty ? pack.manifest.stories : usable).map { ($0, rank($0)) }
        let best = ranked.map(\.1).min()!
        // Every story as good as the best, in manifest order: a random one.
        let ties = ranked.filter { $0.1 == best }.map(\.0)
        let index = min(Int(random(0...Double(ties.count))), ties.count - 1)
        let chosen = ties[max(index, 0)]

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
