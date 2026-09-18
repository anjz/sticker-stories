import Foundation

/// Identifies one running effect so it can be stopped early.
public struct EffectHandle: Hashable, Sendable {
    let id: UUID
    public init() { id = UUID() }
}

/// One effect that has been started on one sticker instance. Immutable
/// apart from `stopTime`; everything about its state at time `t` is derived
/// by `EffectEvaluator` (P3: state is a function of time).
public struct ActiveEffect: Equatable, Sendable, Identifiable {
    public let handle: EffectHandle
    public let name: EffectName
    public let target: UUID
    /// Timeline time (seconds) at which the first cycle begins.
    public let startTime: TimeInterval
    /// Already clamped, with the effect's default colour filled in.
    public let options: EffectOptions
    /// Start order; the later-started effect wins anchor/colour conflicts.
    public let sequence: Int
    /// When set, the effect eases back to identity from this time (§4.2).
    public var stopTime: TimeInterval? = nil

    public var id: EffectHandle { handle }

    public init(
        handle: EffectHandle = EffectHandle(), name: EffectName, target: UUID,
        startTime: TimeInterval, options: EffectOptions, sequence: Int, stopTime: TimeInterval? = nil
    ) {
        self.handle = handle
        self.name = name
        self.target = target
        self.startTime = startTime
        self.options = options.clamped
        self.sequence = sequence
        self.stopTime = stopTime
    }

    public var definition: EffectDefinition { EffectDefinition.definition(for: name) }

    public var cycleDuration: TimeInterval {
        options.duration ?? definition.defaultDuration
    }

    /// Number of cycles, or `nil` for `loop`. One-way effects always run once.
    public var cycleCount: Int? {
        if name.isOneWay { return 1 }
        switch options.repeatCount {
        case .times(let n): return n
        case .loop: return nil
        }
    }

    /// Seconds from `startTime` until the last cycle ends; `nil` for `loop`.
    public var activeDuration: TimeInterval? {
        cycleCount.map { Double($0) * cycleDuration }
    }

    /// True when the end state is kept after the last cycle (`hold`, or a
    /// one-way effect — which keeps its end state until its ease-back).
    var keepsEndState: Bool {
        name.isOneWay || (options.hold && name.supportsHold)
    }

    /// True when `hold` genuinely keeps the effect on until `stopAll`.
    public var holdsAfterEnd: Bool { options.hold && name.supportsHold }

    /// Where within the curve the held end state sits: glow/tint hold at
    /// their peak (the cycle becomes rise-only), fades hold at their end.
    var holdPhase: Double { name.isOneWay ? 1 : 0.5 }

    /// With `hold`, glow and tint spend the whole duration rising to the peak.
    var isRiseOnly: Bool { holdsAfterEnd && !name.isOneWay }
}

/// Where an effect is on its timeline at a given time.
public enum EffectStatus: Equatable, Sendable {
    case pending
    case running(cycle: Int, phase: Double)
    /// Past its last cycle but still contributing (hold / one-way end state).
    case holding
    /// Stopped early or finished; contributes nothing.
    case finished
}

/// Pure: (active effects, time) → per-sticker deltas. No SpriteKit, no
/// audio, no clock; this is the piece the unit tests pin down.
public enum EffectEvaluator {
    /// How long a stopped effect takes to ease back to identity.
    public static let easeBackDuration: TimeInterval = 0.25

    public static func deltas(for effects: [ActiveEffect], at time: TimeInterval) -> [UUID: EffectDelta] {
        var result: [UUID: EffectDelta] = [:]
        for effect in effects.sorted(by: { $0.sequence < $1.sequence }) {
            let delta = delta(of: effect, at: time)
            result[effect.target] = (result[effect.target] ?? .identity).combined(with: delta)
        }
        return result
    }

    public static func status(of effect: ActiveEffect, at time: TimeInterval) -> EffectStatus {
        if isFinished(effect, at: time) { return .finished }
        let local = time - effect.startTime
        if local < 0 { return .pending }
        if let active = effect.activeDuration, local >= active { return .holding }
        let cycle = Int(local / effect.cycleDuration)
        let phase = (local - Double(cycle) * effect.cycleDuration) / effect.cycleDuration
        return .running(cycle: cycle, phase: phase)
    }

    /// The effect's contribution at `time`, including any ease-back after a stop.
    public static func delta(of effect: ActiveEffect, at time: TimeInterval) -> EffectDelta {
        guard let stopTime = effect.stopTime, time >= stopTime else {
            return rawDelta(of: effect, at: time)
        }
        let ease = easeBackDuration(of: effect, stoppingAt: stopTime)
        guard ease > 0 else { return identity(for: effect) }
        let progress = (time - stopTime) / ease
        guard progress < 1 else { return identity(for: effect) }
        return rawDelta(of: effect, at: time).blendedTowardIdentity(progress)
    }

    /// True when the effect no longer contributes and can be retired.
    public static func isFinished(_ effect: ActiveEffect, at time: TimeInterval) -> Bool {
        if let stopTime = effect.stopTime {
            return time >= stopTime + easeBackDuration(of: effect, stoppingAt: stopTime)
        }
        guard let active = effect.activeDuration else { return false }
        return time - effect.startTime >= active && !effect.keepsEndState
    }

    /// `min(0.25s, remaining cycle time)` for a running effect; the full
    /// 0.25s for a held end state; 0 (snap) for one that never started.
    static func easeBackDuration(of effect: ActiveEffect, stoppingAt stopTime: TimeInterval) -> TimeInterval {
        let local = stopTime - effect.startTime
        if local < 0 { return 0 }
        if let active = effect.activeDuration, local >= active { return easeBackDuration }
        let remaining = effect.cycleDuration - local.truncatingRemainder(dividingBy: effect.cycleDuration)
        return min(easeBackDuration, remaining)
    }

    /// The curve value ignoring any stop request.
    static func rawDelta(of effect: ActiveEffect, at time: TimeInterval) -> EffectDelta {
        let local = time - effect.startTime
        if local < 0 { return identity(for: effect) }
        let definition = effect.definition
        let intensity = effect.options.intensity
        if let active = effect.activeDuration, local >= active {
            guard effect.keepsEndState else { return identity(for: effect) }
            return colored(definition.delta(atPhase: effect.holdPhase, intensity: intensity, cycleDuration: effect.cycleDuration), effect)
        }
        let cycle = (local / effect.cycleDuration).rounded(.down)
        var phase = (local - cycle * effect.cycleDuration) / effect.cycleDuration
        if effect.isRiseOnly { phase *= effect.holdPhase }
        return colored(definition.delta(atPhase: phase, intensity: intensity, cycleDuration: effect.cycleDuration), effect)
    }

    private static func identity(for effect: ActiveEffect) -> EffectDelta {
        var delta = EffectDelta.identity
        delta.anchor = effect.definition.anchor
        return delta
    }

    private static func colored(_ delta: EffectDelta, _ effect: ActiveEffect) -> EffectDelta {
        var delta = delta
        switch effect.name {
        case .glow: delta.glowColor = effect.options.color
        case .tint: delta.tintColor = effect.options.color
        default: break
        }
        return delta
    }
}
