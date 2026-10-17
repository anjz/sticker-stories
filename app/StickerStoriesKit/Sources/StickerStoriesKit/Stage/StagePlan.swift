import Foundation

/// What holds a sticker up where it is (`docs/stage3d.md`, "Poses").
public enum StageSupport: Equatable, Sendable {
    /// Standing on the ground (or in water it belongs in).
    case ground
    /// On a line of a place: a branch, the bark of a trunk.
    case perch(String)
    /// In the open air of a place.
    case air(String)
    /// Beside another sticker.
    case beside(UUID)
    /// On top of another sticker.
    case on(UUID)
    /// Under another sticker (in front of its base).
    case under(UUID)
    /// Off the stage.
    case off
}

/// Where a sticker is: its feet in space, what holds it up, which way it
/// faces (+1 its art's own way, −1 mirrored).
public struct StagePose: Equatable, Sendable {
    public var position: Vec3
    public var support: StageSupport
    public var facing: Double

    public init(position: Vec3, support: StageSupport, facing: Double = 1) {
        self.position = position
        self.support = support
        self.facing = facing
    }
}

/// One move of a sticker through space: along `path` (its feet), over
/// `duration` seconds from `at`, the way it gets about.
public struct StageLeg: Equatable, Sendable {
    public enum Gait: Equatable, Sendable {
        /// Its move frames walk it along.
        case walk
        /// Its move frames hop it: an arc per loop of `cycle` seconds.
        case hops(cycle: TimeInterval)
        /// No move frames: it bounces along.
        case bounce
        /// It flies: a glide with a gentle bob.
        case fly
        /// It fades out where it was and in where it goes (Reduce Motion,
        /// calm mode, or something that does not move getting out of the
        /// way).
        case fade
        /// It comes in where it stands: fades in and grows from small.
        case grow
        /// It drops straight down where it is, falling ever faster, no
        /// move frames: something that does not move, put up off the
        /// ground (`StageDirector`, the cast's start).
        case drop

        /// Whether it carries the sticker along its path (it does not fade
        /// or grow where it is).
        var carries: Bool {
            switch self {
            case .fade, .grow: false
            default: true
            }
        }

        /// How far along its path it is (by length) when it is `q` of the
        /// way through its moving: a flight eases in and out, a bounce
        /// slows into its landing.
        func eased(_ q: Double) -> Double {
            switch self {
            case .fly: q * q * (3 - 2 * q)
            case .bounce: 1 - (1 - q) * (1 - q)
            case .drop: q * q
            default: q
            }
        }

        /// The inverse of `eased`.
        func uneased(_ k: Double) -> Double {
            let k = min(max(k, 0), 1)
            switch self {
            case .bounce: return 1 - (1 - k).squareRoot()
            case .drop: return k.squareRoot()
            case .fly:
                var lo = 0.0, hi = 1.0
                for _ in 0..<30 {
                    let mid = (lo + hi) / 2
                    if eased(mid) < k { lo = mid } else { hi = mid }
                }
                return (lo + hi) / 2
            default: return k
            }
        }
    }

    public enum Kind: Equatable, Sendable {
        /// A child's sticker getting to where it can be, as the story starts.
        case settle
        /// A visitor coming in.
        case entrance
        /// A move the story (or an action's place) asks for.
        case move
        /// Making room for someone sharing a spot: it keeps facing its way.
        case shuffle
    }

