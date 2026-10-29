import Foundation

/// `wash`: a big wave washing up the beach and back. Along the whole shore
/// — the near edge of the open water, wherever it runs across the art —
/// the water rushes up the sand, coming in from the left first and
/// sweeping to the right (the way the painted waves roll), laps, and slides
/// back into the sea, leaving the sand it covered wet and dark for a while.
/// It runs furthest where the sticker it is cued on is: up to just past its
/// feet (to the rock pool's rim, over a sandcastle, round someone's toes).
/// A creature of the water that a story sends off to the sea while it
/// draws back there rides it across (`StageDirector`, `StageWash`) instead
/// of fading across. Out at sea, up in the air, or with no open water
/// above it, the cue draws nothing.
///
/// Like `SurfWave`, everything about it at a moment is a pure function of
/// the timeline, so a seek or a replay shows the same water; the app draws
/// it (`WashCoordinator`) on the ground, under every sticker and the
/// scene's layers. Places are art points (fractions of the base art, `v`
/// up from its bottom), in the plane of the painted beach.
public enum Wash {
    /// How much later in the cycle the water reaches the right edge of the
    /// art than the left: it comes in from the left.
    public static let sweep = 0.25
    /// The part of each column's cycle in which the water slides back into
    /// the sea (`drawsBackStart` for the whole cycle).
    public static let drawsBack: ClosedRange<Double> = 0.55...1

    /// The beach a wash runs over, worked out once when it is cued.
    public struct Beach: Equatable, Sendable {
        /// The near edge of the open water, column by column across the
        /// art (`u`, left to right), as its art height `v`.
        public var shore: [SceneSpace.Point]
        /// Where it runs furthest: the sticker's column and how far down
        /// the art it reaches there (a little past its feet).
        public var reach: SceneSpace.Point

        /// How far down the art from the shore the water runs at its
        /// furthest in column `u`: all the way to `reach` in the sticker's
        /// column, a strip of beach elsewhere, uneven like real water.
        public func depth(at u: Double, shore v: Double) -> Double {
            guard let edge = edge(at: reach.u) else { return 0 }
            let full = max(edge - reach.v, 0.02)
            let near = exp(-pow((u - reach.u) / 0.12, 2))
            let strip = 0.3 + 0.7 * near
            let uneven = 1 + 0.12 * sin(23 * u + 3) + 0.06 * sin(57 * u + 1)
            return full * strip * uneven
        }

        /// The shore's art height in column `u` (between the samples).
        public func edge(at u: Double) -> Double? {
            guard let first = shore.first, let last = shore.last else { return nil }
            if u <= first.u { return first.v }
            if u >= last.u { return last.v }
            for (a, b) in zip(shore, shore.dropFirst()) where u <= b.u {
                let k = (u - a.u) / max(b.u - a.u, 1e-9)
                return a.v + (b.v - a.v) * k
            }
            return last.v
        }
    }

    /// The beach for a wash cued on a sticker with its feet at `p`, its
    /// shore sampled in `columns` across `range` (art `u`). Nil out in the
    /// open water already, up in the air, or with no open water above it.
    public static func beach(to p: Vec3, in world: StageWorld, across range: ClosedRange<Double>, columns: Int = 64) -> Beach? {
        guard let reach = reach(to: p, in: world) else { return nil }
        let past = world.project(reach.to.onGround)
        var shore: [SceneSpace.Point] = []
        for k in 0...max(columns, 1) {
            let u = range.lowerBound + (range.upperBound - range.lowerBound) * Double(k) / Double(max(columns, 1))
            if let v = edge(at: u, in: world) { shore.append(SceneSpace.Point(u, v)) }
        }
        guard !shore.isEmpty else { return nil }
        return Beach(shore: shore, reach: SceneSpace.Point(past.u, past.v))
    }

