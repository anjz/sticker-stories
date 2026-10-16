import Foundation

/// A sticker on the stage, as the director plans it (`docs/stage3d.md`).
public struct StageActor: Sendable {
    public var id: UUID
    public var stickerID: String
    /// Its drawing's height at depth 1 (`SceneSpace.sizes`).
    public var size: Double
    /// Its drawing's width over its height.
    public var ratio: Double
    public var stage: StickerStage
    /// Its moves, its usual one first (`StageMove`).
    public var moves: [StageMove]
    /// How far its art reaches in front of its centre (its beak), as a
    /// fraction of its width: puts its front, not its centre, on bark.
    public var front: Double
    /// Where the child put its feet (art points); nil for a visitor.
    public var placed: SceneSpace.Point?
    public var facing: Double
    /// Its size class (`StickerSize`): where the director may choose, the
    /// small ones come to the front, where their details show.
    public var stature: StickerSize?

    public init(
        id: UUID, stickerID: String, size: Double, ratio: Double, stage: StickerStage = .default,
        moves: [StageMove] = [], front: Double = 0.4, placed: SceneSpace.Point? = nil, facing: Double = 1,
        stature: StickerSize? = nil
    ) {
        self.id = id
        self.stickerID = stickerID
        self.size = size
        self.ratio = ratio
        self.stage = stage
        self.moves = moves
        self.front = front
        self.placed = placed
        self.facing = facing
        self.stature = stature
    }

    public var width: Double { size * ratio }

    /// How much it wants a spot near the front (0…1): tiny and small
    /// characters are hard to see far back or half hidden.
    public var wantsFront: Double {
        switch stature {
        case .tiny: 1
        case .small: 0.75
        case .medium: 0.25
        default: 0
        }
    }
    public var canMove: Bool { stage.entrance != .grow }
}

/// Plans a whole story on the stage, in space (`docs/stage3d.md`): where
/// the child's stickers start, where visitors come in and how, and every
/// move the story asks for — beside someone, on or under them, at a place,
/// away, back — along paths on the ground around the water and the trees'
/// roots, or through the air. Pure and seeded.
public enum StageDirector {
    /// How long the child's stickers take, as a story starts, to get to
    /// where they can be and to the size their depth makes them.
    public static let settle: TimeInterval = 1.2
    static let minTravel: TimeInterval = 0.8
    static let maxTravel: TimeInterval = 6
    static let fadeTime: TimeInterval = 0.8
    /// How much faster or slower than drawn a move's frames may play to
    /// keep pace with the ground it covers.
    static let rates: ClosedRange<Double> = 0.6...2.5
    /// How far in front of whom it is with a sticker stands, in depth.
    static let inFront = SceneSpace.inFront
    /// Two sharing a spot overlap by this much of the narrower one.
    static let sharedOverlap = 0.25
    /// A flyer that cannot hover circles this many of its widths either
    /// side of its spot, and comes this much of its depth nearer.
    static let lapAcross = 0.9
    static let lapToward = 0.15
    /// How much of a circling flyer the planes in front may hide.
    static let lapHidden = 0.25

    /// - Parameter cast: the stickers the story uses (names, moves, cues
    ///   on); the child's other stickers that stand in its way move aside to
    ///   the back and the sides as it starts. Nil: nobody moves aside.
    public static func plan<R: RandomNumberGenerator>(
        world: StageWorld, screen: StageScreen, actors: [StageActor], entrances: [EntranceTrigger],
        goes: [GoTrigger], policy: EffectPolicy, cast: Set<String>? = nil, random: inout R
    ) -> [UUID: StagePlan] {
        var director = Director(world: world, screen: screen, policy: policy, actors: actors)
        director.cast = cast
        director.settleThePlaced()
        if let cast {
            // Where the story's cast will be and pass, from a first run;
            // then whoever is in its way steps aside, and the story is
            // planned again round them.
            var dry = director
            var dryRandom = SplitMix(seed: 1)
            dry.run(entrances: entrances, goes: goes, random: &dryRandom)
            director.parkExtras(cast: cast, around: dry, random: &random)
        }
        director.run(entrances: entrances, goes: goes, random: &random)
        var plans: [UUID: StagePlan] = [:]
        for (i, state) in director.states.enumerated() {
            // Left in the air, one that cannot hover flies round its spot.
            let legs = state.legs.map { leg in
                var leg = leg
                leg.circling = director.circling(i, after: leg)
                return leg
            }
            plans[state.actor.id] = StagePlan(
                start: state.start, startsVisible: state.startsVisible, legs: legs, size: state.actor.size)
        }
        return plans
    }

    /// The stickers a story uses: those it brings in, moves, sends someone
    /// to, or cues an action, a face or an effect on (`all` reaches
    /// everyone, so it names no one).
    public static func cast(
        entrances: [EntranceTrigger], goes: [GoTrigger], live: [LiveAnimationTrigger],
        faces: [ExpressionTrigger], effects: [EffectTrigger]
    ) -> Set<String> {
        var cast = Set(entrances.map(\.stickerID))
        for go in goes {
            cast.insert(go.stickerID)
            if let target = go.target { cast.insert(target) }
        }
        cast.formUnion(live.map(\.stickerID))
        cast.formUnion(faces.map(\.stickerID))
        cast.formUnion(effects.map(\.stickerID))
        cast.remove(EffectTrigger.allStickers)
        return cast
    }

    /// The live triggers with every action cued while its sticker is on
    /// its way somewhere held back until it has got there: a sticker on
    /// the move shows its move (walking, hopping, flying) until it stops,
    /// and an action that has a place (`PlacementPlanner.delayed`) waits
    /// for the move that takes it there.
    public static func delayed(
        _ live: [LiveAnimationTrigger], plans: [UUID: StagePlan], stickers: [UUID: String], places: Set<LiveAnimationKey>
    ) -> [LiveAnimationTrigger] {
        live.map { trigger in
            var start = trigger.at
            for (id, plan) in plans where stickers[id] == trigger.stickerID {
                // Legs follow one another (to the shore, then swimming): on
                // to the end of the last one it is still on its way in.
                for leg in plan.legs where leg.travels && leg.at <= start + 1e-6 && start < leg.end {
                    start = leg.end
                }
            }
            var moved = trigger
            moved.at = start
            return moved
        }
    }

    struct State {
        var actor: StageActor
        var start: StagePose
        var startsVisible: Bool
        var pose: StagePose
        var home: StagePose
        var visible: Bool
        var busyUntil: TimeInterval = 0
        var legs: [StageLeg] = []
        /// The way the story last named (`by`); nil for its usual one.
        var by: String?
        /// Whom it stands beside, if anyone ("beside:<id>").
        var beside: String?
        /// The side it went off by (−1 left, 1 right).
        var leftBy: Double = 1
        var hasEntered: Bool
    }

    struct Director {
        let world: StageWorld
        let screen: StageScreen
        let policy: EffectPolicy
        var states: [State]
        /// The stickers the story uses: they come first in being seen.
        var cast: Set<String>?
        /// The moves an entrance has already made (it came in straight to
        /// the place): not made again.
        var made: Set<String> = []
        /// Who shares a spot on or under a sticker ("on:<id>"), left to right.
        var groups: [String: [Int]] = [:]

