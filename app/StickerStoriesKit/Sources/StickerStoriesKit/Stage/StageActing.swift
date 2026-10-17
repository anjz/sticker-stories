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
