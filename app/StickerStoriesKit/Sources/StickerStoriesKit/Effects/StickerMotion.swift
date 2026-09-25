import Foundation

/// A moment the story moves a sticker (`{fox:go to rabbit}` in the
/// authoring text; `docs/effects.md`, "Movement"): it walks, hops or flies
/// to another character, onto or under one, to a place in the scene, off
/// the canvas, or back to its own spot.
public struct GoTrigger: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        /// Beside another sticker (`target` a sticker), or to a place in
        /// the scene (`target` a feature: the pond, the branches).
        case to
        /// On top of another sticker: a bee on the flower.
        case on
        /// Under another sticker: a mouse under the mushroom's cap.
        case under
        /// Off the canvas, by the nearer side.
        case away
        /// Back to its own spot (where the child put it, or where it came
        /// in), from wherever it went — off the canvas included.
        case back
    }

    public var at: TimeInterval
    /// Optional authoring label (the word it fires on); never interpreted.
    public var cue: String?
    public var stickerID: String
    public var kind: Kind
    /// A sticker id (to, on, under) or a feature id (to); nil for away and back.
    public var target: String?

    public init(at: TimeInterval, cue: String? = nil, stickerID: String, kind: Kind, target: String? = nil) {
        self.at = at
        self.cue = cue
        self.stickerID = stickerID
        self.kind = kind
        self.target = target
    }
}

/// Where a sticker is along its moves, relative to its own placement: an
/// offset in multiples of its rendered size (y **down**, the `EffectDelta`
/// convention), a scale, and whether it is on the canvas at all.
public struct MotionSpot: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var scale: Double
    public var visible: Bool

    public init(x: Double = 0, y: Double = 0, scale: Double = 1, visible: Bool = true) {
        self.x = x
        self.y = y
        self.scale = scale
        self.visible = visible
    }

    public static let home = MotionSpot()
}

/// One move of one sticker: from where it was to where it goes, over
/// `duration` seconds from `at`, the way it gets about.
public struct MotionLeg: Equatable, Sendable {
    public enum Gait: Equatable, Sendable {
        /// Its move frames walk it (an even slide).
        case walk
        /// Its move frames hop it: an arc per loop of `cycle` seconds.
        case hops(cycle: TimeInterval)
        /// No move frames: it bounces along.
        case bounce
        /// It flies: a glide with a gentle bob.
        case fly
        /// Reduce Motion / calm mode: it fades out where it was and in
        /// where it goes.
        case fade
    }

    public var at: TimeInterval
    public var duration: TimeInterval
    public var from: MotionSpot
    public var to: MotionSpot
    public var gait: Gait
    /// The way it faces (+1 its art's own way, -1 mirrored) before and
    /// after: it turns at the start to face where it goes.
    public var facingFrom: Double
    public var facingTo: Double

    public init(
        at: TimeInterval, duration: TimeInterval, from: MotionSpot, to: MotionSpot, gait: Gait,
        facingFrom: Double = 1, facingTo: Double = 1
    ) {
        self.at = at
        self.duration = duration
        self.from = from
        self.to = to
        self.gait = gait
        self.facingFrom = facingFrom
        self.facingTo = facingTo
    }

    /// Whether its move frames play along (not while fading).
    public var travels: Bool { gait != .fade }
}

/// A sticker's moves through a story, in time order. Pure: what it adds at
/// any moment is a function of the time alone, so a seek or a dropped frame
/// never leaves a sticker half way.
public struct MotionPlan: Equatable, Sendable {
    public var legs: [MotionLeg]
    /// The way it faces before its first move.
    public var facing: Double

    public init(legs: [MotionLeg], facing: Double = 1) {
        self.legs = legs.sorted { $0.at < $1.at }
        self.facing = facing
    }

    /// How long a sticker takes to turn round.
    public static let turn: TimeInterval = 0.25
    static let hopHeight = 0.18
    static let flyBob = 0.08

    /// The last leg started by `time`, if any.
    public func leg(at time: TimeInterval) -> MotionLeg? {
        legs.last { $0.at <= time }
    }