        init(world: StageWorld, screen: StageScreen, policy: EffectPolicy, actors: [StageActor]) {
            self.world = world
            self.screen = screen
            self.policy = policy
            states = actors.map { actor in
                let pose = StagePose(position: Vec3(0, 0, world.space.stand.near), support: .off, facing: actor.facing)
                return State(
                    actor: actor, start: pose, startsVisible: actor.placed != nil, pose: pose, home: pose,
                    visible: actor.placed != nil, hasEntered: actor.placed != nil)
            }
        }

        /// Plans the story's entrances and moves in the order the story has
        /// them (at the same moment, the entrance first): each one chooses
        /// its spot on the stage as it is then.
        mutating func run<R: RandomNumberGenerator>(entrances: [EntranceTrigger], goes: [GoTrigger], random: inout R) {
            var entered = Set<String>()
            let firsts = entrances.sorted { $0.at < $1.at }.filter { entered.insert($0.stickerID).inserted }
            let cues = (firsts.map { (at: $0.at, order: 0, cue: Cue.entrance($0)) }
                + goes.map { (at: $0.at, order: 1, cue: Cue.go($0)) })
                .enumerated().sorted { a, b in
                    (a.element.at, a.element.order, a.offset) < (b.element.at, b.element.order, b.offset)
                }.map(\.element.cue)
            for cue in cues {
                switch cue {
                case .entrance(let entrance):
                    for i in states.indices where states[i].actor.stickerID == entrance.stickerID && states[i].actor.placed == nil {
                        enter(i, entrance, goes: goes, random: &random)
                    }
                case .go(let go):
                    guard !made.contains(Self.key(go)) else { continue }
                    for i in states.indices
                    where states[i].actor.stickerID == go.stickerID && states[i].actor.canMove && states[i].hasEntered {
                        apply(go, to: i, random: &random)
                    }
                }
            }
        }

        static func key(_ go: GoTrigger) -> String { "\(go.stickerID)@\(go.at)" }

        enum Cue { case entrance(EntranceTrigger), go(GoTrigger) }

        // MARK: Out of the story's way

        /// The child's stickers the story does not use and that stand where
        /// its cast will be or pass step aside as it starts: to the freest
        /// land on screen away from the cast, the further back and the
        /// nearer the sides the better, not far from where they were.
        mutating func parkExtras<R: RandomNumberGenerator>(cast: Set<String>, around dry: Director, random: inout R) {
            let end = (dry.states.flatMap(\.legs).map(\.end).max() ?? 0) + 0.5
            var taken: [StageRect] = []
            for state in dry.states where cast.contains(state.actor.stickerID) {
                let plan = StagePlan(start: state.start, startsVisible: state.startsVisible, legs: state.legs, size: state.actor.size)
                var t = 0.0
                while t <= end {
                    let s = plan.sample(at: t)
                    if s.opacity > 0.5 {
                        taken.append(world.drawing(at: s.position, size: state.actor.size, ratio: state.actor.ratio))
                    }
                    t += 0.25
                }
            }
            guard !taken.isEmpty else { return }
            // As a share of the smaller of the two: a bear over a snail
            // hides all of it, however little of the bear that is.
            func overlap(_ r: StageRect) -> Double {
                let area = { (r: StageRect) in max((r.maxX - r.minX) * (r.maxY - r.minY), 1) }
                return taken.map { t in
                    max(0, min(r.maxX, t.maxX) - max(r.minX, t.minX)) * max(0, min(r.maxY, t.maxY) - max(r.minY, t.minY))
                        / min(area(r), area(t))
                }.max() ?? 0
            }
            let lands = world.grounds.filter { !$0.water }.map(\.place)
            for i in states.indices where states[i].actor.placed != nil && !cast.contains(states[i].actor.stickerID) {
                guard overlap(drawing(i, at: states[i].home.position)) > 0.15 else {
                    taken.append(drawing(i, at: states[i].home.position))
                    continue
                }
                let home = states[i].home.position
                let back = world.space.back
                let candidates = lands.flatMap { spots($0, for: i, move: way(i).move) }
                    .filter {
                        onScreen(i, at: $0.position) && !covered(i, at: $0.position) && overlap(drawing(i, at: $0.position)) < 0.02
                            && hiddenWithHeadroom(i, at: $0.position) < 0.05
                    }
                let best = candidates.max { a, b in
                    score(a) < score(b)
                }
                func score(_ pose: StagePose) -> Double {
                    let p = pose.position
                    let side = abs(world.project(p).u - 0.5) * 2
                    // Back and to the sides — a small one not so far back
                    // it is lost — and never behind the trees.
                    let front = states[i].actor.wantsFront
                    return p.z / back * (1 - 0.8 * front) + side * 0.6 - (p - home).length * 0.15
                        - hidden(i, at: p) * 1.5
                }
                guard let spot = best else { continue }
                // From where the child had it, as the story starts.
                states[i].legs.removeAll()
                states[i].pose = states[i].start
                states[i].busyUntil = 0
                travel(i, to: spot, begin: 0, kind: states[i].actor.canMove ? .settle : .settle)
                if !states[i].actor.canMove, var leg = states[i].legs.last {
                    leg.gait = .fade
                    leg.move = nil
                    states[i].legs[states[i].legs.count - 1] = leg
                }
                states[i].home = states[i].pose
                taken.append(drawing(i, at: spot.position))
            }
        }

        // MARK: Ways and belonging

        /// The move it goes by now and whether that way flies.
        func way(_ i: Int) -> (move: StageMove?, flies: Bool) {
            let me = states[i].actor
            let by = states[i].by
            let move = StageMove.pick(me.moves, by: by)
            if let move, by != nil, move.id == by { return (move, move.flies) }
            return (move, me.stage.entrance == .fly || move?.flies == true)
        }

        /// The places it belongs in going this way: its stage's, and the
        /// way's own (a duckling swimming: the pond).
        func belongs(_ i: Int, _ move: StageMove?) -> Set<String> {
            Set(states[i].actor.stage.on + (move?.on ?? []))
        }

        /// Whether every way it gets about belongs to the water (a fish).
        func onlyGetsAboutInWater(_ i: Int) -> Bool {
            let moves = states[i].actor.moves
            return !moves.isEmpty && moves.allSatisfy { !$0.on.isEmpty }
        }

        /// Whether, resting at `pose`, it is up in the air on its wings
        /// (in a place's air, or hovering by someone) rather than on
        /// something.
        func hovers(_ i: Int, at pose: StagePose) -> Bool {
            switch pose.support {
            case .air: return true
            case .beside: return pose.position.y > 0.01 && (way(i).flies || states[i].actor.stage.entrance == .fly)
            default: return false
            }
        }

