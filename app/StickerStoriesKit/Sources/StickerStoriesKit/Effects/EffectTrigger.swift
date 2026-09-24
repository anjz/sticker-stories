import Foundation

/// One resolved, declarative trigger: at `at` seconds into the narration,
/// run `effect` on every placed instance of `stickerID`.
public struct EffectTrigger: Equatable, Sendable {
    /// The reserved sticker target meaning every placed sticker (a pack may
    /// not name a sticker this).
    public static let allStickers = "all"

    public var at: TimeInterval
    /// Optional authoring label ("sneeze"); never interpreted by the app.
    public var cue: String?
    public var stickerID: String
    public var effect: EffectName
    public var options: EffectOptions

    public init(at: TimeInterval, cue: String? = nil, stickerID: String, effect: EffectName, options: EffectOptions = EffectOptions()) {
        self.at = at
        self.cue = cue
        self.stickerID = stickerID
        self.effect = effect
        self.options = options
    }
}

/// A story's per-language effects sidecar (`docs/effects.md`, "Trigger file").
/// One `triggers` list carries three kinds: an entry whose `effect` names a
/// sticker effect targets a `sticker`; one naming a canvas effect has no
/// sticker and lands in `canvasTriggers`; one naming an `animation` (and
/// no effect) plays that sticker's live animation and lands in
/// `liveTriggers`.
///
/// Decoding follows the spec's non-fatal rules: unknown effect → skip,
/// unknown keys → ignore, out-of-range numbers → clamp, missing effect or
/// sticker → skip, all reported in `warnings`. Only malformed JSON, a wrong
/// root shape or an unsupported `schema` throw — and the story provider then
/// excludes that story rather than surfacing an error to a child.
public struct EffectTriggerFile: Equatable, Sendable {
    public static let supportedSchema = 1

    public var schema: Int
    public var triggers: [EffectTrigger]
    public var canvasTriggers: [CanvasEffectTrigger]
    public var liveTriggers: [LiveAnimationTrigger]
    public var expressionTriggers: [ExpressionTrigger]
    /// Where the story first names each sticker (`docs/effects.md`,
    /// "Entrances"), in time order, one per sticker.
    public var entranceTriggers: [EntranceTrigger]
    public var warnings: [String]

    public enum DecodingError: Error, Equatable {
        case malformedJSON(String)
        case unsupportedSchema(Int)
        case wrongShape(String)
    }

    public init(
        schema: Int = EffectTriggerFile.supportedSchema, triggers: [EffectTrigger],
        canvasTriggers: [CanvasEffectTrigger] = [], liveTriggers: [LiveAnimationTrigger] = [],
        expressionTriggers: [ExpressionTrigger] = [], entranceTriggers: [EntranceTrigger] = [],
        warnings: [String] = []
    ) {
        self.schema = schema
        self.triggers = triggers
        self.canvasTriggers = canvasTriggers
        self.liveTriggers = liveTriggers
        self.expressionTriggers = expressionTriggers
        self.entranceTriggers = entranceTriggers
        self.warnings = warnings
    }