    /// What the moves add to the sticker's placement at `time`.
    public func delta(at time: TimeInterval) -> EffectDelta {
        var delta = EffectDelta()
        guard let leg = leg(at: time) else { return delta }
        let p = leg.duration > 0 ? min(max((time - leg.at) / leg.duration, 0), 1) : 1
        var spot: MotionSpot
        switch leg.gait {
        case .fade:
            // Out where it was over the first half, in where it goes.
            spot = p < 0.5 ? leg.from : leg.to
            let fade = p < 0.5 ? 1 - p * 2 : (p - 0.5) * 2
            delta.opacityMul = fade
        case .fly:
            let k = p * p * (3 - 2 * p)
            spot = Self.mix(leg.from, leg.to, k)
            spot.y -= Self.flyBob * sin(2 * .pi * 1.5 * p) * (1 - p)
        case .walk:
            spot = Self.mix(leg.from, leg.to, p)
        case .bounce:
            let k = 1 - (1 - p) * (1 - p)
            spot = Self.mix(leg.from, leg.to, k)
            let hops = max(2, (abs(leg.to.x - leg.from.x) + abs(leg.to.y - leg.from.y)).rounded())
            spot.y -= Self.hopHeight * abs(sin(.pi * hops * p)) * (p < 1 ? 1 : 0)
        case .hops(let cycle):
            spot = Self.mix(leg.from, leg.to, p)
            if p < 1, cycle > 0 { spot.y -= Self.hopHeight * abs(sin(.pi * (time - leg.at) / cycle)) }
        }
        // Off the canvas: hidden once it is there, until it comes back.
        let visible = p >= 1 ? leg.to.visible : (leg.from.visible || leg.to.visible)
        if !visible { delta.opacityMul = 0 }
        delta.offsetXSelf = spot.x
        delta.offsetYSelf = spot.y
        delta.scaleMul = spot.scale
        return delta
    }

    /// The way it faces at `time`: its sign mirrors the art, and it passes
    /// through a squash as the sticker turns (never quite 0, so the art
    /// never vanishes).
    public func facing(at time: TimeInterval) -> Double {
        guard let leg = leg(at: time) else { return facing }
        guard leg.facingFrom != leg.facingTo else { return leg.facingTo }
        let p = min(max((time - leg.at) / Self.turn, 0), 1)
        let value = leg.facingFrom + (leg.facingTo - leg.facingFrom) * (p * p * (3 - 2 * p))
        return abs(value) < 0.05 ? (value < 0 ? -0.05 : 0.05) : value
    }

    /// The move in progress at `time` whose frames should play (its start
    /// and how long it travels), if any.
    public func travel(at time: TimeInterval) -> (at: TimeInterval, duration: TimeInterval)? {
        guard let leg = leg(at: time), leg.travels else { return nil }
        return (leg.at, leg.duration)
    }

    static func mix(_ a: MotionSpot, _ b: MotionSpot, _ k: Double) -> MotionSpot {
        MotionSpot(
            x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k,
            scale: a.scale * pow(b.scale / max(a.scale, 1e-6), k), visible: b.visible)
    }
}

/// Plans every sticker's moves in a story from its go triggers: where each
/// ends up, how long it takes and how it gets there. Pure and seeded; the
/// scene gives it the stickers on the stage and the world geometry.
public enum MotionPlanner {
    /// A sticker instance on the stage (placed by the child, or a visitor).
    public struct Actor: Sendable {
        public var id: UUID
        public var stickerID: String
        /// Its placement's centre, in world points.
        public var home: StagePoint
        /// Its rendered size at its placement, in world points.
        public var size: StageSize
        /// When it is free to move (a visitor once it has come in).
        public var readyAt: TimeInterval
        /// The way it faces at the start (a mirrored visitor: -1).
        public var facing: Double
        /// Walkers and flyers move; still things (a flower) don't.
        public var canMove: Bool
        public var flies: Bool

