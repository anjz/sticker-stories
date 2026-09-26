import Foundation
import os

/// Identifies one running canvas effect so it can be stopped early.
public struct CanvasEffectHandle: Hashable, Sendable {
    let id: UUID
    public init() { id = UUID() }
}

/// One canvas effect that has been started. Immutable apart from
/// `stopTime`; its strength at any time is derived by `CanvasEffectEvaluator`.
public struct ActiveCanvasEffect: Equatable, Sendable, Identifiable {
    public let handle: CanvasEffectHandle
    public let name: CanvasEffectName
    /// Timeline time (seconds) at which the effect starts building up.
    public let startTime: TimeInterval
    /// Already clamped.
    public let options: CanvasEffectOptions
    /// Start order (for stable iteration).
    public let sequence: Int
    /// When set, the effect clears from this time over its ramp-out.
    public var stopTime: TimeInterval? = nil

    public var id: CanvasEffectHandle { handle }

    public init(
        handle: CanvasEffectHandle = CanvasEffectHandle(), name: CanvasEffectName,
        startTime: TimeInterval, options: CanvasEffectOptions, sequence: Int, stopTime: TimeInterval? = nil
    ) {
        self.handle = handle
        self.name = name
        self.startTime = startTime
        self.options = options.clamped
        self.sequence = sequence
        self.stopTime = stopTime
    }

    public var definition: CanvasEffectDefinition { CanvasEffectDefinition.definition(for: name) }

    /// Seconds the effect stays on, ramps included.
    public var duration: TimeInterval { options.duration ?? definition.defaultDuration }

    /// Ramps never eat more than a third of the duration each, so a short
    /// effect still spends a third of its time at full strength.
    public var rampIn: TimeInterval { min(definition.rampIn, duration / 3) }
    public var rampOut: TimeInterval { min(definition.rampOut, duration / 3) }

    public var endTime: TimeInterval { startTime + duration }
}

/// Pure: (active canvas effects, time) → strength per effect kind. The
/// strength is the envelope (0 → 1 → 0 over ramp-in, hold, ramp-out) times
/// the intensity; the scene renders fog at 0.3 as thinner fog, never as
/// fog appearing later.
public enum CanvasEffectEvaluator {
    /// The 0...1 envelope at `time`, ignoring any stop request.
    static func rawLevel(of effect: ActiveCanvasEffect, at time: TimeInterval) -> Double {
        let local = time - effect.startTime
        guard local >= 0, local < effect.duration else { return 0 }
        let rise = effect.rampIn > 0 ? smoothstep(min(1, local / effect.rampIn)) : 1
        let fall = effect.rampOut > 0 ? smoothstep(min(1, (effect.duration - local) / effect.rampOut)) : 1
        return min(rise, fall)
    }

    /// The envelope including the ease-out after a stop.
    public static func level(of effect: ActiveCanvasEffect, at time: TimeInterval) -> Double {
        let raw = rawLevel(of: effect, at: time)
        guard let stopTime = effect.stopTime, time >= stopTime else { return raw }
        guard effect.rampOut > 0 else { return 0 }
        let remaining = 1 - (time - stopTime) / effect.rampOut
        guard remaining > 0 else { return 0 }
        return raw * smoothstep(remaining)
    }

    /// `level × intensity`: what the scene renders.
    public static func strength(of effect: ActiveCanvasEffect, at time: TimeInterval) -> Double {
        level(of: effect, at: time) * effect.options.intensity
    }

    /// True when the effect contributes nothing any more and can be retired.
    public static func isFinished(_ effect: ActiveCanvasEffect, at time: TimeInterval) -> Bool {
        if let stopTime = effect.stopTime {
            // Stopped before it started: nothing to ease out of.
            if stopTime <= effect.startTime { return time >= stopTime }
            return time >= min(stopTime + effect.rampOut, effect.endTime)
        }
        return time >= effect.endTime
    }

    /// Per kind, the strongest contribution (two overlapping rains are one
    /// rain, never a downpour); kinds at zero are omitted.
    public static func strengths(for effects: [ActiveCanvasEffect], at time: TimeInterval) -> [CanvasEffectName: Double] {
        var result: [CanvasEffectName: Double] = [:]
        for effect in effects {
            let strength = strength(of: effect, at: time)
            guard strength > 0 else { continue }
            result[effect.name] = max(result[effect.name] ?? 0, strength)
        }
        return result
    }

    /// Snow lying on the ground, 0...1: it builds while snow falls
    /// (`snowBuild` seconds of full snow to a full cover), stays when the
    /// snowfall stops, and melts under sunshine or sun rays (`sunMelt`) and
    /// rain (`rainMelt`). A pure function of the effects and the time,
    /// integrated from `from` (at `amount`) in small steps.
    public static func snowCover(
        of effects: [ActiveCanvasEffect], from: TimeInterval, amount: Double, to time: TimeInterval
    ) -> Double {
        var amount = amount
        var t = from
        while t < time {
            let dt = min(snowStep, time - t)
            let at = t + dt / 2
            var snow = 0.0, sun = 0.0, rain = 0.0
            for effect in effects {
                let s = strength(of: effect, at: at)
                guard s > 0 else { continue }
                switch effect.name {
                case .snow: snow = max(snow, s)
                case .sunshine, .sunrays: sun = max(sun, s)
                case .rain: rain = max(rain, s)
                default: break
                }
            }
            amount = (amount + (snow / snowBuild - sun / sunMelt - rain / rainMelt) * dt).clamped(to: 0...1)
            t += dt
        }
        return amount
    }