        /// The loop it flies round its spot once `leg` leaves it in the
        /// air, when its flight cannot hover (`StageMove.hovers`): about
        /// its width either side and a little nearer the camera, narrower
        /// where that keeps it on screen and out from behind the trees.
        /// Nil for one that hovers, lands or goes on its way.
        func circling(_ i: Int, after leg: StageLeg) -> StageLeg.Circling? {
            guard leg.stays, leg.gait == .fly, let id = leg.move, let spot = leg.path.last,
                let move = states[i].actor.moves.first(where: { $0.id == id }), move.flies, !move.hovers
            else { return nil }
            // Out the way its art looks (`StagePlan.lap`).
            let art = move.facing == .left ? -1.0 : 1.0
            let way = (leg.facingTo < 0 ? -1.0 : 1.0) * art
            var loop = StageLeg.Circling(across: 0, toward: 0, art: art)
            for k in [1, 0.7, 0.45, 0.3] {
                loop = StageLeg.Circling(
                    across: StageDirector.lapAcross * states[i].actor.width * k,
                    toward: max(min(StageDirector.lapToward * spot.z * k, spot.z - world.space.stand.near), 0), art: art)
                let round = (1..<12).map { k -> Vec3 in
                    let a = 2 * Double.pi * Double(k) / 12
                    return spot + Vec3(way * loop.across * sin(a), 0, -loop.toward * (1 - cos(a)) / 2)
                }
                if round.allSatisfy({ onScreen(i, at: $0) && hidden(i, at: $0) <= StageDirector.lapHidden }) { break }
            }
            return loop
        }

        /// The move it flies by, when its frames may play.
        func flyingMove(_ i: Int) -> String? {
            guard policy.allowsLiveAnimations, !policy.isCalm else { return nil }
            let move = way(i).move
            if let move, move.flies, move.cycle != nil { return move.id }
            return states[i].actor.moves.first { $0.flies && $0.cycle != nil }?.id
        }

        // MARK: Screen

        func drawing(_ i: Int, at p: Vec3) -> StageRect {
            world.drawing(at: p, size: states[i].actor.size, ratio: states[i].actor.ratio)
        }

        func onScreen(_ i: Int, at p: Vec3) -> Bool {
            let r = drawing(i, at: p), c = screen.clear
            return r.minX >= c.minX && r.maxX <= c.maxX && r.minY >= c.minY && r.maxY <= c.maxY
        }

        /// How much of it the planes in front hide at `p` (0…1).
        func hidden(_ i: Int, at p: Vec3) -> Double {
            world.hidden(drawing(i, at: p), atDepth: p.z)
        }

        /// The same with the room above it (for whoever climbs on it, an
        /// effect over it), for choosing where it goes.
        func hiddenWithHeadroom(_ i: Int, at p: Vec3) -> Double {
            var r = drawing(i, at: p)
            r.maxY += (r.maxY - r.minY) * 0.5
            return world.hidden(r, atDepth: p.z)
        }

        /// How much it matters that the viewer sees it: fully for the
        /// story's cast, less for the child's other stickers.
        func weight(_ i: Int) -> Double {
            cast.map { $0.contains(states[i].actor.stickerID) ? 1 : 0.4 } ?? 1
        }

        /// What the other stickers on the stage and it would hide of each
        /// other with it at `p`, for the viewer: the share of it behind
        /// those nearer, and the most of anyone farther it would stand in
        /// front of, each as much as that one matters (`weight`). Those in
        /// `except` (whom it stands beside) do not count.
        func blocking(_ i: Int, at p: Vec3, except: Set<Int> = []) -> Double {
            let mine = drawing(i, at: p)
            var nearer: [StageRect] = []
            var hides = 0.0
            for o in states.indices where o != i && !except.contains(o) && states[o].visible && states[o].hasEntered {
                let q = states[o].pose.position
                let theirs = drawing(o, at: q)
                if q.z < p.z - 1e-6 {
                    nearer.append(theirs)
                } else if q.z > p.z + 1e-6 {
                    hides = max(hides, StageWorld.hidden(theirs, behind: [mine]) * weight(o))
                }
            }
            return StageWorld.hidden(mine, behind: nearer) * weight(i) + hides
        }

        func covered(_ i: Int, at p: Vec3) -> Bool {
            let r = drawing(i, at: p)
            return screen.avoid.contains { a in r.minX < a.maxX && r.maxX > a.minX && r.minY < a.maxY && r.maxY > a.minY }
        }

        /// Off the visible art at the sides: where entrances start and the
        /// ones going away end, walkable for anyone.
        func offstage(_ p: Vec2) -> Bool {
            let u = 0.5 + p.x / (world.aspect * max(p.z, 0.05))
            return u * world.frame.width < screen.visible.minX || u * world.frame.width > screen.visible.maxX
        }

        /// Pushed in from the screen's sides at its depth so it is wholly on
        /// screen (only across: its depth is its place).
        func pushedOnScreen(_ i: Int, _ p: Vec3) -> Vec3 {
            let r = drawing(i, at: p), c = screen.clear
            var dx = 0.0
            if r.minX < c.minX { dx = c.minX - r.minX } else if r.maxX > c.maxX { dx = c.maxX - r.maxX }
            guard dx != 0 else { return p }
            var q = p
            q.x += dx / world.frame.width * world.aspect * max(p.z, 0.05)
            return q
        }

        /// The side of the screen nearer a point (−1 left, 1 right).
        func nearerSide(_ p: Vec3) -> Double {
            world.screen(p).x < (screen.visible.minX + screen.visible.maxX) / 2 ? -1 : 1
        }

        /// Just off the visible art on `side`, at `p`'s depth.
        func offstagePoint(_ i: Int, side: Double, at p: Vec3) -> Vec3 {
            let z = max(p.z, 0.05)
            let edge = (side < 0 ? screen.visible.minX : screen.visible.maxX) / world.frame.width
            let x = (edge - 0.5) * world.aspect * z + side * states[i].actor.width * 0.8
            return Vec3(x, p.y, z)
        }

        // MARK: The cast's start

        /// Each child's sticker starts where its feet are — on the ground,
        /// a perch, in the air — and, standing where it cannot, gets to the
        /// nearest place it can as the story starts.
        mutating func settleThePlaced() {
            for i in states.indices {
                guard let feet = states[i].actor.placed else { continue }
                let (from, standing) = placedPose(i, feet)
                let valid = outFromBehind(i, standing)
                states[i].start = from
                states[i].pose = from
                states[i].home = valid
                if (valid.position - from.position).length > 0.01 || valid.support != from.support {
                    let me = states[i].actor
                    var leg: StageLeg
                    if !me.canMove || policy.isCalm {
                        leg = StageLeg(
                            at: 0, duration: StageDirector.settle, path: [from.position, valid.position], gait: .fade,
                            kind: .settle, facingFrom: from.facing, facingTo: from.facing, support: valid.support)
                    } else {
                        // Facing the way it goes, like any move.
                        leg = makeLeg(i, to: valid, start: 0, kind: .settle)
                        if leg.duration < StageDirector.settle, leg.rate == 1 || leg.gait == .fly { leg.duration = StageDirector.settle }
                    }
                    leg.stays = hovers(i, at: valid) && leg.gait == .fly && leg.move != nil
                    states[i].legs.append(leg)
                    states[i].busyUntil = leg.end
                    states[i].home.facing = leg.facingTo
                } else if hovers(i, at: valid), let fly = flyingMove(i) {
                    // Placed in the air: its wings going from the start.
                    states[i].legs.append(StageLeg(
                        at: 0, duration: 0, path: [valid.position], gait: .fly, kind: .settle, move: fly, stays: true,
                        facingFrom: valid.facing, facingTo: valid.facing, support: valid.support))
                }
                states[i].pose = states[i].home
            }
        }

