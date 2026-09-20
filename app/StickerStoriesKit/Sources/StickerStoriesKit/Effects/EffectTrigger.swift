import Foundation

/// One resolved, declarative trigger: at `at` seconds into the narration,
/// run `effect` on every placed instance of `stickerID`.
public struct EffectTrigger: Equatable, Sendable {
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
/// One `triggers` list carries both kinds: an entry whose `effect` names a
/// sticker effect targets a `sticker`; one naming a canvas effect has no
/// sticker and lands in `canvasTriggers`.
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
    public var warnings: [String]

    public enum DecodingError: Error, Equatable {
        case malformedJSON(String)
        case unsupportedSchema(Int)
        case wrongShape(String)
    }

    public init(
        schema: Int = EffectTriggerFile.supportedSchema, triggers: [EffectTrigger],
        canvasTriggers: [CanvasEffectTrigger] = [], warnings: [String] = []
    ) {
        self.schema = schema
        self.triggers = triggers
        self.canvasTriggers = canvasTriggers
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
        for (index, entry) in list.enumerated() {
            let label = "triggers[\(index)]"
            guard let fields = entry as? [String: Any] else {
                warnings.append("\(label): not an object; skipped")
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
        self.warnings = warnings
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