    public static let snowBuild: TimeInterval = 14
    public static let sunMelt: TimeInterval = 6
    public static let rainMelt: TimeInterval = 9
    static let snowStep: TimeInterval = 0.1

    static func smoothstep(_ t: Double) -> Double {
        let x = t.clamped(to: 0...1)
        return x * x * (3 - 2 * x)
    }
}

/// Owns the active canvas effects for one playback, mirroring
/// `StickerEffectsRunner`: created when play starts, discarded when it
/// ends, given the timeline time by `tick(_:)` and never reading a clock.
public final class CanvasEffectsRunner {
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var active: [ActiveCanvasEffect] = []
    /// Snow lying on the ground now, 0...1 (`CanvasEffectEvaluator.snowCover`):
    /// it outlives the snowfall, so it follows every effect started so far.
    public private(set) var snowCover: Double = 0
    /// Every effect started since the story began (or the last seek), for
    /// the snow cover.
    private var started: [ActiveCanvasEffect] = []
    private var coverTime: TimeInterval = 0
    /// Applied when an effect starts; running effects keep their options.
    public var policy: EffectPolicy

    private let triggers: [CanvasEffectTrigger]
    private var firedTriggers: Set<Int> = []
    private var sequence = 0
    private let log: (String) -> Void

    private static let logger = Logger(subsystem: "com.anj.stickerstories", category: "effects")

    /// - Parameters:
    ///   - triggers: declarative canvas triggers for this story (already
    ///     decoded). Those whose effect does not suit `setting` are dropped
    ///     here with a log line, once.
    ///   - setting: the pack's setting.
    ///   - policy: Reduce Motion / calm mode.
    ///   - log: where non-fatal content problems go; defaults to os_log.
    public init(
        triggers: [CanvasEffectTrigger] = [], setting: PackSetting = .none,
        policy: EffectPolicy = .standard, log: ((String) -> Void)? = nil
    ) {
        let log = log ?? { Self.logger.notice("\($0, privacy: .public)") }
        self.log = log
        self.policy = policy
        self.triggers = triggers.filter { trigger in
            guard trigger.effect.suits(setting) else {
                log("effects: canvas effect \(trigger.effect.rawValue) does not suit a \(setting.rawValue) pack; skipped")
                return false
            }
            return true
        }
    }

    // MARK: Per-frame

    /// Advances the timeline to `time`, fires due triggers, retires finished
    /// effects and returns the strength per effect kind. Going backwards is
    /// a seek: the active set is rebuilt from the triggers.
    @discardableResult
    public func tick(_ time: TimeInterval) -> [CanvasEffectName: Double] {
        if time < currentTime - 1e-6 { seek(to: time) }
        currentTime = time
        fireDueTriggers()
        let strengths = CanvasEffectEvaluator.strengths(for: active, at: time)
        active.removeAll { CanvasEffectEvaluator.isFinished($0, at: time) }
        if started.contains(where: { $0.name == .snow }) {
            snowCover = CanvasEffectEvaluator.snowCover(of: started, from: coverTime, amount: snowCover, to: time)
        }
        coverTime = time
        return strengths
    }

    private func seek(to time: TimeInterval) {
        active.removeAll()
        started.removeAll()
        firedTriggers.removeAll()
        currentTime = time
        // Rebuilt from the start once the triggers before `time` fire again.
        snowCover = 0
        coverTime = 0
    }

    private func fireDueTriggers() {
        for (index, trigger) in triggers.enumerated() where !firedTriggers.contains(index) && trigger.at <= currentTime {
            firedTriggers.insert(index)
            start(trigger.effect, options: trigger.options, at: trigger.at)
        }
    }

    // MARK: Control

    /// Starts an effect now (the gallery, tests); the pack setting is not
    /// consulted for explicit calls.
    @discardableResult
    public func play(_ effect: CanvasEffectName, options: CanvasEffectOptions = CanvasEffectOptions()) -> CanvasEffectHandle {
        start(effect, options: options, at: currentTime) ?? CanvasEffectHandle()
    }

    /// Eases the effect out from now.
    public func stop(_ handle: CanvasEffectHandle) {
        guard let index = active.firstIndex(where: { $0.handle == handle }), active[index].stopTime == nil else { return }
        active[index].stopTime = currentTime
    }

    /// Called on playback end: drops everything immediately.
    public func stopAll() {
        active.removeAll()
        started.removeAll()
        snowCover = 0
    }

    @discardableResult
    private func start(_ name: CanvasEffectName, options: CanvasEffectOptions, at time: TimeInterval) -> CanvasEffectHandle? {
        guard let options = policy.adjusted(name, options.clamped) else { return nil }
        sequence += 1
        let effect = ActiveCanvasEffect(name: name, startTime: time, options: options, sequence: sequence)
        active.append(effect)
        started.append(effect)
        return effect.handle
    }
}
