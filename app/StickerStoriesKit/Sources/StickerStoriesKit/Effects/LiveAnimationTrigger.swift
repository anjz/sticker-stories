import Foundation

/// One resolved live-animation trigger: at `at` seconds into the narration,
/// every placed instance of `stickerID` plays its action `animationID`
/// (the sticker's own frames — the bear cub yawning, the snail hiding in
/// its shell; `docs/pack-format.md`, "Live animations"), whole, up to its
/// pause frame and staying there (`hold`), or on from the pause frame to
/// the end (`resume`). Character animation is its own system beside the
/// effects library: the sticker effects keep running around it.
public struct LiveAnimationTrigger: Equatable, Sendable {
    public enum Mode: String, Equatable, Sendable {
        case whole
        /// Play to the pause frame and stay there until a `resume` for the
        /// same sticker, another action, or the story's end.
        case hold
        /// Play on from the pause frame to the end.
        case resume
    }

    public var at: TimeInterval
    /// Optional authoring label ("yawned"); never interpreted by the app.
    public var cue: String?
    public var stickerID: String
    public var animationID: String
    public var mode: Mode

    public init(at: TimeInterval, cue: String? = nil, stickerID: String, animationID: String, mode: Mode = .whole) {
        self.at = at
        self.cue = cue
        self.stickerID = stickerID
        self.animationID = animationID
        self.mode = mode
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

/// The part of an animation to play.
public enum LivePart: Equatable, Sendable {
    /// An action from its first frame to its last.
    case whole
    /// An action up to its pause frame, then that frame for as long as it
    /// is asked for.
    case toPause
    /// An action from its pause frame to its last; `held` when the frames
    /// are already on show (the hold before it), so they do not fade in.
    case fromPause(held: Bool)
    /// A move: its loop over and over for `travel` seconds (while the
    /// character comes into the scene), then the frames after the loop,
    /// which bring it to rest. A move without a loop (a sprout) plays its
    /// frames once and ignores `travel`.
    case move(travel: TimeInterval)
}

/// What a live animation shows at one moment: a frame, and how opaque the
/// frames and the still sticker under them are while one dissolves into
/// the other at the start and the end.
public struct LiveFrameState: Equatable, Sendable {
    public var frame: Int
    public var liveAlpha: Double
    public var stillAlpha: Double

    public init(frame: Int, liveAlpha: Double, stillAlpha: Double) {
        self.frame = frame
        self.liveAlpha = liveAlpha
        self.stillAlpha = stillAlpha
    }
}

/// An animation's frame timing, from its sidecar: how long each frame
/// shows, where an action can pause and which frames a move loops. Pure,
/// so what shows at any moment is a function of the time alone — a seek
/// or a dropped frame never leaves a sticker out of step with the words.
public struct LiveFrames: Equatable, Sendable {
    public var holds: [TimeInterval]
    public var pause: Int?
    public var loop: ClosedRange<Int>?

    /// How long the frames take to fade in over the still art (and out at
    /// the end), capped at two thirds of those frames' holds; the rest of
    /// those holds dissolves the still art out underneath (and back in).
    /// Where the first frame is not the sticker's exact drawing, the
    /// difference dissolves instead of popping.
    public static let fade: TimeInterval = 0.3

    public init(holds: [TimeInterval], pause: Int? = nil, loop: ClosedRange<Int>? = nil) {
        self.holds = holds
        self.pause = pause
        self.loop = loop
    }

    /// A move's first frame is the sticker's rest pose, there for the
    /// mapping onto the sticker; it plays from the next one.
    private static let moveStart = 1

    /// The frames a part plays, in order, whether it dissolves in from the
    /// still sticker and out to it, and whether its last frame stays.
    private func plan(_ part: LivePart) -> (frames: [Int], fadeIn: Bool, fadeOut: Bool, stays: Bool)? {
        let n = holds.count
        guard n > 0 else { return nil }
        switch part {
        case .whole:
            return (Array(0..<n), true, true, false)
        case .toPause:
            guard let pause, pause < n else { return nil }
            return (Array(0...pause), true, false, true)
        case .fromPause(let held):
            guard let pause, pause < n else { return nil }
            return (Array(pause..<n), !held, true, false)
        case .move:
            let first = min(loop.map { $0.upperBound + 1 } ?? Self.moveStart, n)
            return (Array(first..<n), false, true, false)
        }
    }

    /// How long the part takes; `nil` for one that stays (a hold).
    public func duration(_ part: LivePart) -> TimeInterval? {
        guard let plan = plan(part) else { return 0 }
        if plan.stays { return nil }
        let rest = plan.frames.reduce(0) { $0 + holds[$1] }
        if case .move(let travel) = part, loop != nil { return max(travel, 0) + rest }
        return rest
    }

    /// Seconds one pass of a move's loop takes (0 without a loop).
    public var loopDuration: TimeInterval {
        guard let loop, loop.upperBound < holds.count else { return 0 }
        return loop.reduce(0) { $0 + holds[$1] }
    }

    /// What the part shows `elapsed` seconds after it started; `nil` once it
    /// is over (the still sticker is back) or before it starts.
    public func state(_ part: LivePart, at elapsed: TimeInterval) -> LiveFrameState? {
        guard elapsed >= 0, let plan = plan(part) else { return nil }
        var t = elapsed
        // A move's loop comes first, for as long as the character travels.
        if case .move(let travel) = part, let loop, loop.upperBound < holds.count {
            let cycle = loopDuration
            if t < travel, cycle > 0 {
                var inCycle = t.truncatingRemainder(dividingBy: cycle)
                for frame in loop {
                    if inCycle < holds[frame] { return LiveFrameState(frame: frame, liveAlpha: 1, stillAlpha: 0) }
                    inCycle -= holds[frame]
                }
                return LiveFrameState(frame: loop.upperBound, liveAlpha: 1, stillAlpha: 0)
            }
            t -= max(travel, 0)
            if plan.frames.isEmpty {
                // No frames after the loop: dissolve from the last loop frame.
                return t < Self.fade
                    ? LiveFrameState(frame: loop.upperBound, liveAlpha: 1 - t / Self.fade, stillAlpha: 1) : nil
            }
        }
        guard let firstFrame = plan.frames.first, let lastFrame = plan.frames.last else { return nil }
        let firstHold = holds[firstFrame], lastHold = holds[lastFrame]
        let fade = min(Self.fade, min(firstHold, lastHold) * 2 / 3)
        var start: TimeInterval = 0
        for (index, frame) in plan.frames.enumerated() {
            let hold = holds[frame]
            let isLast = index == plan.frames.count - 1
            if isLast && plan.stays { return LiveFrameState(frame: frame, liveAlpha: 1, stillAlpha: 0) }
            guard t < start + hold else {
                start += hold
                continue
            }
            let local = t - start
            var live = 1.0, still = 0.0
            if index == 0 && plan.fadeIn {
                live = min(local / max(fade, 1e-6), 1)
                still = local < fade ? 1 : max(0, 1 - (local - fade) / max(hold - fade, 1e-6))
            }
            if isLast && plan.fadeOut {
                // The still art comes back underneath, then the frames fade.
                still = max(still, min(local / max(hold - fade, 1e-6), 1))
                if local > hold - fade { live = min(live, max(0, (hold - local) / max(fade, 1e-6))) }
            }
            return LiveFrameState(frame: frame, liveAlpha: live, stillAlpha: still)
        }
        return nil
    }
}

/// A story's live-animation triggers and what each sticker is playing at
/// any moment: the last trigger for that sticker up to then decides (an
/// action on it replaces the one before, a hold lasts until the next one).
/// Pure, like `ExpressionTimeline`, so a seek is exact and a trigger is
/// never lost to a slow frame.
public struct LiveTimeline: Sendable {
    public let triggers: [LiveAnimationTrigger]
    private let byStickerID: [String: [LiveAnimationTrigger]]

    public init(triggers: [LiveAnimationTrigger]) {
        self.triggers = triggers.sorted { $0.at < $1.at }
        byStickerID = Dictionary(grouping: self.triggers, by: \.stickerID)
    }

    /// Every sticker/animation pair the story may play, for preloading.
    public var animations: Set<LiveAnimationKey> {
        Set(triggers.map { LiveAnimationKey(stickerID: $0.stickerID, animationID: $0.animationID) })
    }

    /// The action a sticker plays at `time`: which one, which part and how
    /// far in; `nil` when it shows its still art. `frames` gives an
    /// animation's timing (nil: not loaded, so nothing plays).
    public func current(
        for stickerID: String, at time: TimeInterval, frames: (LiveAnimationKey) -> LiveFrames?
    ) -> (key: LiveAnimationKey, part: LivePart, elapsed: TimeInterval, since: TimeInterval)? {
        guard let list = byStickerID[stickerID],
            let index = list.lastIndex(where: { $0.at <= time })
        else { return nil }
        let trigger = list[index]
        let key = LiveAnimationKey(stickerID: stickerID, animationID: trigger.animationID)
        guard let timing = frames(key) else { return nil }
        let part: LivePart
        switch trigger.mode {
        case .whole:
            part = .whole
        case .hold:
            part = timing.pause == nil ? .whole : .toPause
        case .resume:
            guard timing.pause != nil else { return nil }
            let before = index > 0 ? list[index - 1] : nil
            part = .fromPause(held: before?.mode == .hold && before?.animationID == trigger.animationID)
        }
        let elapsed = time - trigger.at
        if let duration = timing.duration(part), elapsed >= duration { return nil }
        return (key, part, elapsed, trigger.at)
    }
}
