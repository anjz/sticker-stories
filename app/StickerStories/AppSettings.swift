import Foundation
import Observation
import StickerStoriesKit

/// Parent-adjustable settings, edited only behind the parental gate.
/// Persisted in UserDefaults (app-internal state, covered by the CA92.1
/// privacy declaration).
@MainActor
@Observable
final class AppSettings {
    private static let languageOverrideKey = "settings.languageOverride"

    /// BCP-47 tag ("en-US", "es-ES") or nil to follow the device language.
    var languageOverride: String? {
        didSet {
            if let languageOverride {
                UserDefaults.standard.set(languageOverride, forKey: Self.languageOverrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.languageOverrideKey)
            }
        }
    }

    init() {
        languageOverride = UserDefaults.standard.string(forKey: Self.languageOverrideKey)
    }

    /// What `LanguageResolver` should match pack languages against: the
    /// override (when set) wins, then the device preferences as fallback.
    var preferredLanguages: [String] {
        if let languageOverride {
            return [languageOverride] + Locale.preferredLanguages
        }
        return Locale.preferredLanguages
    }

    /// Locale for SwiftUI's environment so UI text follows the override
    /// live. Uses the primary subtag ("es") to match the String Catalog's
    /// language identifiers; nil means follow the system.
    var uiLocale: Locale? {
        languageOverride.map { Locale(identifier: LanguageResolver.primarySubtag($0)) }
    }
}