        /// Where a child's sticker is, by its feet on the art, and where it
        /// can be.
        /// A child's sticker that its depth puts mostly behind a plane in
        /// front (a tree's trunk) steps out to the nearest spot where it
        /// shows.
        func outFromBehind(_ i: Int, _ pose: StagePose) -> StagePose {
            guard case .ground = pose.support, hidden(i, at: pose.position) > 0.3 else { return pose }
            let belongs = self.belongs(i, way(i).move)
            guard let spot = world.nearestStand(to: pose.position.ground, belongsIn: belongs, accept: {
                hidden(i, at: $0.onGround) < 0.15 && onScreen(i, at: $0.onGround)
            }) else { return pose }
            return StagePose(position: spot.onGround, support: .ground, facing: pose.facing)
        }

        func placedPose(_ i: Int, _ feet: SceneSpace.Point) -> (StagePose, StagePose) {
            let me = states[i].actor
            let space = world.space
            let belongs = self.belongs(i, way(i).move)
            let facing = me.facing
            let accept = { (g: Vec2) in onScreen(i, at: g.onGround) }
            if space.isGround(artY: feet.v) {
                let g = world.groundPoint(feet)
                let here = StagePose(position: g.onGround, support: .ground, facing: facing)
                if world.canStand(at: g, belongsIn: belongs) { return (here, here) }
                let land = world.nearestStand(to: g, belongsIn: belongs, accept: accept) ?? g
                return (here, StagePose(position: land.onGround, support: .ground, facing: facing))
            }
            // Up off the ground: on the branch it is at, in the air it
            // flies in, else down to the ground.
            if let perch = nearestPerch(i, to: feet, within: 0.08) { return (perch, perch) }
            let flies = way(i).flies || me.moves.contains { $0.flies }
            if flies, let air = world.airs.first(where: { SceneSpace.contains($0.area, feet) }) ?? world.airs.first {
                let p = world.point(feet, atDepth: (air.near + air.far) / 2)
                let pose = StagePose(position: p, support: .air(air.place), facing: facing)
                return (pose, pose)
            }
            let z = space.stand.far
            let up = world.point(feet, atDepth: z)
            let below = Vec2(up.x, z)
            let land = world.nearestStand(to: below, belongsIn: belongs, reach: 4, accept: accept) ?? below
            return (StagePose(position: up, support: .air(""), facing: facing),
                    StagePose(position: land.onGround, support: .ground, facing: facing))
        }

        /// The perch spot nearest an art point, if one is within `within`
        /// (art fractions).
        func nearestPerch(_ i: Int, to feet: SceneSpace.Point, within: Double) -> StagePose? {
            var best: (d: Double, pose: StagePose)?
            for perch in world.perches {
                let art = perch.points.map(world.project)
                let d = SceneSpace.distance(feet, toPolyline: art)
                guard d <= within, d < (best?.d ?? .infinity) else { continue }
                // The nearest point of the line, in space.
                var nearest = perch.points[0], nd = Double.infinity
                for k in 0...20 {
                    let p = StagePlan.along(perch.points, Double(k) / 20)
                    let pd = hypot(world.project(p).u - feet.u, world.project(p).v - feet.v)
                    if pd < nd { (nearest, nd) = (p, pd) }
                }
                best = (d, perchPose(i, perch, at: nearest))
            }
            return best?.pose
        }

        /// A sticker on a perch at `p`: feet on a branch; on bark, its front
        /// on it, facing it.
        func perchPose(_ i: Int, _ perch: StageWorld.Perch, at p: Vec3) -> StagePose {
            let me = states[i].actor
            var position = Vec3(p.x, p.y, perch.depth - StageDirector.inFront)
            var facing = states[i].pose.facing
            if let face = perch.facing {
                // Its centre behind the bark by its reach; its centre at the
                // line's height.
                position.x += (face == .left ? 1 : -1) * me.front * me.width
                position.y -= me.size / 2
                if let sign = sign(face, for: i) { facing = sign }
            }
            return StagePose(position: position, support: .perch(perch.place), facing: facing)
        }

        /// Which way it faces (+1 / −1) to face `face`, from the way its
        /// usual move travels.
        func sign(_ face: StageMove.Facing, for i: Int) -> Double? {
            guard let art = states[i].actor.moves.first?.facing else { return nil }
            return art == face ? 1 : -1
        }

        // MARK: Spots in places

        /// Where in a place it can be: ground inside the place (or on its
        /// shore, for one that does not belong in its water), points along
        /// its lines, points in its air.
        func spots(_ name: String, for i: Int, move: StageMove?) -> [StagePose] {
            let me = states[i].actor
            let belongs = self.belongs(i, move)
            if let ground = world.grounds.first(where: { $0.place == name }),
                let art = world.space.places[name]?.ground
            {
                let into = !ground.water || belongs.contains(name)
                let us = art.map(\.u), vs = art.map(\.v)
                let pad = into ? 0.0 : 0.08
                let lo = SceneSpace.Point((us.min() ?? 0) - pad, max((vs.min() ?? 0) - pad, 0))
                let hi = SceneSpace.Point((us.max() ?? 1) + pad, min((vs.max() ?? 1) + pad / 2, world.space.horizon - 0.01))
                var out: [StagePose] = []
                for c in 0...15 {
                    for r in 0...9 {
                        let p = SceneSpace.Point(lo.u + (hi.u - lo.u) * Double(c) / 15, lo.v + (hi.v - lo.v) * Double(r) / 9)
                        guard world.space.isGround(artY: p.v) else { continue }
                        let g = world.groundPoint(p)
                        guard world.canStand(at: g, belongsIn: belongs) else { continue }
                        if into {
                            guard ground.polygon.contains(g) else { continue }
                        } else {
                            guard !ground.polygon.contains(g), ground.polygon.distance(to: g) < me.width * 0.9 + 0.1 else { continue }
                        }
                        out.append(StagePose(position: g.onGround, support: .ground, facing: states[i].pose.facing))
                    }
                }
                return out
            }
            let perches = world.perches.filter { $0.place == name }
            if !perches.isEmpty {
                return perches.flatMap { perch in
                    (0...10).map { k in perchPose(i, perch, at: StagePlan.along(perch.points, Double(k) / 10)) }
                }
            }
            if let air = world.airs.first(where: { $0.place == name }) {
                let us = air.area.map(\.u), vs = air.area.map(\.v)
                var out: [StagePose] = []
                for c in 0...8 {
                    for r in 0...4 {
                        let p = SceneSpace.Point(
                            (us.min() ?? 0) + ((us.max() ?? 1) - (us.min() ?? 0)) * Double(c) / 8,
                            (vs.min() ?? 0) + ((vs.max() ?? 1) - (vs.min() ?? 0)) * Double(r) / 4)
                        guard SceneSpace.contains(air.area, p) else { continue }
                        // The area holds centres, near and far.
                        for depth in [air.near, (air.near + air.far) / 2, air.far] {
                            var centre = world.point(p, atDepth: depth)
                            centre.y -= me.size / 2
                            out.append(StagePose(position: centre, support: .air(name), facing: states[i].pose.facing))
                        }
                    }
                }
                return out
            }
            return []
        }

