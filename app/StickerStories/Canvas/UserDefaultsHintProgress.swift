import Foundation
import StickerStoriesKit

/// Remembers, app-wide, which canvas gestures the child has ever used
/// (pinch, layer button) so their hints stop, and whether any pack has
/// ever been opened (the first time, the hints come right away).
/// Compliance note: app-internal state only, never sent anywhere —
/// covered by the CA92.1 declaration in PrivacyInfo.xcprivacy, like
/// `UserDefaultsRecentStories`.
struct UserDefaultsHintProgress: HintProgressStore {
    func usedHints() -> Set<CanvasHint> {
        #if DEBUG
        // Screenshots and tuning: every hint, as if never used.
        if ProcessInfo.processInfo.arguments.contains("-hintsDemo") { return [] }
        #endif
        return Set(CanvasHint.allCases.filter { UserDefaults.standard.bool(forKey: Self.key($0)) })
    }

    func markUsed(_ hint: CanvasHint) {
        UserDefaults.standard.set(true, forKey: Self.key(hint))
    }

    func hasOpenedAPack() -> Bool {
        UserDefaults.standard.bool(forKey: Self.openedAPackKey)
    }

    func markOpenedAPack() {
        UserDefaults.standard.set(true, forKey: Self.openedAPackKey)
    }

    private static let openedAPackKey = "hints.openedAPack"

    private static func key(_ hint: CanvasHint) -> String { "hints.used.\(hint.rawValue)" }
}
