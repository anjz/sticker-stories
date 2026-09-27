import Foundation

/// The decisions around narration that is delivered per language
/// (`docs/asset-delivery.md`): which language a pack's stories play in when
/// the chosen one hasn't arrived yet, and which languages to keep on the
/// device. Pure — the app says what is on the device — so it is unit-tested.
public enum NarrationPlanner {
    /// The language a pack's stories play in.
    public struct Choice: Equatable, Sendable {
        public var language: String
        /// Not the language asked for: that one's narration isn't on the
        /// device yet, so the parent is told.
        public var isFallback: Bool

        public init(language: String, isFallback: Bool) {
            self.language = language
            self.isFallback = isFallback
        }
    }

    /// Free space for important use above which the previous language's
    /// narration is kept, so switching back needs no network.
    public static let roomToSpareBytes: Int64 = 5_000_000_000

    /// The language to play a pack's stories in: `preferred` when its
    /// narration is on the device; else the most recently used of the
    /// pack's languages that is (`recent`, newest first); else the first of
    /// them that is; nil while none is.
    public static func choose(
        preferred: String, languages: [String], recent: [String], isLocal: (String) -> Bool
    ) -> Choice? {
        if isLocal(preferred) { return Choice(language: preferred, isFallback: false) }
        let candidates = recent.filter { languages.contains($0) } + languages
        return candidates.first { $0 != preferred && isLocal($0) }.map { Choice(language: $0, isFallback: true) }
    }

    /// The languages whose narration can go now. Nothing while the current
    /// language isn't all on the device (one of the others is what plays);
    /// then every other language — except the most recently used of them
    /// when there is room to spare.
    public static func removable(
        current: String, local: Set<String>, currentComplete: Bool, recent: [String], roomToSpare: Bool
    ) -> Set<String> {
        guard currentComplete else { return [] }
        var remove = local.subtracting([current])
        if roomToSpare, let previous = recent.first(where: { $0 != current && local.contains($0) }) {
            remove.remove(previous)
        }
        return remove
    }

    /// `recent` with `language` moved to the front (the newest).
    public static func used(_ language: String, recent: [String]) -> [String] {
        [language] + recent.filter { $0 != language }
    }
}