    public static func load(from url: URL) throws -> EffectTriggerFile {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw DecodingError.malformedJSON("unreadable: \(error)") }
        return try EffectTriggerFile(data: data)
    }

    public init(data: Data) throws {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) } catch { throw DecodingError.malformedJSON(String(describing: error)) }
        guard let object = root as? [String: Any] else { throw DecodingError.wrongShape("root must be an object") }

        var warnings: [String] = []
        if let raw = object["schema"] {
            guard let schema = Self.integer(raw) else { throw DecodingError.wrongShape("schema must be an integer") }
            guard schema <= Self.supportedSchema else { throw DecodingError.unsupportedSchema(schema) }
            self.schema = schema
        } else {
            warnings.append("schema missing; assuming \(Self.supportedSchema)")
            self.schema = Self.supportedSchema
        }
        guard let list = object["triggers"] as? [Any] else { throw DecodingError.wrongShape("triggers must be an array") }

        var triggers: [EffectTrigger] = []
        var canvasTriggers: [CanvasEffectTrigger] = []
        var liveTriggers: [LiveAnimationTrigger] = []
        var expressionTriggers: [ExpressionTrigger] = []
        var entranceTriggers: [EntranceTrigger] = []
        for (index, entry) in list.enumerated() {
            let label = "triggers[\(index)]"
            guard let fields = entry as? [String: Any] else {
                warnings.append("\(label): not an object; skipped")
                continue
            }
            if fields["enter"] != nil {
                if let trigger = Self.decodeEntranceTrigger(fields, label: label, warnings: &warnings) {
                    if entranceTriggers.contains(where: { $0.stickerID == trigger.stickerID }) {
                        warnings.append("\(label): \(trigger.stickerID) already enters; skipped")
                    } else {
                        entranceTriggers.append(trigger)
                    }
                }
                continue
            }
            if fields["expression"] != nil {
                if let trigger = Self.decodeExpressionTrigger(fields, label: label, warnings: &warnings) {
                    expressionTriggers.append(trigger)
                }
                continue
            }
            if fields["animation"] != nil {
                if let trigger = Self.decodeLiveTrigger(fields, label: label, warnings: &warnings) {
                    liveTriggers.append(trigger)
                }
                continue
            }
            guard let name = fields["effect"] as? String else {
                warnings.append("\(label): missing effect; skipped")
                continue
            }
            if let effect = EffectName(rawValue: name) {
                if let trigger = Self.decodeTrigger(effect, fields, label: label, warnings: &warnings) {
                    triggers.append(trigger)
                }
            } else if let effect = CanvasEffectName(rawValue: name) {
                if let trigger = Self.decodeCanvasTrigger(effect, fields, label: label, warnings: &warnings) {
                    canvasTriggers.append(trigger)
                }
            } else {
                warnings.append("\(label): unknown effect \"\(name)\"; skipped")
            }
        }
        self.triggers = triggers.sorted { $0.at < $1.at }
        self.canvasTriggers = canvasTriggers.sorted { $0.at < $1.at }
        self.liveTriggers = liveTriggers.sorted { $0.at < $1.at }
        // Stable: two expression changes at the same moment keep file order.
        self.expressionTriggers = expressionTriggers.enumerated()
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        self.entranceTriggers = entranceTriggers.sorted { $0.at < $1.at }
        self.warnings = warnings
    }

    /// Entrances name one sticker (never `all`) and say `"enter": true`.
    private static func decodeEntranceTrigger(_ fields: [String: Any], label: String, warnings: inout [String]) -> EntranceTrigger? {
        guard let enter = fields["enter"] as? NSNumber, CFGetTypeID(enter) == CFBooleanGetTypeID(), enter.boolValue else {
            warnings.append("\(label): enter must be true; skipped")
            return nil
        }
        guard let stickerID = fields["sticker"] as? String, !stickerID.isEmpty, stickerID != EffectTrigger.allStickers else {
            warnings.append("\(label): an entrance needs one sticker; skipped")
            return nil
        }
        guard let at = number(fields["at"]), at.isFinite, at >= 0 else {
            warnings.append("\(label): missing or invalid at; skipped")
            return nil
        }
        for key in ["effect", "animation", "expression", "repeat", "duration", "intensity", "color", "hold"] where fields[key] != nil {
            warnings.append("\(label): \(key) is ignored by an entrance")
        }
        return EntranceTrigger(at: at, cue: fields["cue"] as? String, stickerID: stickerID)
    }

    private static func decodeTrigger(_ effect: EffectName, _ fields: [String: Any], label: String, warnings: inout [String]) -> EffectTrigger? {
        guard let stickerID = fields["sticker"] as? String, !stickerID.isEmpty else {
            warnings.append("\(label): missing sticker; skipped")
            return nil
        }
        guard let at = number(fields["at"]), at.isFinite, at >= 0 else {
            warnings.append("\(label): missing or invalid at; skipped")
            return nil
        }

        var options = EffectOptions()
        if let raw = fields["repeat"] {
            if let text = raw as? String, text == "loop" {
                options.repeatCount = .loop
            } else if let n = integer(raw) {
                if n < 1 || n > RepeatCount.maxTimes { warnings.append("\(label): repeat \(n) clamped to 1...\(RepeatCount.maxTimes)") }
                options.repeatCount = .times(n)
            } else {
                warnings.append("\(label): repeat must be an integer or \"loop\"; using 1")
            }
            if effect.isOneWay { warnings.append("\(label): repeat is ignored for \(effect.rawValue)") }
        }
        if let raw = fields["duration"] {
            if let d = number(raw), d.isFinite {
                if !EffectOptions.durationRange.contains(d) { warnings.append("\(label): duration \(d) clamped to 0.05...30") }
                options.duration = d
            } else {
                warnings.append("\(label): duration must be a number; using the default")
            }
        }
        if let raw = fields["intensity"] {
            if let i = number(raw), i.isFinite {
                if i < 0 || i > 1 { warnings.append("\(label): intensity \(i) clamped to 0...1") }
                options.intensity = i
            } else {
                warnings.append("\(label): intensity must be a number; using the default")
            }
        }
        if let raw = fields["color"] {
            if let text = raw as? String, let color = RGBA(hex: text) {
                options.color = color
            } else {
                warnings.append("\(label): malformed color; ignored")
            }
            if !effect.readsColor { warnings.append("\(label): color is ignored by \(effect.rawValue)") }
        }
        if let raw = fields["hold"] {
            if let hold = raw as? Bool {
                options.hold = hold
                if hold && !effect.supportsHold { warnings.append("\(label): hold is ignored by \(effect.rawValue)") }
            } else {
                warnings.append("\(label): hold must be true or false; ignored")
            }
        }
        if effect.requiresColor && options.color == nil {
            warnings.append("\(label): \(effect.rawValue) requires a color; skipped")
            return nil
        }
        return EffectTrigger(
            at: at, cue: fields["cue"] as? String, stickerID: stickerID, effect: effect,
            options: options.clamped)
    }

    /// Canvas triggers take `intensity` and `duration` only; the sticker
    /// keys are reported and ignored.
    private static func decodeCanvasTrigger(_ effect: CanvasEffectName, _ fields: [String: Any], label: String, warnings: inout [String]) -> CanvasEffectTrigger? {
        guard let at = number(fields["at"]), at.isFinite, at >= 0 else {
            warnings.append("\(label): missing or invalid at; skipped")
            return nil
        }
        var options = CanvasEffectOptions()
        if let raw = fields["duration"] {
            if let d = number(raw), d.isFinite {
                if !CanvasEffectOptions.durationRange.contains(d) {
                    warnings.append("\(label): duration \(d) clamped to \(CanvasEffectOptions.durationRange.lowerBound)...\(CanvasEffectOptions.durationRange.upperBound)")
                }
                options.duration = d
            } else {
                warnings.append("\(label): duration must be a number; using the default")
            }
        }
        if let raw = fields["intensity"] {
            if let i = number(raw), i.isFinite {
                if i < 0 || i > 1 { warnings.append("\(label): intensity \(i) clamped to 0...1") }
                options.intensity = i
            } else {
                warnings.append("\(label): intensity must be a number; using the default")
            }
        }
        for key in ["sticker", "repeat", "color", "hold"] where fields[key] != nil {
            warnings.append("\(label): \(key) is ignored by canvas effect \(effect.rawValue)")
        }
        return CanvasEffectTrigger(at: at, cue: fields["cue"] as? String, effect: effect, options: options.clamped)
    }

    /// Live triggers name a sticker and one of its animations; nothing
    /// else applies to them, so other keys are reported and ignored.
    private static func decodeLiveTrigger(_ fields: [String: Any], label: String, warnings: inout [String]) -> LiveAnimationTrigger? {
        guard let animationID = fields["animation"] as? String, !animationID.isEmpty else {
            warnings.append("\(label): animation must be a non-empty string; skipped")
            return nil
        }
        guard let stickerID = fields["sticker"] as? String, !stickerID.isEmpty else {
            warnings.append("\(label): missing sticker; skipped")
            return nil
        }
        guard let at = number(fields["at"]), at.isFinite, at >= 0 else {
            warnings.append("\(label): missing or invalid at; skipped")
            return nil
        }
        for key in ["effect", "repeat", "duration", "intensity", "color", "hold"] where fields[key] != nil {
            warnings.append("\(label): \(key) is ignored by a live animation")
        }
        return LiveAnimationTrigger(at: at, cue: fields["cue"] as? String, stickerID: stickerID, animationID: animationID)
    }

    /// Expression triggers name a sticker (or `all`) and an expression; they
    /// have no duration — the face stays until the next one.
    private static func decodeExpressionTrigger(_ fields: [String: Any], label: String, warnings: inout [String]) -> ExpressionTrigger? {
        guard let expression = fields["expression"] as? String, !expression.isEmpty else {
            warnings.append("\(label): expression must be a non-empty string; skipped")
            return nil
        }
        guard let stickerID = fields["sticker"] as? String, !stickerID.isEmpty else {
            warnings.append("\(label): missing sticker; skipped")
            return nil
        }
        guard let at = number(fields["at"]), at.isFinite, at >= 0 else {
            warnings.append("\(label): missing or invalid at; skipped")
            return nil
        }
        for key in ["effect", "animation", "repeat", "duration", "intensity", "color", "hold"] where fields[key] != nil {
            warnings.append("\(label): \(key) is ignored by an expression")
        }
        return ExpressionTrigger(at: at, cue: fields["cue"] as? String, stickerID: stickerID, expression: expression)
    }

    private static func number(_ raw: Any?) -> Double? {
        switch raw {
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): return n.doubleValue
        default: return nil
        }
    }

    private static func integer(_ raw: Any?) -> Int? {
        guard let value = number(raw), value == value.rounded(), abs(value) < Double(Int32.max) else { return nil }
        return Int(value)
    }
}
