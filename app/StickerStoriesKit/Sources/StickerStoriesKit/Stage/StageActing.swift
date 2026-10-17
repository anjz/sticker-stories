import Foundation

/// How an action a story cues plays on the stage in space
/// (`docs/stage3d.md`, "In the water"): in the water a move keeps the
/// sticker in, only its face, unless the action is done there; facing the
/// way the action says.
public enum StageActing {
    /// Whether an action cued while a sticker stays in the water keeps to
    /// its face: the move that keeps it there (`StageMove.stays`, with the
    /// water in its `on`) plays on — the surfer paddles on, laughing —
    /// unless the action is done in that water (its `on`: riding a wave,
    /// in the sea). Out of the water, or on a move that does not stay,
    /// the action plays. `move`: the move `travel` plays.
    public static func keepsToFace(actionOn: [String], travel: StageTravel?, move: StageMove?, water: String?) -> Bool {
        guard let travel, travel.stays, let move, let water, move.on.contains(water) else { return false }
        return !actionOn.contains(water)
    }

    /// The way a sticker faces (+1 its art's own way, −1 mirrored) while
    /// an action that `faces` a way on screen plays: turned to it over
    /// its first moments, whatever way it faced, and back as it ends.
    /// `art`: the way its art looks; `duration` nil for one that holds.
    public static func facing(
        _ facing: Double, art: StageMove.Facing?, faces: StageMove.Facing?, elapsed: TimeInterval, duration: TimeInterval?
    ) -> Double {
        guard let art, let faces else { return facing }
        let target: Double = art == faces ? 1 : -1
        var k = min(max(elapsed / StagePlan.turn, 0), 1)
        if let duration { k = min(k, min(max((duration - elapsed) / StagePlan.turn, 0), 1)) }
        let eased = k * k * (3 - 2 * k)
        return StagePlan.unsquashed(facing + (target - facing) * eased)
    }
}

extension StageActing {
    /// An action played over a move that goes on through it — afloat on a
    /// move that stays (the surfer riding a wave out at sea), or aloft (a
    /// bird talking on the wing): its first and last keys are the
    /// sticker's still pose, so they are left out. It goes from the move's
    /// pose straight into the action, and back to the move as the action
    /// heads for its last key (nil: show the move), never through standing
    /// still on the water or in the air. `keys`: how many the action has.
    public static func overMove(_ tween: LiveTween, keys: Int) -> LiveTween? {
        guard keys >= 4 else { return tween }
        if tween.frame >= keys - 2 { return nil }
        if tween.frame == 0 { return LiveTween(frame: 1, next: 1, progress: 0) }
        return tween
    }
}
