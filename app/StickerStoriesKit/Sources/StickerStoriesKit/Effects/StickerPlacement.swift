import Foundation

/// Actions that only make sense in one place — the woodpecker taps a trunk
/// (an action's `place`, `docs/pack-format.md`, "Live animations"). Before
/// one plays, the sticker goes to the nearest right spot unless it is there
/// already, wherever the child put it or the story took it; the action
/// waits until it has arrived. Pure, like the planners it feeds.
public enum PlacementPlanner {
    /// The moves that take each sticker to where its actions happen: one
    /// per action that has a place, just after the sticker's last story
    /// move before it (it queues behind that move), each skipped by the
    /// motion planner when the sticker is there already.
    public static func goes(
        live: [LiveAnimationTrigger], places: [LiveAnimationKey: [String]], goes: [GoTrigger]
    ) -> [GoTrigger] {
        var out: [GoTrigger] = []
        for trigger in live.sorted(by: { $0.at < $1.at }) where trigger.mode != .resume {
            let key = LiveAnimationKey(stickerID: trigger.stickerID, animationID: trigger.animationID)
            guard let place = places[key]?.first else { continue }
            let before = goes.filter { $0.stickerID == trigger.stickerID && $0.at <= trigger.at }.max { $0.at < $1.at }
            // The story took it there itself: nothing to add.
            if let before, before.kind == .to, let target = before.target, places[key]?.contains(target) == true { continue }
            // Just after that move, so it is planned (and queued) after it.
            let at = before.map { $0.at + 0.001 } ?? 0
            guard !out.contains(where: { $0.stickerID == trigger.stickerID && $0.at == at }) else { continue }
            out.append(GoTrigger(at: at, stickerID: trigger.stickerID, kind: .to, target: place, unlessThere: true))
        }
        return out
    }

    /// The live triggers with every action that has a place held back
    /// until its sticker has got there: an action cued while a move of the
    /// sticker is still under way starts when the move ends.
    public static func delayed(
        _ live: [LiveAnimationTrigger], plans: [UUID: MotionPlan], stickers: [UUID: String],
        places: Set<LiveAnimationKey>
    ) -> [LiveAnimationTrigger] {
        live.map { trigger in
            let key = LiveAnimationKey(stickerID: trigger.stickerID, animationID: trigger.animationID)
            guard trigger.mode != .resume, places.contains(key) else { return trigger }
            var start = trigger.at
            for (id, plan) in plans where stickers[id] == trigger.stickerID {
                for leg in plan.legs where leg.travels && leg.at <= trigger.at && trigger.at < leg.at + leg.duration {
                    start = max(start, leg.at + leg.duration)
                }
            }
            var moved = trigger
            moved.at = start
            return moved
        }
    }
}
