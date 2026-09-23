import Foundation

/// One resolved live-animation trigger: at `at` seconds into the narration,
/// every placed instance of `stickerID` plays its animation `animationID`
/// (the sticker's own frames — the bear cub yawning, the frog's backflip;
/// `docs/pack-format.md`, "Live animations"). Character animation is its
/// own system beside the effects library: it has no options, and the
/// sticker effects keep running around it.
public struct LiveAnimationTrigger: Equatable, Sendable {
    public var at: TimeInterval
    /// Optional authoring label ("yawned"); never interpreted by the app.
    public var cue: String?
    public var stickerID: String
    public var animationID: String

    public init(at: TimeInterval, cue: String? = nil, stickerID: String, animationID: String) {
        self.at = at
        self.cue = cue
        self.stickerID = stickerID
        self.animationID = animationID
    }
}

/// Hands out a story's live-animation triggers as the timeline reaches
/// them, each once. Pure bookkeeping — the scene plays what comes out — so
/// it is testable without SpriteKit. Mirrors the runners: a step backwards
/// is a seek and re-arms the triggers after it.
public final class LiveAnimationSchedule {
    /// A trigger found this late (the app was in the background, a frame
    /// hitched badly) is dropped rather than played out of step with the
    /// words it belongs to.
    public static let maxLateness: TimeInterval = 1.0

    public var policy: EffectPolicy
    private let triggers: [LiveAnimationTrigger]
    private var fired: Set<Int> = []
    private var currentTime: TimeInterval = 0

    public init(triggers: [LiveAnimationTrigger], policy: EffectPolicy = .standard) {
        self.triggers = triggers.sorted { $0.at < $1.at }
        self.policy = policy
    }

    /// Every sticker/animation pair the story may play, for preloading.
    public var animations: Set<LiveAnimationKey> {
        Set(triggers.map { LiveAnimationKey(stickerID: $0.stickerID, animationID: $0.animationID) })
    }

    /// Advances to `time` and returns the triggers that fell due since the
    /// last call and should play now. Under Reduce Motion or calm mode
    /// they fall due but nothing plays.
    public func due(at time: TimeInterval) -> [LiveAnimationTrigger] {
        if time < currentTime - 1e-6 {
            fired = fired.filter { triggers[$0].at <= time }
        }
        currentTime = time
        var out: [LiveAnimationTrigger] = []
        for (index, trigger) in triggers.enumerated() where !fired.contains(index) && trigger.at <= time {
            fired.insert(index)
            if time - trigger.at <= Self.maxLateness && policy.allowsLiveAnimations {
                out.append(trigger)
            }
        }
        return out
    }
}

/// A sticker's animation, as the scene caches its sprite sheet.
public struct LiveAnimationKey: Hashable, Sendable {
    public var stickerID: String
    public var animationID: String

    public init(stickerID: String, animationID: String) {
        self.stickerID = stickerID
        self.animationID = animationID
    }
}
