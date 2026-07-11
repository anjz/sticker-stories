import Foundation

/// Picks which of a pack's declared languages to use for the current device.
///
/// Matching, per docs/pack-format.md ("Language resolution"):
/// 1. exact tag match, case-insensitive (`es-ES` device → `es-ES` pack);
/// 2. else primary-subtag match (`es-MX` device → `es-ES` pack);
/// 3. else the pack's first declared language (its fallback).
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

    static func primarySubtag(_ tag: String) -> String {
        tag.split(separator: "-").first.map { $0.lowercased() } ?? tag.lowercased()
    }
}