    /// Where the water runs for a sticker with its feet at `p`: from the
    /// edge of the open water straight up the screen above it (a water
    /// place that is not shallow, `SceneSpace.Place`) to a little past its
    /// feet. Nil out in that water already, up in the air, or with no such
    /// water above it.
    public static func reach(to p: Vec3, in world: StageWorld) -> (from: Vec2, to: Vec2)? {
        guard p.y < 0.01, !inOpen(p.ground, in: world) else { return nil }
        let a = world.project(p.ground.onGround)
        guard let v = edge(at: a.u, from: a.v, in: world) else { return nil }
        // Past its feet by a little: the water reaches round them.
        return (world.groundPoint(SceneSpace.Point(a.u, v)), world.groundPoint(SceneSpace.Point(a.u, max(a.v - 0.025, 0))))
    }

    /// The near edge of the open water in art column `u`, looking up the
    /// art from `v` (its bottom by default); nil with none there.
    static func edge(at u: Double, from v: Double = 0, in world: StageWorld) -> Double? {
        let step = 0.002
        var v = v
        while v + step < world.space.horizon {
            v += step
            if inOpen(world.groundPoint(SceneSpace.Point(u, v)), in: world) { return v }
        }
        return nil
    }

    static func inOpen(_ g: Vec2, in world: StageWorld) -> Bool {
        world.grounds.contains { $0.water && !$0.shallow && $0.polygon.contains(g) }
    }

    /// Where the wash is in its cycle.
    public struct Frame: Equatable, Sendable {
        /// 0…1 within the cycle.
        public var phase: Double
        public var intensity: Double
        /// The whole wash's opacity, eased to 0 when the effect is stopped
        /// early.
        public var opacity: Double
    }

    /// The wash of a running `wash` effect at `time`, or nil when it shows
    /// nothing then (not started, finished, or another effect).
    public static func frame(of effect: ActiveEffect, at time: TimeInterval) -> Frame? {
        guard effect.name == .wash, effect.options.intensity > 0 else { return nil }
        guard case .running(_, let phase) = EffectEvaluator.status(of: effect, at: time) else { return nil }
        var fade = 1.0
        if let stopTime = effect.stopTime, time >= stopTime {
            let ease = EffectEvaluator.easeBackDuration(of: effect, stoppingAt: stopTime)
            fade = ease > 0 ? max(0, 1 - (time - stopTime) / ease) : 0
        }
        return Frame(phase: phase, intensity: effect.options.intensity, opacity: fade)
    }

    /// The cycle as column `across` of the art sees it (0 its left edge, 1
    /// its right): the left end first.
    public static func local(_ phase: Double, across: Double) -> Double {
        min(max((phase - sweep * min(max(across, 0), 1)) / (1 - sweep), 0), 1)
    }

    /// When, in the whole cycle, the water in column `across` starts
    /// sliding back into the sea.
    public static func drawsBackStart(across: Double) -> Double {
        drawsBack.lowerBound * (1 - sweep) + sweep * min(max(across, 0), 1)
    }

    /// How far up the beach the water's front is in a column (0 at the
    /// shore, 1 at its furthest) at its own point in the cycle: it rushes
    /// up, slowing as it comes (to 0.35), laps a little back and forth, and
    /// slides back down into the sea, gathering speed (from 0.55).
    public static func front(at phase: Double) -> Double {
        let t = min(max(phase, 0), 1)
        if t < 0.35 { return SurfWave.smooth(0, 1, t / 0.35 * 0.5 + 0.5) * 2 - 1 }
        if t < drawsBack.lowerBound { return 1 - 0.06 * sin((t - 0.35) / 0.2 * .pi) }
        let back = (t - drawsBack.lowerBound) / (1 - drawsBack.lowerBound)
        return 1 - back * back
    }

    /// How far up the beach the water has been so far in a column: the wet
    /// sand it leaves.
    public static func reached(at phase: Double) -> Double {
        phase < 0.35 ? front(at: phase) : 1
    }

    /// How dark the covered sand is in a column at its point in the cycle:
    /// wet as the water covers it, drying once the water has gone.
    public static func wet(at phase: Double) -> Double {
        SurfWave.smooth(0.05, 0.3, phase) * (1 - SurfWave.smooth(0.75, 1, phase))
    }
}