        public init(
            id: UUID, stickerID: String, home: StagePoint, size: StageSize, readyAt: TimeInterval = 0,
            facing: Double = 1, canMove: Bool = true, flies: Bool = false
        ) {
            self.id = id
            self.stickerID = stickerID
            self.home = home
            self.size = size
            self.readyAt = readyAt
            self.facing = facing
            self.canMove = canMove
            self.flies = flies
        }
    }

    /// On or under another sticker, the mover is at most this big relative
    /// to it (left alone when already smaller).
    public static let nestedScale = 0.75
    /// A walker never takes longer than this to get anywhere, nor less than
    /// `minTravel`.
    static let maxTravel: TimeInterval = 5
    static let minTravel: TimeInterval = 0.8
    static let fadeTime: TimeInterval = 0.8

    /// Where each actor is while the plan is built.
    private struct State {
        var actor: Actor
        var center: StagePoint
        var scale: Double
        var visible: Bool
        var busyUntil: TimeInterval
        var facing: Double
        var legs: [MotionLeg] = []
        /// The side it left by, to come back from.
        var leftBy: Double = 1
    }

    public static func plan<R: RandomNumberGenerator>(
        goes: [GoTrigger], actors: [Actor], features: [String: SceneFeature] = [:],
        moves: [String: StageMove] = [:], scene: StagePlanner.Scene, policy: EffectPolicy, random: inout R
    ) -> [UUID: MotionPlan] {
        var states = actors.map {
            State(actor: $0, center: $0.home, scale: 1, visible: true, busyUntil: $0.readyAt, facing: $0.facing)
        }
        for go in goes.sorted(by: { $0.at < $1.at }) {
            for index in states.indices where states[index].actor.stickerID == go.stickerID && states[index].actor.canMove {
                guard let leg = plan(go, for: index, in: &states, features: features, moves: moves, scene: scene,
                                     policy: policy, random: &random)
                else { continue }
                states[index].legs.append(leg)
            }
        }
        var plans: [UUID: MotionPlan] = [:]
        for state in states where !state.legs.isEmpty {
            plans[state.actor.id] = MotionPlan(legs: state.legs, facing: state.actor.facing)
        }
        return plans
    }

