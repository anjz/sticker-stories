import Foundation
import StickerStoriesKit

/// Persists recently played story IDs per pack in UserDefaults.
/// Compliance note: app-internal state only, no personal data — covered by
/// the CA92.1 declaration in PrivacyInfo.xcprivacy.
struct UserDefaultsRecentStories: RecentStoriesStore {
    private static let maxStored = 10

    func recentStoryIDs(forPackID packID: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: Self.key(packID)) ?? []
    }

    func recordPlayed(storyID: String, packID: String) {
        var recent = recentStoryIDs(forPackID: packID)
        recent.removeAll { $0 == storyID }
        recent.insert(storyID, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(Self.maxStored)), forKey: Self.key(packID))
    }

    private static func key(_ packID: String) -> String { "recentStories.\(packID)" }
}
