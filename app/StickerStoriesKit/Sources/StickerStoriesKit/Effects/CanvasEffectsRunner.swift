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
        return strengths
    }

    private func seek(to time: TimeInterval) {
        active.removeAll()
        firedTriggers.removeAll()
        currentTime = time
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
    }

    @discardableResult
    private func start(_ name: CanvasEffectName, options: CanvasEffectOptions, at time: TimeInterval) -> CanvasEffectHandle? {
        guard let options = policy.adjusted(name, options.clamped) else { return nil }
        sequence += 1
        let effect = ActiveCanvasEffect(name: name, startTime: time, options: options, sequence: sequence)
        active.append(effect)
        return effect.handle
    }
}