    public var at: TimeInterval
    public var duration: TimeInterval
    public var path: [Vec3]
    public var gait: Gait
    public var kind: Kind
    /// The move whose frames play along, if any.
    public var move: String?
    /// The time of the cue that made it (an entrance, a go; 0 for settling
    /// as the story starts): an action cued before it does not wait for
    /// it (`StageDirector.delayed`).
    public var cue: TimeInterval = 0
    /// The move played instead while it is on its way, when the way goes
    /// away from the viewer (`StageMove.away`): its back to us.
    public var away: String?
    /// The move's loop goes on once it is there (`StageMove.stays`).
    public var stays: Bool
    /// A flyer that cannot hover, left in the air: from its arrival it
    /// keeps flying a slow loop round its spot until its next leg.
    public var circling: Circling?
    public var facingFrom: Double
    public var facingTo: Double
    /// The way it faces along its path when that changes on the way (a
    /// walk round the pond that doubles back): from each point (`k`, the
    /// fraction of the path's length) on. Empty: `facingTo` all the way.
    /// It turns round on the spot at each change (`StagePlan.way`), and
    /// at the end to `facingTo` if that is not the way it went.
    public var ways: [Way] = []
    /// What holds it up once it is there.
    public var support: StageSupport
    /// How fast its move frames play (1: as drawn), so its steps keep pace
    /// with the ground it covers and it never glides.
    public var rate: Double

    public init(
        at: TimeInterval, duration: TimeInterval, path: [Vec3], gait: Gait, kind: Kind = .move,
        move: String? = nil, stays: Bool = false, facingFrom: Double = 1, facingTo: Double = 1, support: StageSupport = .ground,
        rate: Double = 1
    ) {
        self.at = at
        self.duration = duration
        self.path = path
        self.gait = gait
        self.kind = kind
        self.move = move
        self.stays = stays
        self.facingFrom = facingFrom
        self.facingTo = facingTo
        self.support = support
        self.rate = rate
    }

    public var end: TimeInterval { at + duration }

    /// A loop flown round a spot in the air (`StagePlan.lap`): out ahead
    /// the way it faces, `across` either side, and back round nearer the
    /// camera, `toward` at most (depth), turning at each end.
    public struct Circling: Equatable, Sendable {
        public var across: Double
        public var toward: Double
        /// The way across the screen its art looks: 1 right, −1 left.
        public var art: Double

        public init(across: Double, toward: Double, art: Double = 1) {
            self.across = across
            self.toward = toward
            self.art = art
        }
    }

    /// The way it faces from a point of its path on (`ways`).
    public struct Way: Equatable, Sendable {
        public var k: Double
        public var facing: Double

        public init(k: Double, facing: Double) {
            self.k = k
            self.facing = facing
        }
    }

    /// Whether its move frames play along.
    public var travels: Bool {
        switch gait {
        case .fade, .drop: false
        case .grow: move != nil
        default: true
        }
    }
}

/// A sticker's whole part in a story, in space: where it starts and every
/// leg after. Pure: what it is at any moment is a function of the time
/// alone, so a seek or a dropped frame never leaves a sticker half way.
public struct StagePlan: Equatable, Sendable {
    public var start: StagePose
    /// Whether it is on the stage before its first leg (a visitor is not).
    public var startsVisible: Bool
    public var legs: [StageLeg]
    /// Its drawing's height at depth 1 (`SceneSpace.sizes`): hops and bobs
    /// are in proportion.
    public var size: Double
    /// The depth it is drawn at among the scene's planes, when not its
    /// feet's: something that never moves, left where the child put it
    /// behind a tree, is drawn just in front of the tree, as the child saw
    /// it (every sticker is in front of the scene while the child plays).
    public var drawnAt: Double?

    public init(start: StagePose, startsVisible: Bool = true, legs: [StageLeg] = [], size: Double, drawnAt: Double? = nil) {
        self.start = start
        self.startsVisible = startsVisible
        self.legs = legs.sorted { $0.at < $1.at }
        self.size = size
        self.drawnAt = drawnAt
    }

    /// Where it is at a moment, and how it shows.
    public struct Sample: Equatable, Sendable {
        public var position: Vec3
        public var facing: Double
        public var opacity: Double
        /// Grows in from small as it comes in (`Gait.grow`); 1 otherwise.
        public var growth: Double
        public var support: StageSupport
        /// When it last got where it is: at the same depth, the later one
        /// is in front.
        public var arrivedAt: TimeInterval
    }

