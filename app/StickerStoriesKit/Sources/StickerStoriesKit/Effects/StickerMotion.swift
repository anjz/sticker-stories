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
    /// to it — at least 35 % smaller (left alone when already smaller).
    public static let nestedScale = 0.65
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
        /// Whom it stands beside ("to:<id>"), so the next one that goes
        /// there takes the other side.
        var at: String?
    }

    public static func plan<R: RandomNumberGenerator>(
        goes: [GoTrigger], actors: [Actor], features: [String: SceneFeature] = [:],
        moves: [String: StageMove] = [:], scene: StagePlanner.Scene, policy: EffectPolicy, random: inout R
    ) -> [UUID: MotionPlan] {
        var planner = Planner(
            states: actors.map {
                State(actor: $0, center: $0.home, scale: 1, visible: true, busyUntil: $0.readyAt, facing: $0.facing)
            },
            features: features, moves: moves, scene: scene, policy: policy)
        for go in goes.sorted(by: { $0.at < $1.at }) {
            for index in planner.states.indices
            where planner.states[index].actor.stickerID == go.stickerID && planner.states[index].actor.canMove {
                planner.apply(go, to: index, random: &random)
            }
        }
        var plans: [UUID: MotionPlan] = [:]
        for state in planner.states where !state.legs.isEmpty {
            plans[state.actor.id] = MotionPlan(legs: state.legs, facing: state.actor.facing)
        }
        return plans
    }

    /// How much two stickers sharing a spot on or under another overlap, as
    /// a fraction of the narrower one's width: tucked in together, a little
    /// squashed, both still easy to see.
    public static let sharedOverlap = 0.25

    private struct Planner {
        var states: [State]
        let features: [String: SceneFeature]
        let moves: [String: StageMove]
        let scene: StagePlanner.Scene
        let policy: EffectPolicy
        /// Who shares a spot on or under a sticker ("under:<id>"), left to
        /// right.
        var groups: [String: [Int]] = [:]

        mutating func apply<R: RandomNumberGenerator>(_ go: GoTrigger, to index: Int, random: inout R) {
            let state = states[index]
            let start = max(go.at, state.busyUntil)
            // Leaving a shared spot: the others close up. Whoever it stood
            // beside, it no longer does (a move to a sticker sets it again).
            let left = leaveGroup(index)
            states[index].at = nil

            if go.kind == .on || go.kind == .under, let name = go.target, let other = nearest(name, to: index) {
                let key = "\(go.kind.rawValue):\(states[other].actor.id)"
                var members = groups[key] ?? []
                // In on the side it comes from.
                if state.center.x < states[other].center.x { members.insert(index, at: 0) } else { members.append(index) }
                groups[key] = members
                relayout(key, start: start, mover: index)
            } else if let destination = destination(go, for: index, random: &random) {
                leg(index, to: destination.point, scale: destination.scale, visible: destination.visible, start: start)
            }
            if let left, left != groupKey(of: index) { relayout(left, start: start, mover: nil) }
        }

        func groupKey(of index: Int) -> String? {
            groups.first { $0.value.contains(index) }?.key
        }

        mutating func leaveGroup(_ index: Int) -> String? {
            guard let key = groupKey(of: index) else { return nil }
            groups[key]?.removeAll { $0 == index }
            return key
        }

        /// The nearest instance of that sticker on the canvas now.
        func nearest(_ name: String, to index: Int) -> Int? {
            states.indices.filter { $0 != index && states[$0].visible && states[$0].actor.stickerID == name }
                .min { distance(states[$0].center, states[index].center) < distance(states[$1].center, states[index].center) }
        }

        /// Lays out everyone on or under one sticker: side by side, each
        /// shrunk to at most `nestedScale` of it, overlapping by
        /// `sharedOverlap`, the whole row centred on it — and pushed in as a
        /// row from any screen edge. The mover goes to its place; the others
        /// shuffle to theirs.
        mutating func relayout(_ key: String, start: TimeInterval, mover: Int?) {
            guard let members = groups[key], !members.isEmpty,
                let targetID = UUID(uuidString: String(key.split(separator: ":")[1])),
                let t = states.firstIndex(where: { $0.actor.id == targetID })
            else { return }
            let on = key.hasPrefix("on:")
            let them = states[t]
            let th = them.actor.size.height * them.scale
            var slots: [(index: Int, x: Double, y: Double, scale: Double, w: Double, h: Double)] = []
            var x = 0.0
            for (n, i) in members.enumerated() {
                let a = states[i].actor
                let scale = min(1, nestedScale * th / max(a.size.height, 1))
                let w = a.size.width * scale, h = a.size.height * scale
                if n > 0 {
                    let prev = slots[n - 1]
                    x += prev.w / 2 + w / 2 - sharedOverlap * min(prev.w, w)
                }
                let y = on ? them.center.y + th * 0.32 + h * 0.3 : them.center.y - th / 2 + h / 2
                slots.append((i, x, y, scale, w, h))
            }
            // Centre the row on the sticker, then keep it on screen.
            let left = slots.map { $0.x - $0.w / 2 }.min() ?? 0, right = slots.map { $0.x + $0.w / 2 }.max() ?? 0
            var shift = them.center.x - (left + right) / 2
            let v = scene.visible
            if left + shift < v.minX { shift += v.minX - (left + shift) }
            if right + shift > v.maxX { shift -= (right + shift) - v.maxX }
            for slot in slots {
                var point = StagePoint(x: slot.x + shift, y: slot.y)
                point.x = min(max(point.x, v.minX + slot.w / 2), max(v.maxX - slot.w / 2, v.minX + slot.w / 2))
                point.y = min(max(point.y, v.minY + slot.h / 2), max(v.maxY - slot.h / 2, v.minY + slot.h / 2))
                let begin = slot.index == mover ? start : max(start, states[slot.index].busyUntil)
                leg(slot.index, to: point, scale: slot.scale, visible: true, start: begin, shuffle: slot.index != mover)
            }
        }

        /// Where a move other than on/under ends: beside a sticker, a place
        /// in the scene, off the canvas, back home.
        mutating func destination<R: RandomNumberGenerator>(
            _ go: GoTrigger, for index: Int, random: inout R
        ) -> (point: StagePoint, scale: Double, visible: Bool)? {
            let state = states[index]
            let me = state.actor
            let others = states.indices.filter { $0 != index && states[$0].visible }
            switch go.kind {
            case .to:
                guard let name = go.target else { return nil }
                if features[name] != nil, !states.contains(where: { $0.actor.stickerID == name }) {
                    // A place in the scene: its freest spot on screen.
                    let stage = StickerStage(entrance: me.flies ? .fly : .hop, on: [name])
                    let rects = StagePlanner.places(for: stage, features: features, in: scene).first ?? []
                    guard !rects.isEmpty else { return nil }
                    let obstacles = others.map {
                        StageObstacle(
                            center: states[$0].center,
                            radius: max(states[$0].actor.size.width, states[$0].actor.size.height) * states[$0].scale
                                * StagePlanner.footprint)
                    }
                    let radius = max(me.size.width, me.size.height) * StagePlanner.footprint
                    let point = (StagePlanner.freeSpot(in: rects, radius: radius, avoiding: obstacles, random: &random)
                        ?? StagePlanner.randomSpot(in: rects, random: &random)).point
                    return (point, 1, true)
                }
                guard let other = nearest(name, to: index) else { return nil }
                let them = states[other]
                let tw = them.actor.size.width * them.scale, th = them.actor.size.height * them.scale
                // Beside it, on the side it comes from, a little overlapping;
                // the next one to come takes the other side, then further out.
                let key = "to:\(them.actor.id)"
                let beside = states.indices.filter { $0 != index && states[$0].at == key }
                let xs = beside.map { states[$0].center.x - them.center.x }
                let onSide = { (side: Double) in xs.filter { $0 * side > 0 }.count }
                // Its own side if free, else the other; both taken, further out
                // on the emptier one.
                var side: Double = state.center.x <= them.center.x ? -1 : 1
                if onSide(side) > onSide(-side) { side = -side }
                let already = onSide(side) * 2
                let feetLevel = them.center.y - th / 2 + me.size.height / 2  // feet on the same line
                let point = StagePoint(
                    x: them.center.x + side * (tw / 2 + me.size.width / 2) * (0.72 + 0.6 * Double(already / 2)),
                    y: me.flies
                        ? them.center.y + th * 0.15
                        // A walker going to a flyer up on a branch or in the
                        // sky stays on the ground, just below it.
                        : them.actor.flies && feetLevel > state.center.y + me.size.height
                            ? state.center.y : feetLevel)
                states[index].at = key
                return (point, 1, true)
            case .away:
                let side: Double = state.center.x < scene.visible.midX ? -1 : 1
                let x = side < 0 ? scene.visible.minX - me.size.width * 0.8 : scene.visible.maxX + me.size.width * 0.8
                states[index].leftBy = side
                return (StagePoint(x: x, y: state.center.y), 1, false)
            case .back:
                return (me.home, 1, true)
            case .on, .under:
                return nil
            }
        }

        /// Adds the leg that takes a sticker to `point`: the way it gets
        /// about, for as long as the distance needs, turned to face where it
        /// goes (not for a little shuffle to make room).
        mutating func leg(
            _ index: Int, to point: StagePoint, scale: Double, visible: Bool, start: TimeInterval, shuffle: Bool = false
        ) {
            let state = states[index]
            let me = state.actor
            var target = point
            if visible {
                // Always wholly on screen: pushed in from any edge it would cross.
                let w = me.size.width * scale / 2, h = me.size.height * scale / 2
                let v = scene.visible
                target.x = min(max(target.x, v.minX + w), max(v.maxX - w, v.minX + w))
                target.y = min(max(target.y, v.minY + h), max(v.maxY - h, v.minY + h))
            }
            // Coming back onto the canvas: from just off the side it left by.
            var from = state.center
            if !state.visible {
                from = StagePoint(
                    x: state.leftBy < 0 ? scene.visible.minX - me.size.width * 0.8 : scene.visible.maxX + me.size.width * 0.8,
                    y: target.y)
            }
            let dx = target.x - from.x, dy = target.y - from.y
            let widths = (dx * dx + dy * dy).squareRoot() / max(me.size.width, 1)
            guard widths > 0.05 || abs(scale - state.scale) > 0.01 || visible != state.visible else { return }

            let move = moves[me.stickerID]
            var gait: MotionLeg.Gait
            var duration: TimeInterval
            if policy.isCalm {
                gait = .fade
                duration = fadeTime
            } else if me.flies {
                gait = .fly
                duration = min(max(widths * 0.3 + 0.6, shuffle ? 0.6 : 1.2), 3.4)
            } else if let move, let cycle = move.cycle, cycle > 0, move.stride > 0, policy.allowsLiveAnimations {
                gait = move.hops ? .hops(cycle: cycle) : .walk
                duration = min(max(widths / (move.stride / cycle), shuffle ? 0.5 : minTravel), maxTravel)
            } else {
                gait = .bounce
                duration = min(max(widths * 0.35, shuffle ? 0.5 : minTravel), 3.2)
            }
            var facing = state.facing
            if !shuffle, let way = move?.facing, abs(dx) > me.size.width * 0.1, gait != .fade {
                facing = (way == .right) == (dx > 0) ? 1 : -1
            }
            let base = me.home
            let spot = { (p: StagePoint, s: Double, visible: Bool) in
                MotionSpot(
                    x: (p.x - base.x) / max(me.size.width, 1), y: -(p.y - base.y) / max(me.size.height, 1),
                    scale: s, visible: visible)
            }
            states[index].legs.append(MotionLeg(
                at: start, duration: duration, from: spot(from, state.scale, true), to: spot(target, scale, visible),
                gait: gait, facingFrom: state.facing, facingTo: facing))
            states[index].center = target
            states[index].scale = scale
            states[index].visible = visible
            states[index].busyUntil = start + duration
            states[index].facing = facing
        }
    }

    static func distance(_ a: StagePoint, _ b: StagePoint) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