        /// The freest of `spots` on screen at `time` — farthest from the
        /// others there, a little random among the roomiest, a little
        /// nearer preferred — clear of the screen's furniture when it can.
        func choose<R: RandomNumberGenerator>(
            _ spots: [StagePose], for i: Int, at time: TimeInterval, near: Vec3?, random: inout R
        ) -> StagePose? {
            let visible = spots.filter { onScreen(i, at: $0.position) }
            guard !visible.isEmpty else { return nil }
            let me = states[i].actor
            let others = states.indices.filter { $0 != i && states[$0].visible && states[$0].hasEntered }
            func clearance(_ p: Vec3) -> Double {
                others.map { o -> Double in
                    let q = states[o].pose.position
                    let reach = (me.width + states[o].actor.width) / 2 * 0.8
                    return (p - q).length - reach
                }.min() ?? 10
            }
            let uncovered = visible.filter { !covered(i, at: $0.position) }
            let pool = uncovered.isEmpty ? visible : uncovered
            // Small characters to the front; nobody behind the trees.
            let stand = world.space.stand
            let scored = pool.map { pose -> (StagePose, Double) in
                let c = clearance(pose.position)
                let d = near.map { (pose.position - $0).length } ?? 0
                let back = min(max((pose.position.z - stand.near) / max(stand.far - stand.near, 0.01), 0), 1)
                let front = me.wantsFront
                // Seen: not behind the planes, nor behind someone, nor in
                // front of someone already there.
                return (pose, min(c, me.width * 2) - d * 0.05 - back * front * 0.35
                    - hiddenWithHeadroom(i, at: pose.position) * (me.width * 2 + 0.3 + front * 0.5)
                    - blocking(i, at: pose.position) * (me.width * 3 + 1))
            }
            let best = scored.map(\.1).max() ?? 0
            let roomy = scored.filter { $0.1 >= best - me.width * 0.3 }
            return roomy[Int.random(in: 0..<roomy.count, using: &random)].0
        }

        // MARK: Entrances

        /// A visitor comes in: onto the first place of its stage with room
        /// on screen, from the nearer side along the ground (or through the
        /// air), or growing where it stands.
        mutating func enter<R: RandomNumberGenerator>(
            _ i: Int, _ entrance: EntranceTrigger, goes: [GoTrigger], random: inout R
        ) {
            var stage = states[i].actor.stage
            let itsGoes = goes.filter { $0.stickerID == entrance.stickerID && $0.at >= entrance.at - 0.01 }
                .sorted { $0.at < $1.at }
            var arrival: (go: GoTrigger, place: String)?
            if let first = itsGoes.first, first.kind == .to, first.at - entrance.at <= StagePlanner.arrivalMove,
                let place = first.target, world.space.places[place] != nil
            {
                stage.on = [place] + stage.on.filter { $0 != place }
                arrival = (first, place)
            }
            states[i].by = entrance.by
            let move = StageMove.pick(states[i].actor.moves, by: entrance.by)
            if let move, let by = entrance.by, move.id == by, move.cycle != nil {
                stage.entrance = move.flies ? .fly : .hop
                if !move.on.isEmpty { stage.on = move.on }
            }
            var landing: StagePose?
            for place in stage.on {
                landing = choose(spots(place, for: i, move: move), for: i, at: entrance.at, near: nil, random: &random)
                if landing != nil {
                    // Come straight to the place the story sends it to its
                    // usual way: that move is made.
                    if let arrival, arrival.place == place, arrival.go.by == nil || arrival.go.by == entrance.by,
                        !arrival.go.another, arrival.go.toward == nil
                    {
                        made.insert(Director.key(arrival.go))
                    }
                    break
                }
            }
            if landing == nil {
                // Nowhere of its own: any land on screen.
                let land = world.grounds.filter { !$0.water }.map(\.place)
                for place in land {
                    landing = choose(spots(place, for: i, move: move), for: i, at: entrance.at, near: nil, random: &random)
                    if landing != nil { break }
                }
            }
            let target = landing ?? StagePose(
                position: Vec3(0, 0, (world.space.stand.near + world.space.stand.far) / 2), support: .ground)
            states[i].hasEntered = true
            states[i].home = target
            let gait: StageLeg.Gait
            var path: [Vec3]
            var duration: TimeInterval
            var moveID: String? = nil
            var facing = target.facing
            if policy.isCalm {
                gait = .fade
                path = [target.position, target.position]
                duration = StageDirector.fadeTime
            } else if stage.entrance == .grow || !states[i].actor.canMove {
                gait = .grow
                path = [target.position]
                let sprout = states[i].actor.moves.first { $0.cycle == nil && $0.seconds > 0 }
                moveID = policy.allowsLiveAnimations ? sprout?.id : nil
                duration = max(sprout?.seconds ?? 0, 0.7)
            } else {
                // From the nearer side — the other when that way would pass
                // under the story's pill.
                var side = nearerSide(target.position)
                let director = self, size = states[i].actor.size, flies = stage.entrance == .fly
                let start = { (side: Double) -> Vec3 in
                    var s = director.offstagePoint(i, side: side, at: target.position)
                    s.y = flies ? target.position.y + 0.25 * size + 0.2 : 0
                    return s
                }
                if crossesAvoid(i, from: start(side), to: target.position), !crossesAvoid(i, from: start(-side), to: target.position) {
                    side = -side
                }
                states[i].pose = StagePose(position: start(side), support: .off, facing: states[i].pose.facing)
                states[i].visible = true
                states[i].start = states[i].pose
                states[i].startsVisible = false
                if stage.entrance == .fly {
                    states[i].by = move?.flies == true ? move?.id : states[i].by
                }
                var leg = makeLeg(i, to: target, start: entrance.at, kind: .entrance, forceFly: stage.entrance == .fly)
                if leg.gait == .fly, leg.move != nil, hovers(i, at: target) { leg.stays = true }
                // Off stage it already faces the way it comes in: no turn on the way.
                leg.facingFrom = leg.facingTo
                states[i].start.facing = leg.facingTo
                states[i].legs.append(leg)
                states[i].pose = target
                states[i].busyUntil = leg.end
                states[i].pose.facing = leg.facingTo
                // Into its element by a way that stays there: it keeps going.
                if let move, move.stays, leg.move == move.id, case .ground = target.support,
                    let water = world.water(at: target.position.ground), move.on.contains(water)
                {
                    states[i].legs[states[i].legs.count - 1].stays = true
                }
                return
            }
            states[i].start = StagePose(position: target.position, support: .off, facing: facing)
            states[i].startsVisible = false
            facing = target.facing
            states[i].legs.append(StageLeg(
                at: entrance.at, duration: duration, path: path, gait: gait, kind: .entrance, move: moveID,
                facingFrom: facing, facingTo: facing, support: target.support))
            states[i].pose = target
            states[i].visible = true
            states[i].busyUntil = entrance.at + duration
        }

        func crossesAvoid(_ i: Int, from a: Vec3, to b: Vec3) -> Bool {
            guard !screen.avoid.isEmpty else { return false }
            return (0...16).contains { k in covered(i, at: a.lerp(to: b, Double(k) / 16)) }
        }

        // MARK: Moves