    static let hopHeight = 0.18
    static let flyBob = 0.08
    /// A flyer resting in the air bobs gently, this much of its size, once
    /// every `hoverCycle` seconds.
    static let hoverBob = 0.04
    static let hoverCycle: TimeInterval = 1.7
    static let turn: TimeInterval = 0.25
    /// Seconds a circling flyer takes round its loop, and to swing out
    /// into it once it gets there.
    static let lapTime: TimeInterval = 5
    static let lapIn: TimeInterval = 1.2

    public func sample(at time: TimeInterval) -> Sample {
        guard let index = legs.lastIndex(where: { $0.at <= time }) else {
            return Sample(
                position: start.position, facing: start.facing, opacity: startsVisible ? 1 : 0, growth: 1,
                support: start.support, arrivedAt: 0)
        }
        let leg = legs[index]
        // Off a loop it was flying round its spot (below).
        let lapBefore = index > 0 ? lap(before: index) : nil
        let p = leg.duration > 0 ? min(max((time - leg.at) / leg.duration, 0), 1) : 1
        // How far along its way it is, and the way it faces: it turns
        // round on the spot wherever it has to, never stepping backwards.
        let (q, wayFacing) = way(leg, at: time, from: lapBefore?.facing)
        let arrived = legs[...index].filter { $0.end <= time }.map(\.end).max() ?? 0
        var opacity = 1.0, growth = 1.0
        var position: Vec3
        switch leg.gait {
        case .fade:
            position = p < 0.5 ? leg.path.first ?? start.position : leg.path.last ?? start.position
            opacity = p < 0.5 ? 1 - p * 2 : (p - 0.5) * 2
        case .grow:
            position = leg.path.last ?? start.position
            opacity = min(p * 3, 1)
            // From small, a little past its size, and back.
            growth = p < 0.7 ? 0.2 + 0.9 * (p / 0.7) : 1.1 - 0.1 * ((p - 0.7) / 0.3)
        case .fly:
            position = Self.along(leg.path, leg.gait.eased(q))
            position.y += Self.flyBob * size * sin(2 * .pi * 1.5 * q) * (1 - q)
            if p >= 1, leg.stays, leg.circling != nil {
                // It cannot hover: round and round its spot, wings going.
                position = position + lap(leg, since: time - leg.end).offset
            } else if p >= 1, leg.stays {
                // Hovering where it got to, its wings going.
                position.y += Self.hoverBob * size * sin(2 * .pi * (time - leg.end) / Self.hoverCycle)
            }
        case .walk:
            position = Self.along(leg.path, q)
        case .drop:
            position = Self.along(leg.path, leg.gait.eased(q))
        case .hops(let cycle):
            position = Self.along(leg.path, q)
            if p < 1, cycle > 0 { position.y += Self.hopHeight * size * abs(sin(.pi * (time - leg.at) / cycle)) }
        case .bounce:
            position = Self.along(leg.path, leg.gait.eased(q))
            let hops = max(2, (GroundPaths.length(leg.path.map(\.ground)) / max(size, 0.01)).rounded())
            if q < 1 { position.y += Self.hopHeight * size * abs(sin(.pi * hops * q)) }
        }
        // Off a loop it was flying round its spot: from where it was on
        // it, easing over onto the way.
        if let lap = lapBefore {
            position = position + lap.offset * (1 - q * q * (3 - 2 * q))
        }
        // Off the stage once it is there; in view while it comes or goes.
        let off = leg.support == .off
        if p >= 1, off { opacity = 0 }
        // A visitor is not there until it comes in.
        if leg.kind == .entrance, time < leg.at { opacity = 0 }
        // Turning from its back to us (its `away` move) to the front as it
        // gets there: a quick squash through edge-on, like any turn.
        var facing = wayFacing
        if let turned = legs.first(where: { $0.away != nil && abs(time - $0.end) < Self.turn / 2 }) {
            let k = abs(time - turned.end) / (Self.turn / 2)
            let squash = Self.narrowest + (1 - Self.narrowest) * k * k * (3 - 2 * k)
            facing = (facing < 0 ? -1 : 1) * min(abs(facing), squash)
        }
        return Sample(
            position: position, facing: facing, opacity: opacity, growth: growth,
            support: p >= 1 ? leg.support : (index > 0 ? legs[index - 1].support : start.support), arrivedAt: arrived)
    }

