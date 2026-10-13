import Foundation

/// Characters alive at rest (`docs/stage3d.md`, "Alive at rest"): now and
/// then, while a story leaves one be, it plays one of its small, gentle
/// actions (`idle` in its sidecar: a look around, an ear flick, a sniff).
/// Never while it moves, plays or holds an action the story cued, sleeps
/// or hovers, and never just before the story cues it — the story always
/// comes first. Pure and seeded: the actions are planned once, as the
/// story starts, as ordinary live triggers.
public enum IdleLife {
    /// One of a sticker's idle actions and how long it plays.
    public struct Action: Equatable, Sendable {
        public var id: String
        public var duration: TimeInterval

        public init(id: String, duration: TimeInterval) {
            self.id = id
            self.duration = duration
        }
    }

    /// Seconds between one sticker's idle actions.
    public static let every: ClosedRange<TimeInterval> = 7...14
    /// Room kept clear before and after anything the story does with it.
    static let margin: TimeInterval = 0.8

    /// The idle actions to play, as live triggers (mode `whole`).
    /// - Parameters:
    ///   - actions: each sticker on the stage and its idle actions.
    ///   - story: the story's live triggers, as they play (held back for
    ///     moves, `StageDirector.delayed`).
    ///   - frames: an animation's timing.
    ///   - busy: whether something else has the sticker at a moment — on
    ///     its way somewhere, hovering or swimming, asleep, not on the
    ///     stage.
    ///   - from, to: when the story's stage is settled, and its end.
    public static func triggers<R: RandomNumberGenerator>(
        actions: [String: [Action]], story: [LiveAnimationTrigger], frames: (LiveAnimationKey) -> LiveFrames?,
        busy: (String, TimeInterval) -> Bool, from: TimeInterval, to: TimeInterval, random: inout R
    ) -> [LiveAnimationTrigger] {
        let timeline = LiveTimeline(triggers: story)
        let cued = Dictionary(grouping: story, by: \.stickerID).mapValues { $0.map(\.at) }
        var out: [LiveAnimationTrigger] = []
        for sticker in actions.keys.sorted() {
            guard let mine = actions[sticker]?.filter({ $0.duration > 0 }), !mine.isEmpty else { continue }
            func free(_ t: TimeInterval, for duration: TimeInterval) -> Bool {
                let end = t + duration
                if (cued[sticker] ?? []).contains(where: { $0 > t - margin && $0 < end + margin }) { return false }
                for k in 0...4 {
                    let s = t - margin + (duration + 2 * margin) * Double(k) / 4
                    if busy(sticker, s) || timeline.current(for: sticker, at: s, frames: frames) != nil { return false }
                }
                return true
            }
            // Staggered, so the stage never fidgets all at once.
            var t = from + Double.random(in: 1...every.upperBound, using: &random)
            var last: String?
            while t < to {
                let choices = mine.count > 1 ? mine.filter { $0.id != last } : mine
                let action = choices[Int.random(in: 0..<choices.count, using: &random)]
                guard t + action.duration < to else { break }
                if free(t, for: action.duration) {
                    out.append(LiveAnimationTrigger(at: t, cue: "idle", stickerID: sticker, animationID: action.id))
                    last = action.id
                    t += action.duration + Double.random(in: every, using: &random)
                } else {
                    t += 1.5
                }
            }
        }
        return out.sorted { $0.at < $1.at }
    }
}