        mutating func apply<R: RandomNumberGenerator>(_ go: GoTrigger, to i: Int, random: inout R) {
            let begin = max(go.at, states[i].busyUntil)
            let left = leaveGroup(i)
            let wasBeside = states[i].beside
            states[i].beside = nil
            states[i].by = go.by
            let me = states[i].actor

            switch go.kind {
            case .on, .under:
                guard let name = go.target, let j = nearest(name, to: i) else { break }
                let key = "\(go.kind.rawValue):\(states[j].actor.id)"
                var members = groups[key] ?? []
                if states[i].pose.position.x < states[j].pose.position.x { members.insert(i, at: 0) } else { members.append(i) }
                groups[key] = members
                relayout(key, start: begin, mover: i)
            case .to:
                guard let name = go.target else { break }
                if world.space.places[name] != nil, !states.contains(where: { $0.actor.stickerID == name }) {
                    goToPlace(name, i, go: go, begin: begin, random: &random)
                } else if let j = nearest(name, to: i) {
                    let key = "beside:\(states[j].actor.id)"
                    if wasBeside == key, go.toward == nil {
                        states[i].beside = key
                        break
                    }
                    let spot = besideSpot(i, j, toward: go.toward)
                    states[i].beside = key
                    goWalking(i, to: spot, begin: begin)
                }
            case .away:
                let side = go.toward.map { $0 == .right ? 1.0 : -1.0 } ?? nearerSide(states[i].pose.position)
                var out = offstagePoint(i, side: side, at: states[i].pose.position)
                if !way(i).flies { out.y = 0 }
                states[i].leftBy = side
                travel(i, to: StagePose(position: out, support: .off, facing: states[i].pose.facing), begin: begin)
            case .back:
                if !states[i].visible {
                    states[i].pose.position = offstagePoint(i, side: states[i].leftBy, at: states[i].home.position)
                    if !way(i).flies { states[i].pose.position.y = 0 }
                    states[i].visible = true
                }
                goWalking(i, to: states[i].home, begin: begin)
            }
            if let left, left != groupKey(of: i) { relayout(left, start: begin, mover: nil) }
            _ = me
        }

        /// To a place: in it for one that belongs there, on its shore for
        /// one that does not belong in its water; on its lines; in its air.
        mutating func goToPlace<R: RandomNumberGenerator>(_ name: String, _ i: Int, go: GoTrigger, begin: TimeInterval, random: inout R) {
            let move = way(i).move
            let here = states[i].pose
            // There already: it stays (or, asked for another part of it,
            // goes on to one).
            var spots = spots(name, for: i, move: move)
            let threshold = states[i].actor.width * 0.6
            let atPlace = isAt(name, i)
            if atPlace, !go.another {
                // A story sending it to the bark it is at: the next tree.
                let facingPlace = world.perches.contains { $0.place == name && $0.facing != nil }
                if !facingPlace || go.unlessThere { return }
            }
            if atPlace || go.another {
                // Another part of it on screen; none: it stays where it is.
                let elsewhere = spots.filter {
                    ($0.position - here.position).length > max(threshold, 0.3) && onScreen(i, at: $0.position)
                }
                if elsewhere.isEmpty { return }
                spots = elsewhere
            }
            if let toward = go.toward {
                let x = here.position.x + (toward == .right ? 1 : -1) * states[i].actor.width
                let side = spots.filter { toward == .right ? $0.position.x >= x : $0.position.x <= x }
                if !side.isEmpty {
                    spots = side
                } else if let far = (toward == .right ? spots.max { $0.position.x < $1.position.x }
                                                     : spots.min { $0.position.x < $1.position.x }) {
                    spots = [far]
                }
            }
            // A place it faces into (bark): the nearest spot. Elsewhere: the
            // freest, a little nearer preferred.
            let facing = world.perches.contains { $0.place == name && $0.facing != nil }
            let chosen: StagePose?
            if facing {
                chosen = spots.filter { onScreen(i, at: $0.position) }.min {
                    ($0.position - here.position).length < ($1.position - here.position).length
                } ?? spots.first
            } else {
                chosen = choose(spots, for: i, at: begin, near: here.position, random: &random)
            }
            guard let target = chosen else { return }
            goWalking(i, to: target, begin: begin, stays: move?.stays == true && move?.on.contains(name) == true)
        }

        func isAt(_ name: String, _ i: Int) -> Bool {
            let pose = states[i].pose
            switch pose.support {
            case .perch(let place), .air(let place): return place == name
            case .ground:
                guard let ground = world.grounds.first(where: { $0.place == name }) else { return false }
                let g = pose.position.ground
                if ground.polygon.contains(g) {
                    // In it: where it belongs, or where it went for the spot.
                    return !ground.water || belongs(i, way(i).move).contains(name)
                }
                // On its shore, for one that does not go in.
                return ground.water && !belongs(i, way(i).move).contains(name)
                    && ground.polygon.distance(to: g) < states[i].actor.width * 0.9 + 0.1
            default: return false
            }
        }

        /// Beside another sticker, at its depth: on the side it comes from
        /// (the other when that is taken or off screen), a little
        /// overlapping; a flyer hovers by it; a walker by someone up a tree
        /// or in water it does not belong in stands on the nearest land.
        func besideSpot(_ i: Int, _ j: Int, toward: GoTrigger.Side?) -> StagePose {
            let me = states[i].actor, them = states[j].actor
            let t = states[j].pose.position
            let key = "beside:\(them.id)"
            let xs = states.indices.filter { $0 != i && states[$0].beside == key }.map { states[$0].pose.position.x - t.x }
            let onSide = { (side: Double) in xs.filter { $0 * side > 0 }.count }
            var side: Double = states[i].pose.position.x <= t.x ? -1 : 1
            if onSide(side) > onSide(-side) { side = -side }
            let spacing = (them.width / 2 + me.width / 2) * 0.72
            let room = { (side: Double) -> Bool in
                onScreen(i, at: Vec3(t.x + side * spacing, 0, t.z))
            }
            if !room(side), room(-side) { side = -side }
            let z = max(t.z - StageDirector.inFront, 0.1)
            let spotX = { (side: Double, out: Double) -> Double in
                t.x + side * spacing * (out + 0.85 * Double(onSide(side) / 2 * 2) / 2)
            }
            if let toward { side = toward == .right ? 1 : -1 }
            // Where it would stand for a spot: a flyer hovers there; a
            // walker stands on the nearest land it can, on screen.
            let flies = way(i).flies
            let belongs = self.belongs(i, way(i).move)
            func standing(_ x: Double, _ z: Double) -> Vec3 {
                if flies { return pushedOnScreen(i, Vec3(x, t.y + them.size * 0.15, z)) }
                let ground = Vec2(x, z)
                let land = world.nearestStand(to: ground, belongsIn: belongs, accept: { onScreen(i, at: $0.onGround) }) ?? ground
                return pushedOnScreen(i, land.onGround)
            }
            // Seen where it ends up: not behind a tree (the planes count
            // double — behind one it is never seen) nor behind or in front
            // of someone else. Else the other side, or a step further out,
            // or nearer — out from under a tree's low branches.
            let seen = { (p: Vec3) in hidden(i, at: p) * 2 + blocking(i, at: p, except: [j]) }
            var spot = standing(spotX(side, 1), z)
            var behind = seen(spot)
            if behind > 0.2 {
                let near = world.space.stand.near
                var tries: [(Double, Double, Double)] = []
                for dz in [0, 0.4, 0.8] where dz == 0 || z - dz >= near {
                    for (s, out) in [(side, 1.0), (side, 1.6), (-side, 1), (-side, 1.6), (side, 2.4), (-side, 2.4)]
                    where dz > 0 || out != 1 || s != side {
                        tries.append((s, out, z - dz))
                    }
                }
                for (s, out, depth) in tries where toward == nil || s == side {
                    let other = standing(spotX(s, out), depth)
                    guard onScreen(i, at: other) else { continue }
                    let h = seen(other)
                    if h < behind - 0.15 { (spot, behind) = (other, h) }
                }
            }
            return StagePose(position: spot, support: .beside(them.id), facing: states[i].pose.facing)
        }

