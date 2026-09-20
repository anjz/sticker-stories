import Foundation
import os

/// The API the rest of the app sees. Targets are sticker *instances*; the
/// runner also fires declarative triggers, which address sticker IDs and
/// expand to every placed instance of that sticker.
public protocol StickerEffects: AnyObject {
    @discardableResult
    func play(_ effect: EffectName, on target: UUID, options: EffectOptions) -> EffectHandle
    func stop(_ handle: EffectHandle)
    func stopAll(on target: UUID)
    /// Called on playback end: drops everything immediately (P4 restore).
    func stopAll()
}

/// Owns the active effects for one playback. Created when play starts and
/// discarded when it ends (P6); it holds no state between stories.
///
/// It is pure in the sense that matters: it is *given* the timeline time by
/// `tick(_:)` and never reads a clock, so it lives in the Kit and is tested
/// there. The app ticks it from the scene's update loop with the audio time.
public final class StickerEffectsRunner: StickerEffects {
    /// Most flashes (white tints) allowed to start in any one second.
    public static let maxFlashesPerSecond = 3

    public private(set) var currentTime: TimeInterval = 0
    public private(set) var active: [ActiveEffect] = []
    /// Applied when an effect starts. Change it freely; running effects keep
    /// the options they started with.
    public var policy: EffectPolicy

    private let triggers: [EffectTrigger]
    private let targets: [String: [UUID]]
    private var firedTriggers: Set<Int> = []
    private var sequence = 0
    private var flashStarts: [TimeInterval] = []
    private let log: (String) -> Void

    private static let logger = Logger(subsystem: "com.anj.stickerstories", category: "effects")

    /// - Parameters:
    ///   - triggers: declarative triggers for this story (already decoded).
    ///   - targets: sticker ID → placed instance IDs. Triggers whose sticker
    ///     has no instances simply never fire (that is normal, not a fault).
    ///   - policy: Reduce Motion / calm mode.
    ///   - log: where non-fatal content problems go; defaults to os_log.
    public init(
        triggers: [EffectTrigger] = [], targets: [String: [UUID]] = [:],
        policy: EffectPolicy = .standard, log: ((String) -> Void)? = nil
    ) {
        self.triggers = triggers
        self.targets = targets
        self.policy = policy
        self.log = log ?? { Self.logger.notice("\($0, privacy: .public)") }
    }

    /// Instances currently affected (including held end states).
    public var affectedTargets: Set<UUID> { Set(active.map(\.target)) }

    // MARK: Per-frame

    /// Advances the timeline to `time`, fires due triggers, retires finished
    /// effects and returns the composed delta per affected instance.
    /// Going backwards is a seek: the active set is rebuilt from the
    /// triggers so the result is the same as having played forward to `time`.
    @discardableResult
    public func tick(_ time: TimeInterval) -> [UUID: EffectDelta] {
        if time < currentTime - 1e-6 { seek(to: time) }
        currentTime = time
        fireDueTriggers()
        let deltas = EffectEvaluator.deltas(for: active, at: time)
        active.removeAll { EffectEvaluator.isFinished($0, at: time) }
        return deltas
    }

    private func seek(to time: TimeInterval) {
        active.removeAll()
        firedTriggers.removeAll()
        flashStarts.removeAll()
        currentTime = time
    }

    private func fireDueTriggers() {
        for (index, trigger) in triggers.enumerated() where !firedTriggers.contains(index) && trigger.at <= currentTime {
            firedTriggers.insert(index)
            for instance in targets[trigger.stickerID] ?? [] {
                start(trigger.effect, on: instance, options: trigger.options, at: trigger.at)
            }
        }
    }

    // MARK: StickerEffects

    @discardableResult
    public func play(_ effect: EffectName, on target: UUID, options: EffectOptions = EffectOptions()) -> EffectHandle {
        start(effect, on: target, options: options, at: currentTime) ?? EffectHandle()
    }

    public func stop(_ handle: EffectHandle) {
        guard let index = active.firstIndex(where: { $0.handle == handle }), active[index].stopTime == nil else { return }
        active[index].stopTime = currentTime
    }

    public func stopAll(on target: UUID) {
        for index in active.indices where active[index].target == target && active[index].stopTime == nil {
            active[index].stopTime = currentTime
        }
    }

    public func stopAll() {
        active.removeAll()
    }

    // MARK: Starting

    @discardableResult
    private func start(_ name: EffectName, on target: UUID, options: EffectOptions, at time: TimeInterval) -> EffectHandle? {
        guard var options = policy.adjusted(name, options.clamped) else { return nil }
        if options.color == nil { options.color = EffectDefinition.definition(for: name).defaultColor }
        if name.requiresColor && options.color == nil {
            log("effects: \(name.rawValue) needs a color; skipped")
            return nil
        }
        if name.isOneWay, options.repeatCount != .times(1) {
            log("effects: repeat is ignored for one-way effect \(name.rawValue)")
            options.repeatCount = .times(1)
        }
        if isFlash(name, options) {
            flashStarts.removeAll { $0 <= time - 1 }
            guard flashStarts.count < Self.maxFlashesPerSecond else {
                log("effects: \(name.rawValue) skipped — more than \(Self.maxFlashesPerSecond) flashes in a second")
                return nil
            }
            flashStarts.append(time)
        }

        sequence += 1
        var effect = ActiveEffect(name: name, target: target, startTime: time, options: options, sequence: sequence)
        if name.isOneWay, !options.hold, let active = effect.activeDuration {
            // Without hold a one-way effect returns to base when it ends —
            // an ease-back, so a fade-out fades back in rather than popping.
            effect.stopTime = time + active
        }
        active.append(effect)
        return effect.handle
    }

    /// A white tint is a flash (hard on the eyes); nothing else in the
    /// library is hard-edged any more.
    private func isFlash(_ name: EffectName, _ options: EffectOptions) -> Bool {
        name == .tint && options.color?.isWhite == true
    }
}