    /// How far along its way a leg has it at `time` (0…1 of its moving,
    /// before its gait's easing), and the way it faces. Facing one way
    /// and going the other, it stops and turns round on the spot — as it
    /// sets off, wherever its way doubles back (`StageLeg.ways`) and, to
    /// face what it came to (the bark of a trunk), as it gets there —
    /// passing through a squash (never quite 0, so the art never
    /// vanishes). `from`: the way it faced as the leg began, when that is
    /// not the leg's own (it was circling).
    func way(_ leg: StageLeg, at time: TimeInterval, from: Double? = nil) -> (q: Double, facing: Double) {
        let p = leg.duration > 0 ? min(max((time - leg.at) / leg.duration, 0), 1) : 1
        if leg.circling != nil, leg.stays, time > leg.end {
            return (1, lap(leg, since: time - leg.end).facing)
        }
        let begin = from ?? leg.facingFrom
        func blend(_ a: Double, _ b: Double, _ k: Double) -> Double {
            let k = min(max(k, 0), 1)
            return Self.unsquashed(a + (b - a) * (k * k * (3 - 2 * k)))
        }
        guard leg.gait.carries else {
            // Fading or growing where it is: a turn as it begins, if any.
            guard begin != leg.facingTo else { return (p, leg.facingTo) }
            return (p, blend(begin, leg.facingTo, (time - leg.at) / Self.turn))
        }
        // Where it turns round: (where along its moving, from, to).
        var ways = leg.ways.isEmpty ? [StageLeg.Way(k: 0, facing: leg.facingTo)] : leg.ways
        if (ways[ways.count - 1].facing < 0) != (leg.facingTo < 0) { ways.append(.init(k: 1, facing: leg.facingTo)) }
        var stops: [(q: Double, from: Double, to: Double)] = []
        var was = begin
        for w in ways {
            if (w.facing < 0) != (was < 0) { stops.append((leg.gait.uneased(w.k), was, w.facing)) }
            was = w.facing
        }
        let first = ways[0].facing
        guard !stops.isEmpty, leg.duration > 0 else {
            // Its way all along; easing from a lap's turn, if it was circling.
            guard begin != first else { return (p, first) }
            return (p, blend(begin, first, (time - leg.at) / Self.turn))
        }
        // Each turn takes its time from the moving; a short leg turns quicker.
        let turn = min(Self.turn, leg.duration * 0.5 / Double(stops.count))
        let moving = leg.duration - turn * Double(stops.count)
        var left = time - leg.at, q = 0.0, facing = begin
        for stop in stops {
            let going = (stop.q - q) * moving
            if left < going { return (q + max(left, 0) / moving, facing) }
            left -= going
            q = stop.q
            if left < turn { return (q, blend(stop.from, stop.to, left / turn)) }
            left -= turn
            facing = stop.to
        }
        return (min(q + left / moving, 1), facing)
    }

    /// Never narrower than `narrowest`, so the art never vanishes.
    static func unsquashed(_ value: Double) -> Double {
        abs(value) < narrowest ? (value < 0 ? -narrowest : narrowest) : value
    }

    /// The narrowest a turning sticker is drawn (its facing's size): a
    /// turn flips through edge-on in a blink, never showing a sliver.
    public static let narrowest = 0.5

