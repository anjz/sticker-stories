import Foundation
import Synchronization
import StickerStoriesKit

/// Persists recently played story IDs per pack in UserDefaults, and keeps
/// the ones played since the app opened in memory (a session: no story
/// repeats in it until the whole pack has played).
/// Compliance note: app-internal state only, no personal data — covered by
/// the CA92.1 declaration in PrivacyInfo.xcprivacy.
struct UserDefaultsRecentStories: RecentStoriesStore {
    /// Enough to remember a whole round of a pack (50 stories) so selection
    /// can play every story before repeating one.
    private static let maxStored = 100
    /// This launch's plays by pack, most recent first; gone when the app quits.
    private static let session = Mutex<[String: [String]]>([:])

    func recentStoryIDs(forPackID packID: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: Self.key(packID)) ?? []
    }

    func sessionStoryIDs(forPackID packID: String) -> [String] {
        Self.session.withLock { $0[packID] ?? [] }
    }

    func recordPlayed(storyID: String, packID: String) {
        var recent = recentStoryIDs(forPackID: packID)
        recent.removeAll { $0 == storyID }
        recent.insert(storyID, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(Self.maxStored)), forKey: Self.key(packID))
        Self.session.withLock { session in
            var played = session[packID] ?? []
            played.removeAll { $0 == storyID }
            played.insert(storyID, at: 0)
            session[packID] = played
        }
    }

    private static func key(_ packID: String) -> String { "recentStories.\(packID)" }
}
