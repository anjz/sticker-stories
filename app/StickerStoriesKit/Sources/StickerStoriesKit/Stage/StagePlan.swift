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
    /// The move's loop goes on once it is there (`StageMove.stays`).
    public var stays: Bool
    public var facingFrom: Double
    public var facingTo: Double
    /// What holds it up once it is there.
    public var support: StageSupport

    public init(
        at: TimeInterval, duration: TimeInterval, path: [Vec3], gait: Gait, kind: Kind = .move,
        move: String? = nil, stays: Bool = false, facingFrom: Double = 1, facingTo: Double = 1, support: StageSupport = .ground
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
    }

    public var end: TimeInterval { at + duration }
    /// Whether its move frames play along.
    public var travels: Bool {
        switch gait {
        case .fade: false
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

    public init(start: StagePose, startsVisible: Bool = true, legs: [StageLeg] = [], size: Double) {
        self.start = start
        self.startsVisible = startsVisible
        self.legs = legs.sorted { $0.at < $1.at }
        self.size = size
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
    static let turn: TimeInterval = 0.25

    public func sample(at time: TimeInterval) -> Sample {
        guard let index = legs.lastIndex(where: { $0.at <= time }) else {
            return Sample(
                position: start.position, facing: start.facing, opacity: startsVisible ? 1 : 0, growth: 1,
                support: start.support, arrivedAt: 0)
        }
        let leg = legs[index]
        let p = leg.duration > 0 ? min(max((time - leg.at) / leg.duration, 0), 1) : 1
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
            position = Self.along(leg.path, p * p * (3 - 2 * p))
            position.y += Self.flyBob * size * sin(2 * .pi * 1.5 * p) * (1 - p)
        case .walk:
            position = Self.along(leg.path, p)
        case .hops(let cycle):
            position = Self.along(leg.path, p)
            if p < 1, cycle > 0 { position.y += Self.hopHeight * size * abs(sin(.pi * (time - leg.at) / cycle)) }
        case .bounce:
            position = Self.along(leg.path, 1 - (1 - p) * (1 - p))
            let hops = max(2, (GroundPaths.length(leg.path.map(\.ground)) / max(size, 0.01)).rounded())
            if p < 1 { position.y += Self.hopHeight * size * abs(sin(.pi * hops * p)) }
        }
        // Off the stage once it is there; in view while it comes or goes.
        let off = leg.support == .off
        if p >= 1, off { opacity = 0 }
        // A visitor is not there until it comes in.
        if leg.kind == .entrance, time < leg.at { opacity = 0 }
        return Sample(
            position: position, facing: facing(leg, at: time), opacity: opacity, growth: growth,
            support: p >= 1 ? leg.support : (index > 0 ? legs[index - 1].support : start.support), arrivedAt: arrived)
    }

    /// The way it faces: it turns at a leg's start, passing through a
    /// squash (never quite 0, so the art never vanishes).
    func facing(_ leg: StageLeg, at time: TimeInterval) -> Double {
        guard leg.facingFrom != leg.facingTo else { return leg.facingTo }
        let p = min(max((time - leg.at) / Self.turn, 0), 1)
        let value = leg.facingFrom + (leg.facingTo - leg.facingFrom) * (p * p * (3 - 2 * p))
        return abs(value) < 0.05 ? (value < 0 ? -0.05 : 0.05) : value
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

    /// The move in progress at `time` whose frames should play (its start,
    /// how long it travels, which move, whether its loop stays on), if any.
    public func travel(at time: TimeInterval) -> (at: TimeInterval, duration: TimeInterval, move: String?, stays: Bool)? {
        guard let leg = legs.last(where: { $0.at <= time }), leg.travels else { return nil }
        return (leg.at, leg.duration, leg.move, leg.stays)
    }
}
