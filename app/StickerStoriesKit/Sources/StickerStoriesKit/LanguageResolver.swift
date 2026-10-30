import Foundation

/// Picks which of a pack's declared languages to use for the current device.
///
/// Matching, per docs/pack-format.md ("Language resolution"):
/// 1. exact tag match, case-insensitive (`es-ES` device → `es-ES` pack);
/// 2. else primary-subtag match (`es-MX` device → `es-ES` pack);
/// 3. else the pack's first declared language (its fallback).
///
/// Chinese goes by script and region rather than by its primary subtag:
/// Traditional Chinese in Hong Kong or Macau, and Cantonese (`yue`), is
/// `zh-HK` (Cantonese narration); any other Traditional Chinese (`zh-Hant`,
/// Taiwan) is `zh-TW`; Simplified Chinese matches neither (no pack has it).
///
/// Pure logic with injectable device preferences so it is unit-testable; the
/// app uses the default `Locale.preferredLanguages`.
public struct LanguageResolver: Sendable {
    private let preferredLanguages: [String]

    public init(preferredLanguages: [String] = Locale.preferredLanguages) {
        self.preferredLanguages = preferredLanguages
    }

    public func resolve(from available: [String]) -> String {
        for preferred in preferredLanguages {
            if let chinese = Self.chinese(preferred) {
                // Only its own kind of Chinese, never another by primary subtag.
                if let match = available.first(where: { Self.chinese($0) == chinese }) { return match }
                continue
            }
            if let exact = available.first(where: {
                $0.caseInsensitiveCompare(preferred) == .orderedSame
            }) {
                return exact
            }
            let preferredPrimary = Self.primarySubtag(preferred)
            if let primaryMatch = available.first(where: {
                Self.primarySubtag($0) == preferredPrimary
            }) {
                return primaryMatch
            }
        }
        return available.first ?? "en-US"
    }

    /// Which Chinese a tag is: `zh-HK` (Hong Kong, Macau, Cantonese),
    /// `zh-TW` (other Traditional), `zh-Hans` (Simplified); nil for any
    /// other language.
    public static func chinese(_ tag: String) -> String? {
        let parts = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.lowercased() }
        guard let primary = parts.first, primary == "zh" || primary == "yue" else { return nil }
        if primary == "yue" || parts.contains("hk") || parts.contains("mo") { return "zh-HK" }
        if parts.contains("hant") || parts.contains("tw") { return "zh-TW" }
        return "zh-Hans"
    }

    public static func primarySubtag(_ tag: String) -> String {
        tag.split(separator: "-").first.map { $0.lowercased() } ?? tag.lowercased()
    }
}