    /// Where a circling flyer is on its loop, `since` seconds after `leg`
    /// got it to its spot (from it), and the way it faces: it swings out
    /// into the loop the way it faces, and turns, through the squash, at
    /// each end — always facing the way it is going across the screen.
    func lap(_ leg: StageLeg, since: TimeInterval) -> (offset: Vec3, facing: Double) {
        guard let circling = leg.circling else { return (Vec3(0, 0, 0), leg.facingTo) }
        let look = leg.facingTo < 0 ? -1.0 : 1.0
        // The way across the screen it sets out: the way its art looks.
        let way = look * circling.art
        func offset(_ since: TimeInterval) -> Vec3 {
            let s = max(since, 0)
            let k = min(s / Self.lapIn, 1)
            let swing = k * k * (3 - 2 * k)
            let angle = 2 * .pi * s / Self.lapTime
            return Vec3(
                way * circling.across * sin(angle) * swing,
                Self.hoverBob * size * sin(2 * angle) * swing,
                -circling.toward * (1 - cos(angle)) / 2 * swing)
        }
        // Which way it is going across the screen (nearer the camera, its
        // depth moves it across too): its way out, or back.
        let spot = leg.path.last ?? Vec3(0, 0, 1)
        func across(_ o: Vec3) -> Double { (spot.x + o.x) / max(spot.z + o.z, 0.05) }
        let dt = 0.02
        let here = offset(since)
        let speed = (across(offset(since + dt)) - across(here)) / dt * way
        let full = max(circling.across, 1e-6) * 2 * .pi / Self.lapTime / max(spot.z, 0.05)
        return (here, look * Self.unsquashed(min(max(speed / (full * 0.35), -1), 1)))
    }

    /// The loop it was flying round its spot as leg `index` began, if the
    /// leg before left it circling.
    func lap(before index: Int) -> (offset: Vec3, facing: Double)? {
        let before = legs[index - 1]
        guard before.stays, before.circling != nil, legs[index].at > before.end else { return nil }
        return lap(before, since: legs[index].at - before.end)
    }

    /// The point `k` (0…1) of the way along a path, by length.
    static func along(_ path: [Vec3], _ k: Double) -> Vec3 {
        guard let first = path.first else { return Vec3(0, 0, 1) }
        guard path.count > 1 else { return first }
        let lengths = zip(path, path.dropFirst()).map { ($1 - $0).length }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return path.last! }
        var remaining = min(max(k, 0), 1) * total
        for (i, l) in lengths.enumerated() {
            if remaining <= l || i == lengths.count - 1 {
                return path[i].lerp(to: path[i + 1], l > 0 ? min(remaining / l, 1) : 1)
            }
            remaining -= l
        }
        return path.last!
    }

    /// Every move whose frames the plan plays (each leg's, and the one it
    /// plays going away, `StageLeg.away`): what to load before it plays.
    public var movesPlayed: Set<String> {
        Set(legs.filter(\.travels).flatMap { [$0.move, $0.away].compactMap { $0 } })
    }

    /// The move whose frames play at `time`, if any: the latest leg's, on
    /// its way or settling (or going on, for one that stays).
    public func travel(at time: TimeInterval) -> StageTravel? {
        guard let leg = legs.last(where: { $0.at <= time }), leg.travels else { return nil }
        // Going away its `away` move; there, its own again.
        let move = time < leg.end ? leg.away ?? leg.move : leg.move
        return StageTravel(at: leg.at, duration: leg.duration, move: move, stays: leg.stays, rate: leg.rate)
    }
}

/// A move's frames on a leg (`StagePlan.travel`): from `at`, its loop for
/// `duration` seconds at `rate`, then the frames that bring it to rest —
/// or its loop on, when it `stays`.
public struct StageTravel: Equatable, Sendable {
    public var at: TimeInterval
    public var duration: TimeInterval
    public var move: String?
    public var stays: Bool
    public var rate: Double

    public init(at: TimeInterval, duration: TimeInterval, move: String?, stays: Bool, rate: Double = 1) {
        self.at = at
        self.duration = duration
        self.move = move
        self.stays = stays
        self.rate = rate
    }

    /// Whether it is still on its way at `time` (its move frames come
    /// before anything else then).
    public func isMoving(at time: TimeInterval) -> Bool { time < at + duration }

    /// The part of the move to play and how far into it, at `time`.
    public func part(at time: TimeInterval) -> (part: LivePart, elapsed: TimeInterval) {
        (.move(travel: duration * rate, stays: stays), (time - at) * rate)
    }
}