        /// The instance of `name` nearest to it on the stage.
        func nearest(_ name: String, to i: Int) -> Int? {
            states.indices.filter { $0 != i && states[$0].actor.stickerID == name && states[$0].visible && states[$0].hasEntered }
                .min { (states[$0].pose.position - states[i].pose.position).length < (states[$1].pose.position - states[i].pose.position).length }
        }

        func groupKey(of i: Int) -> String? { groups.first { $0.value.contains(i) }?.key }

        mutating func leaveGroup(_ i: Int) -> String? {
            guard let key = groupKey(of: i) else { return nil }
            groups[key]?.removeAll { $0 == i }
            return key
        }

        /// Everyone on (or under) a sticker in one row centred on it, each
        /// overlapping the next by a quarter of the narrower: the newcomer
        /// goes there, the others shuffle over to make room or close up.
        mutating func relayout(_ key: String, start: TimeInterval, mover: Int?) {
            guard let members = groups[key], !members.isEmpty,
                let id = UUID(uuidString: String(key.split(separator: ":")[1])),
                let j = states.firstIndex(where: { $0.actor.id == id })
            else { return }
            let on = key.hasPrefix("on:")
            let t = states[j].pose.position
            let them = states[j].actor
            let widths = members.map { states[$0].actor.width }
            var total = widths.reduce(0, +)
            for (a, b) in zip(widths, widths.dropFirst()) { total -= min(a, b) * StageDirector.sharedOverlap }
            let y = on ? t.y + them.size * 0.8 : t.y
            let z = max(t.z - StageDirector.inFront * (on ? 1 : 2), 0.1)
            func centres(_ shift: Double) -> [Double] {
                var x = t.x - total / 2 + shift
                return widths.enumerated().map { k, w in
                    defer { x += w - (k + 1 < widths.count ? min(w, widths[k + 1]) * StageDirector.sharedOverlap : 0) }
                    return x + w / 2
                }
            }
            // Along its back (or before it) out from behind a tree, when
            // the row would be hidden there.
            func hiddenRow(_ shift: Double) -> Double {
                zip(members, centres(shift)).map { hidden($0, at: pushedOnScreen($0, Vec3($1, y, z))) }.reduce(0, +)
            }
            var shift = 0.0
            for candidate in [-0.25, 0.25, -0.5, 0.5].map({ $0 * them.width }) where hiddenRow(candidate) < hiddenRow(shift) - 0.05 {
                shift = candidate
            }
            let row = centres(shift)
            for (k, m) in members.enumerated() {
                let centre = row[k]
                let target = StagePose(
                    position: pushedOnScreen(m, Vec3(centre, y, z)),
                    support: on ? .on(them.id) : .under(them.id), facing: states[m].pose.facing)
                if m == mover {
                    goWalking(m, to: target, begin: start)
                } else if (target.position - states[m].pose.position).length > 0.01 {
                    travel(m, to: target, begin: max(start, states[m].busyUntil), kind: .shuffle)
                }
            }
        }

        /// Goes to `target` its way — through the water ways' rules: a way
        /// that belongs to the water only takes it about in it, walking the
        /// rest; a sticker that only gets about in water stays in it.
        mutating func goWalking(_ i: Int, to target: StagePose, begin: TimeInterval, stays: Bool = false) {
            var target = target
            var begin = begin
            let flies = way(i).flies
            let element = (way(i).move?.on ?? []).filter { name in world.grounds.contains { $0.place == name && $0.water } }
            if !element.isEmpty, !flies {
                let world = self.world
                let waterAt = { (p: Vec3) -> String? in world.water(at: p.ground).flatMap { element.contains($0) ? $0 : nil } }
                let intoElement = waterAt(target.position) != nil
                let inElement = waterAt(states[i].pose.position) != nil
                if !intoElement {
                    if onlyGetsAboutInWater(i) {
                        if let water = world.nearestStand(to: target.position.ground, belongsIn: Set(element), reach: 4, accept: {
                            world.water(at: $0) != nil && onScreen(i, at: $0.onGround)
                        }) {
                            target.position = water.onGround
                        }
                    } else {
                        if inElement, let exit = shore(of: element, near: target.position.ground, from: states[i].pose.position.ground) {
                            // Out of the water its water way, then on foot.
                            travel(i, to: StagePose(position: exit.onGround, support: .ground, facing: states[i].pose.facing), begin: begin)
                            begin = max(begin, states[i].busyUntil)
                        }
                        states[i].by = nil
                    }
                } else if !inElement, !onlyGetsAboutInWater(i),
                    let entry = shore(of: element, near: states[i].pose.position.ground, from: target.position.ground)
                {
                    // Into the water from the land: to its edge its usual way
                    // first, then in.
                    let by = states[i].by
                    states[i].by = nil
                    travel(i, to: StagePose(position: entry.onGround, support: .ground, facing: states[i].pose.facing), begin: begin)
                    begin = max(begin, states[i].busyUntil)
                    states[i].by = by
                }
            }
            travel(i, to: target, begin: begin, stays: stays)
        }

        /// The point of the water's edge nearest `near` (a little on the
        /// land side), heading for `from`.
        func shore(of element: [String], near p: Vec2, from q: Vec2) -> Vec2? {
            let polygons = world.grounds.filter { element.contains($0.place) }.map(\.polygon)
            var best: (Vec2, Double)?
            for polygon in polygons {
                for (k, a) in polygon.points.enumerated() {
                    let b = polygon.points[(k + 1) % polygon.points.count]
                    for s in 0...8 {
                        let e = a + (b - a) * (Double(s) / 8)
                        let d = e.distance(to: p) + 0.3 * e.distance(to: q)
                        if d < (best?.1 ?? .infinity) { best = (e, d) }
                    }
                }
            }
            return best?.0
        }

        /// Adds the leg that takes it to `target` and moves it there.
        mutating func travel(
            _ i: Int, to target: StagePose, begin: TimeInterval, kind: StageLeg.Kind = .move, stays: Bool = false
        ) {
            let from = states[i].pose
            let turns = target.facing != from.facing
            guard (target.position - from.position).length > 0.005 || target.support != from.support || turns
                || states[i].visible != (target.support != .off)
            else { return }
            var leg = makeLeg(i, to: target, start: begin, kind: kind)
            let hovering = leg.gait == .fly && hovers(i, at: target)
            leg.stays = (stays || hovering) && leg.gait != .fade && leg.move != nil
            states[i].legs.append(leg)
            states[i].pose = target
            states[i].pose.facing = leg.facingTo
            states[i].visible = target.support != .off
            states[i].busyUntil = leg.end
        }

