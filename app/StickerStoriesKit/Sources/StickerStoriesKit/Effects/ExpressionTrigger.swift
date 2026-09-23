import Foundation

/// One expression change: from `at` seconds into the narration, every placed
/// instance of `stickerID` (or of every sticker, for `EffectTrigger.allStickers`)
/// shows the face `expression` — one of the sticker's `expressions`, or
/// `normal` for its own image. Faces have no duration: a face stays until
/// the next change, and the story's end puts every sticker back to normal.
public struct ExpressionTrigger: Equatable, Sendable {
    /// The sticker's own face.
    public static let normal = "normal"

    public var at: TimeInterval
    /// Optional authoring label ("smiled"); never interpreted by the app.
    public var cue: String?
    public var stickerID: String
    public var expression: String

    public init(at: TimeInterval, cue: String? = nil, stickerID: String, expression: String) {
        self.at = at
        self.cue = cue
        self.stickerID = stickerID
        self.expression = expression
    }
}

/// A story's faces over time. Pure: the face a sticker shows at any moment
/// is the last change up to then that names it or `all`, so seeking or a
/// dropped frame never leaves a face out of step.
public struct ExpressionTimeline: Equatable, Sendable {
    public let triggers: [ExpressionTrigger]

    /// `triggers` in time order (as `EffectTriggerFile` gives them).
    public init(triggers: [ExpressionTrigger]) {
        self.triggers = triggers
    }

    /// The face each of `stickerIDs` shows at `time`, `normal` by default.
    /// A sticker without that face (the pack declares no such variant, as
    /// `all` can ask for) is the caller's to skip: it keeps its face.
    public func expressions(at time: TimeInterval, for stickerIDs: Set<String>) -> [String: String] {
        var out = Dictionary(uniqueKeysWithValues: stickerIDs.map { ($0, ExpressionTrigger.normal) })
        for trigger in triggers where trigger.at <= time {
            if trigger.stickerID == EffectTrigger.allStickers {
                for id in stickerIDs { out[id] = trigger.expression }
            } else if stickerIDs.contains(trigger.stickerID) {
                out[trigger.stickerID] = trigger.expression
            }
        }
        return out
    }

    /// Every sticker/expression pair the story may show for these placed
    /// stickers (`normal` excluded): what to load before playing.
    public func expressionsUsed(by stickerIDs: Set<String>) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for trigger in triggers where trigger.expression != ExpressionTrigger.normal {
            let targets = trigger.stickerID == EffectTrigger.allStickers
                ? stickerIDs : stickerIDs.intersection([trigger.stickerID])
            for id in targets { out[id, default: []].insert(trigger.expression) }
        }
        return out
    }
}