    private static func plan<R: RandomNumberGenerator>(
        _ go: GoTrigger, for index: Int, in states: inout [State], features: [String: SceneFeature],
        moves: [String: StageMove], scene: StagePlanner.Scene, policy: EffectPolicy, random: inout R
    ) -> MotionLeg? {
        let state = states[index]
        let me = state.actor
        let start = max(go.at, state.busyUntil)
        var scale = 1.0
        var target: StagePoint
        var visibleAfter = true
        let myWidth = { (s: Double) in me.size.width * s }, myHeight = { (s: Double) in me.size.height * s }
        let others = states.indices.filter { $0 != index && states[$0].visible }

        switch go.kind {
        case .to, .on, .under:
            guard let name = go.target else { return nil }
            if go.kind == .to, features[name] != nil, !states.contains(where: { $0.actor.stickerID == name }) {
                // A place in the scene: its freest spot on screen.
                let stage = StickerStage(entrance: me.flies ? .fly : .hop, on: [name])
                let rects = StagePlanner.places(for: stage, features: features, in: scene).first ?? []
                let obstacles = others.map {
                    StageObstacle(center: states[$0].center, radius: max(states[$0].actor.size.width, states[$0].actor.size.height) * states[$0].scale * StagePlanner.footprint)
                }
                let radius = max(me.size.width, me.size.height) * StagePlanner.footprint
                guard !rects.isEmpty else { return nil }
                target = (StagePlanner.freeSpot(in: rects, radius: radius, avoiding: obstacles, random: &random)
                    ?? StagePlanner.randomSpot(in: rects, random: &random)).point
            } else {
                // The nearest of that sticker's instances on the canvas now.
                guard let other = others.filter({ states[$0].actor.stickerID == name })
                    .min(by: { distance(states[$0].center, state.center) < distance(states[$1].center, state.center) })
                else { return nil }
                let them = states[other]
                let tw = them.actor.size.width * them.scale, th = them.actor.size.height * them.scale
                switch go.kind {
                case .to:
                    // Beside it, on the side it comes from, a little overlapping.
                    let side: Double = state.center.x <= them.center.x ? -1 : 1
                    target = StagePoint(
                        x: them.center.x + side * (tw / 2 + myWidth(1) / 2) * 0.72,
                        y: me.flies
                            ? them.center.y + th * 0.15
                            : them.center.y - th / 2 + myHeight(1) / 2)  // feet on the same line
                case .on:
                    scale = min(1, nestedScale * th / max(me.size.height, 1))
                    target = StagePoint(x: them.center.x, y: them.center.y + th * 0.32 + myHeight(scale) * 0.3)
                default:  // under
                    scale = min(1, nestedScale * th / max(me.size.height, 1))
                    target = StagePoint(x: them.center.x + tw * 0.08, y: them.center.y - th / 2 + myHeight(scale) / 2)
                }
            }
        case .away:
            let side: Double = state.center.x < scene.visible.midX ? -1 : 1
            let x = side < 0 ? scene.visible.minX - myWidth(1) * 0.8 : scene.visible.maxX + myWidth(1) * 0.8
            target = StagePoint(x: x, y: state.center.y)
            visibleAfter = false
            states[index].leftBy = side
        case .back:
            target = me.home
        }
        if visibleAfter {
            // Always wholly on screen: pushed in from any edge it would cross
            // (on or under another sticker near an edge, that means more
            // overlap, never a cut-off sticker).
            let w = myWidth(scale) / 2, h = myHeight(scale) / 2
            let v = scene.visible
            target.x = min(max(target.x, v.minX + w), max(v.maxX - w, v.minX + w))
            target.y = min(max(target.y, v.minY + h), max(v.maxY - h, v.minY + h))
        }

        // Coming back onto the canvas: from just off the side it left by.
        var from = state.center
        if !state.visible {
            from = StagePoint(
                x: state.leftBy < 0 ? scene.visible.minX - myWidth(1) * 0.8 : scene.visible.maxX + myWidth(1) * 0.8,
                y: target.y)
        }
        let dx = target.x - from.x, dy = target.y - from.y
        let widths = (dx * dx + dy * dy).squareRoot() / max(me.size.width, 1)
        guard widths > 0.05 || abs(scale - state.scale) > 0.01 || visibleAfter != state.visible else { return nil }

        // How it gets there, and for how long.
        let move = moves[me.stickerID]
        var gait: MotionLeg.Gait
        var duration: TimeInterval
        if policy.isCalm {
            gait = .fade
            duration = fadeTime
        } else if me.flies {
            gait = .fly
            duration = min(max(widths * 0.3 + 0.6, 1.2), 3.4)
        } else if let move, let cycle = move.cycle, cycle > 0, move.stride > 0, policy.allowsLiveAnimations {
            gait = move.hops ? .hops(cycle: cycle) : .walk
            duration = min(max(widths / (move.stride / cycle), minTravel), maxTravel)
        } else {
            gait = .bounce
            duration = min(max(widths * 0.35, minTravel), 3.2)
        }

        // It turns to face where it goes (when its frames have a way round).
        var facing = state.facing
        if let way = move?.facing, abs(dx) > me.size.width * 0.1, gait != .fade {
            let right = dx > 0
            facing = (way == .right) == right ? 1 : -1
        }

        let base = me.home
        let spot = { (p: StagePoint, s: Double, visible: Bool) in
            MotionSpot(
                x: (p.x - base.x) / max(me.size.width, 1), y: -(p.y - base.y) / max(me.size.height, 1),
                scale: s, visible: visible)
        }
        let leg = MotionLeg(
            at: start, duration: duration, from: spot(from, state.scale, true),
            to: spot(target, scale, visibleAfter), gait: gait, facingFrom: state.facing, facingTo: facing)
        states[index].center = target
        states[index].scale = scale
        states[index].visible = visibleAfter
        states[index].busyUntil = start + duration
        states[index].facing = facing
        return leg
    }

    static func distance(_ a: StagePoint, _ b: StagePoint) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