        /// The leg from where it is to `target`: the path (round the water
        /// and roots on foot, straight through the air), its gait and its
        /// time from the distance and the way it gets about.
        func makeLeg(_ i: Int, to target: StagePose, start: TimeInterval, kind: StageLeg.Kind, forceFly: Bool = false) -> StageLeg {
            let me = states[i].actor
            let from = states[i].pose.position
            let (move, wayFlies) = way(i)
            let flies = forceFly || wayFlies
            let belongs = self.belongs(i, move)
            var path: [Vec3]
            if policy.isCalm {
                path = [from, target.position]
            } else if kind == .shuffle, from.y > 0.01 || target.position.y > 0.01 {
                // Shuffling over in a row on someone's back: along it, not
                // down to the ground and up again.
                path = [from, target.position]
            } else if flies {
                // Up through the air and down: an arc over whatever lies
                // between (never skimming the pond).
                let span = (target.position - from).length
                var top = from.lerp(to: target.position, 0.5)
                top.y = max(from.y, target.position.y) + min(max(span * 0.25, me.size * 0.5), 1.2)
                path = span < me.size * 0.3 ? [from, target.position] : [from, top, target.position]
            } else {
                // Standing where it cannot (a child's sticker in the pond):
                // out to the nearest land first, then on round.
                var start = from.ground
                var lead: [Vec2] = []
                if !world.canStand(at: start, belongsIn: belongs), !offstage(start),
                    let land = world.nearestStand(to: start, belongsIn: belongs)
                {
                    lead = [start]
                    start = land
                }
                let bounds = groundBounds(start, target.position.ground)
                let ground = GroundPaths.path(
                    from: start, to: target.position.ground,
                    walkable: { [world] p in world.canPass(at: p, belongsIn: belongs) },
                    crosses: { [world] p, q in world.crossesBlocked(from: p, to: q, belongsIn: belongs) }, bounds: bounds)
                path = (lead + ground).map(\.onGround)
                if from.y > 0.01 { path.insert(from, at: 0) }
                if target.position.y > 0.01 { path.append(target.position) }
            }
            let length = zip(path, path.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0).length }
            let widths = length / max(me.width, 0.01)
            let shuffle = kind == .shuffle
            var gait: StageLeg.Gait
            var duration: TimeInterval
            var rate = 1.0
            var moveID = move?.id
            if policy.isCalm {
                gait = .fade
                duration = StageDirector.fadeTime
                moveID = nil
            } else if flies {
                gait = .fly
                duration = min(max(widths * 0.3 + 0.6, shuffle ? 0.6 : 1.2), 3.4)
                if !(move?.flies ?? false) { moveID = me.moves.first { $0.flies }?.id ?? move?.id }
            } else if let move, let cycle = move.cycle, cycle > 0, move.stride > 0, policy.allowsLiveAnimations {
                // As long as its steps take to cover the way, the frames a
                // little faster or slower to keep it near the usual times;
                // its feet always keep pace with the ground.
                let speed = move.stride * me.width / cycle
                let natural = length / max(speed, 0.01)
                duration = min(max(natural, shuffle ? 0.5 : StageDirector.minTravel), StageDirector.maxTravel)
                if natural > 0 {
                    // A long way for short legs (a caterpillar across the
                    // meadow) hurries, but never keeps the story waiting.
                    rate = min(max(natural / duration, StageDirector.rates.lowerBound), StageDirector.rates.upperBound)
                    duration = min(natural / rate, StageDirector.maxTravel)
                }
                gait = move.hops ? .hops(cycle: cycle / rate) : .walk
            } else {
                gait = .bounce
                duration = min(max(widths * 0.35, shuffle ? 0.5 : StageDirector.minTravel), 3.2)
                moveID = nil
            }
            if !policy.allowsLiveAnimations { moveID = nil }
            // Facing the way it goes, all the way: turning round where its
            // way doubles back across the screen.
            var facing = states[i].pose.facing
            var ways: [StageLeg.Way] = []
            let travels = StageMove.pick(me.moves, by: moveID).flatMap(\.facing) ?? me.moves.first?.facing
            if gait != .fade, let travels {
                let widthPoints = world.drawnHeight(size: me.size, atDepth: from.z) * me.ratio
                ways = self.ways(along: path, art: travels == .right ? 1 : -1, width: widthPoints, shuffle: shuffle)
                if let last = ways.last { facing = last.facing }
                if ways.count < 2 { ways = [] }
            }
            // Onto bark: it flies there facing its way, and turns to it as
            // it gets there.
            if case .perch(let place) = target.support,
                let perch = world.perches.first(where: { $0.place == place && $0.facing != nil }),
                let face = perch.facing, let sign = sign(face, for: i)
            {
                if ways.isEmpty, sign != facing { ways = [StageLeg.Way(k: 0, facing: facing)] }
                facing = sign
            }
            var leg = StageLeg(
                at: start, duration: duration, path: path, gait: gait, kind: kind, move: moveID,
                facingFrom: states[i].pose.facing, facingTo: facing, support: target.support, rate: rate)
            leg.ways = ways
            return leg
        }

        /// The way a sticker whose art looks `art` (1 right, −1 left)
        /// faces along a path, run by run across the screen: from where
        /// each run starts (a fraction of the path's length), facing the
        /// way it goes. Runs too short to show (a wiggle round a corner,
        /// less than a fifth of its `width` — a tenth for the whole way;
        /// a quarter for a shuffle, which can sidestep) keep the way before.
        /// Empty when nothing goes far enough across to turn for.
        func ways(along path: [Vec3], art: Double, width: Double, shuffle: Bool) -> [StageLeg.Way] {
            guard path.count > 1 else { return [] }
            let xs = path.map { world.screen($0).x }
            let lengths = zip(path, path.dropFirst()).map { ($1 - $0).length }
            let total = max(lengths.reduce(0, +), 1e-9)
            // Runs of segments going the same way across.
            var runs: [(k: Double, dx: Double)] = []
            var done = 0.0
            for j in lengths.indices {
                let dx = xs[j + 1] - xs[j]
                if let last = runs.last, (last.dx < 0) == (dx < 0) || abs(dx) < 1e-9 {
                    runs[runs.count - 1].dx += dx
                } else {
                    runs.append((done / total, dx))
                }
                done += lengths[j]
            }
            let least = width * (shuffle ? 0.25 : runs.count == 1 ? 0.1 : 0.2)
            var ways: [StageLeg.Way] = []
            for run in runs where abs(run.dx) > least {
                let facing = (run.dx > 0) == (art > 0) ? 1.0 : -1.0
                if ways.last?.facing != facing { ways.append(StageLeg.Way(k: ways.isEmpty ? 0 : run.k, facing: facing)) }
            }
            return ways
        }

        func groundBounds(_ a: Vec2, _ b: Vec2) -> (min: Vec2, max: Vec2) {
            var lo = Vec2(min(a.x, b.x), min(a.z, b.z)), hi = Vec2(max(a.x, b.x), max(a.z, b.z))
            for g in world.grounds {
                let bb = g.polygon.bounds
                lo = Vec2(min(lo.x, bb.min.x), min(lo.z, bb.min.z))
                hi = Vec2(max(hi.x, bb.max.x), max(hi.z, bb.max.z))
            }
            return (Vec2(lo.x - 0.5, max(lo.z - 0.2, 0.3)), Vec2(hi.x + 0.5, hi.z + 0.2))
        }
    }
}

/// A small seeded generator (SplitMix64): the director's first run, which
/// only finds where the cast goes, is the same every time.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
