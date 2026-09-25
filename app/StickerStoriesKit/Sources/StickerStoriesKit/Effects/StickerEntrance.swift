import Foundation

/// The moment a story first names a sticker (`{fox:enter}` in the
/// authoring text): if the child has not placed that sticker, it comes
/// into the scene there, the way its manifest stage says
/// (`docs/effects.md`, "Entrances").
public struct EntranceTrigger: Equatable, Sendable {
    public var at: TimeInterval
    /// Optional authoring label (the word it fires on); never interpreted.
    public var cue: String?
    public var stickerID: String
    /// The move it comes in by (`{ladybug:enter by fly}`), one of the
    /// sticker's moves; nil for its usual one.
    public var by: String?

    public init(at: TimeInterval, cue: String? = nil, stickerID: String, by: String? = nil) {
        self.at = at
        self.cue = cue
        self.stickerID = stickerID
        self.by = by
    }
}

/// A point or a rectangle in the scene's world points (SpriteKit
/// convention: origin bottom-left, y up).
public struct StagePoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct StageRect: Equatable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public var midX: Double { (minX + maxX) / 2 }
    public var midY: Double { (minY + maxY) / 2 }
}

/// A sticker's rendered width and height, in world points.
public struct StageSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Something already standing in the scene that a newcomer should not land
/// on: a centre and a radius, in world points.
public struct StageObstacle: Equatable, Sendable {
    public var center: StagePoint
    public var radius: Double

    public init(center: StagePoint, radius: Double) {
        self.center = center
        self.radius = radius
    }
}

/// How one visiting sticker comes in: where it lands, where it starts
/// from (relative to where it lands) and how, and when. Pure: the delta at
/// any time is a function of the time alone, so a seek or a dropped frame
/// never leaves a sticker half in.
public struct EntrancePlan: Equatable, Sendable {
    /// What the sticker does on the way in. `fade` is what hops and flights
    /// become under Reduce Motion or calm mode: it simply appears. `sprout`
    /// is `grow` for a sticker whose move frames grow it (a flower): it
    /// fades in where it stands and the frames do the growing.
    public enum Motion: String, Equatable, Sendable {
        case hop, fly, grow, sprout, fade
    }

    /// How a `hop` entrance carries the sticker. Without move frames it
    /// bounces along (`bounce`); with a walk cycle its frames do the
    /// walking and it slides at the pace of its legs (`walk`); with a hop
    /// cycle it slides and rises in one arc per loop of its frames (`hops`,
    /// the loop's seconds), so the leaps and the frames stay together.
    public enum Gait: Equatable, Sendable {
        case bounce
        case walk
        case hops(cycle: TimeInterval)
    }

    public var stickerID: String
    public var at: TimeInterval
    public var motion: Motion
    /// Where the sticker's centre lands, in world points.
    public var target: StagePoint
    /// Where it starts, relative to `target`, in multiples of its own
    /// rendered size with y **down** (the `EffectDelta` convention), so the
    /// path survives the world being rescaled mid-story.
    public var startOffset: (x: Double, y: Double)
    /// Its size where it starts, relative to its size where it lands: a
    /// walker coming up the meadow (away from the viewer) starts a little
    /// bigger and shrinks, one coming down starts smaller and grows.
    public var startScale: Double
    public var duration: TimeInterval
    public var gait: Gait
    /// The sticker is drawn the other way round for the whole visit: its
    /// move travels one way in its frames and it has to come in the other.
    public var mirrored: Bool
    /// The id of the move whose frames play on the way in; nil for none.
    public var move: String?

    public init(
        stickerID: String, at: TimeInterval, motion: Motion, target: StagePoint,
        startOffset: (x: Double, y: Double) = (0, 0), startScale: Double = 1, duration: TimeInterval,
        gait: Gait = .bounce, mirrored: Bool = false, move: String? = nil
    ) {
        self.stickerID = stickerID
        self.at = at
        self.motion = motion
        self.target = target
        self.startOffset = startOffset
        self.startScale = startScale
        self.duration = duration
        self.gait = gait
        self.mirrored = mirrored
        self.move = move
    }

    public static func == (a: EntrancePlan, b: EntrancePlan) -> Bool {
        a.stickerID == b.stickerID && a.at == b.at && a.motion == b.motion && a.target == b.target
            && a.startOffset.x == b.startOffset.x && a.startOffset.y == b.startOffset.y
            && a.startScale == b.startScale && a.duration == b.duration && a.gait == b.gait
            && a.mirrored == b.mirrored && a.move == b.move
    }

    /// How long the sticker travels, for its move frames: they loop this
    /// long and then settle (0 for motions that do not travel).
    public var travel: TimeInterval {
        switch motion {
        case .hop, .fly: duration
        case .grow, .sprout, .fade: 0
        }
    }

    public func isFinished(at time: TimeInterval) -> Bool { time >= at + duration }

    /// What the entrance adds to the sticker's placement at `time`: hidden
    /// before `at`, on its way in during `duration`, identity after.
    public func delta(at time: TimeInterval) -> EffectDelta {
        var delta = EffectDelta()
        guard time >= at else {
            delta.opacityMul = 0
            return delta
        }
        let p = duration > 0 ? min((time - at) / duration, 1) : 1
        guard p < 1 else { return delta }
        switch motion {
        case .hop:
            let travel: Double, bounce: Double
            switch gait {
            case .bounce:
                // Walks in at an even pace, slowing for the last step, one
                // hop per sticker width or so.
                travel = Self.easeOut(p)
                let distance = (startOffset.x * startOffset.x + startOffset.y * startOffset.y).squareRoot()
                let hops = min(max(distance.rounded(), 2), 8)
                bounce = Self.hopHeight * abs(sin(.pi * hops * p))
            case .walk:
                // The legs set the pace: an even slide, the frames settle it.
                travel = p
                bounce = 0
            case .hops(let cycle):
                travel = p
                bounce = cycle > 0 ? Self.hopHeight * abs(sin(.pi * (time - at) / cycle)) : 0
            }
            delta.offsetXSelf = startOffset.x * (1 - travel)
            delta.offsetYSelf = startOffset.y * (1 - travel) - bounce
            delta.scaleMul = startScale + (1 - startScale) * travel
            delta.anchor = .bottomCenter
        case .fly:
            // Glides in and settles, with a gentle bob and tilt that die
            // away as it arrives.
            let travel = Self.easeInOut(p)
            let fade = 1 - p
            delta.offsetXSelf = startOffset.x * (1 - travel)
            delta.offsetYSelf = startOffset.y * (1 - travel) + Self.flyBob * sin(2 * .pi * 1.5 * p) * fade
            delta.rotationAdd = Self.flyTilt * sin(2 * .pi * 1.5 * p) * fade * (startOffset.x < 0 ? 1 : -1)
            delta.scaleMul = startScale + (1 - startScale) * travel
        case .sprout:
            delta.opacityMul = min(p / 0.12, 1)
        case .grow:
            delta.opacityMul = min(p / 0.4, 1)
            delta.scaleMul = Self.growFrom + (1 - Self.growFrom) * Self.easeOutBack(p)
            delta.anchor = .bottomCenter
        case .fade:
            delta.opacityMul = p
        }
        return delta
    }

    /// Hop arc, in multiples of the sticker's height.
    static let hopHeight = 0.22
    static let flyBob = 0.12
    /// Degrees.
    static let flyTilt = 7.0
    static let growFrom = 0.2

    static func easeOut(_ p: Double) -> Double { 1 - (1 - p) * (1 - p) }
    static func easeInOut(_ p: Double) -> Double { p * p * (3 - 2 * p) }
    /// Overshoots a little before settling: a sprout popping up.
    static func easeOutBack(_ p: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(p - 1, 3) + c1 * pow(p - 1, 2)
    }
}

/// A sticker's move frames as the planner needs them (the sidecar's
/// timing, `docs/pack-format.md`, "Live animations"): a loop that carries
/// it `stride` sticker widths every `cycle` seconds, facing the way the
/// frames travel, maybe hopping or flying — or a one-shot (a sprout) of
/// `seconds`. A sticker can have more than one (the ladybug crawls and
/// flies): the first is its usual way, the others play when a story says
/// so (`{ladybug:go on flower by fly}`).
public struct StageMove: Equatable, Sendable {
    public enum Facing: String, Codable, Equatable, Sendable {
        case left, right
    }

    /// The animation's id (`fly`), which triggers name in `by`.
    public var id: String
    public var cycle: TimeInterval?
    public var stride: Double
    public var hops: Bool
    /// The loop is a flight: it glides along with a gentle bob.
    public var flies: Bool
    /// Features it comes in on when a story brings it in this way (a
    /// duckling swimming in: the pond); empty for the sticker's stage.
    public var on: [String]
    public var facing: Facing?
    public var seconds: TimeInterval

    public init(
        id: String = "", cycle: TimeInterval? = nil, stride: Double = 0, hops: Bool = false, flies: Bool = false,
        on: [String] = [], facing: Facing? = nil, seconds: TimeInterval = 0
    ) {
        self.id = id
        self.cycle = cycle
        self.stride = stride
        self.hops = hops
        self.flies = flies
        self.on = on
        self.facing = facing
        self.seconds = seconds
    }

    /// The move `by` names among a sticker's moves, or its usual one (the
    /// first) when `by` is nil or not one of them.
    public static func pick(_ moves: [StageMove]?, by: String?) -> StageMove? {
        guard let moves else { return nil }
        return by.flatMap { id in moves.first { $0.id == id } } ?? moves.first
    }

    /// Whether a sticker whose frames travel this way has to be mirrored
    /// to come in moving right (or left).
    func mirrors(travellingRight: Bool) -> Bool {
        guard let facing else { return false }
        return (facing == .right) != travellingRight
    }
}

/// Decides where the stickers a story names but the child has not placed
/// come in, and how. Pure and seeded, so it is unit-tested; the scene
/// gives it the world geometry and turns the plans into nodes.
public enum StagePlanner {
    /// The scene as the planner needs it, in world points.
    public struct Scene: Sendable {
        /// The base art's frame: the space stage areas are fractions of.
        public var world: StageRect
        /// Where a sticker's centre may be and still be seen: the visible
        /// part of the world, inset so a sticker is not cut by an edge.
        public var usable: StageRect
        /// The visible part of the world; walkers and flyers start just
        /// beyond its sides.
        public var visible: StageRect
        /// A sticker's rendered side at scale 1 (its longer side).
        public var stickerSize: Double
        /// Each sticker's rendered size at scale 1, when known; a sticker
        /// without one is a `stickerSize` square.
        public var sizes: [String: StageSize]

        public init(
            world: StageRect, usable: StageRect, visible: StageRect, stickerSize: Double,
            sizes: [String: StageSize] = [:]
        ) {
            self.world = world
            self.usable = usable
            self.visible = visible
            self.stickerSize = stickerSize
            self.sizes = sizes
        }

        func size(of stickerID: String) -> StageSize {
            sizes[stickerID] ?? StageSize(width: stickerSize, height: stickerSize)
        }
    }

    /// How much of a sticker's square counts when deciding if two overlap:
    /// the art rarely fills its square, so two can stand a little closer
    /// than their squares would say.
    public static let footprint = 0.38

    /// The plans for every entrance whose sticker is not already placed,
    /// in time order; later visitors avoid the earlier ones' spots.
    public static func plan<R: RandomNumberGenerator>(
        entrances: [EntranceTrigger], placed: Set<String>, stages: [String: StickerStage],
        features: [String: SceneFeature] = [:], moves: [String: [StageMove]] = [:], scene: Scene,
        obstacles: [StageObstacle], policy: EffectPolicy, random: inout R
    ) -> [EntrancePlan] {
        var obstacles = obstacles
        var plans: [EntrancePlan] = []
        var seen = Set<String>()
        for entrance in entrances.sorted(by: { $0.at < $1.at })
        where !placed.contains(entrance.stickerID) && seen.insert(entrance.stickerID).inserted {
            var stage = stages[entrance.stickerID] ?? .default
            let move = StageMove.pick(moves[entrance.stickerID], by: entrance.by)
            if let move, let by = entrance.by, move.id == by, move.cycle != nil {
                // Another way in than its usual one: it flies or walks in
                // that way, onto the places that way goes (a duckling
                // swimming in lands on the pond).
                stage.entrance = move.flies ? .fly : .hop
                if !move.on.isEmpty { stage.on = move.on }
            }
            let radius = scene.stickerSize * footprint
            let choices = places(for: stage, features: features, in: scene)
            // The first place in order of preference with a free spot;
            // when every one is crowded, anywhere in the first.
            var landing: (point: StagePoint, rect: StageRect)?
            for rects in choices {
                landing = freeSpot(in: rects, radius: radius, avoiding: obstacles, random: &random)
                if landing != nil { break }
            }
            let (target, rect) = landing ?? randomSpot(in: choices[0], random: &random)
            obstacles.append(StageObstacle(center: target, radius: radius))
            plans.append(
                path(
                    for: entrance, stage: stage, move: policy.allowsLiveAnimations ? move : nil,
                    target: target, area: rect, scene: scene, policy: policy, random: &random))
        }
        return plans
    }

    /// Where a sticker may land, in order of preference, in world points and
    /// kept to what the window shows: each of its features that is at least
    /// partly on screen (its visible parts), then its own area. The area
    /// always yields a place — when it is off screen on an axis the usable
    /// band stands in on that axis — and a stage with neither lands in the
    /// default area, so the list is never empty.
    static func places(for stage: StickerStage, features: [String: SceneFeature], in scene: Scene) -> [[StageRect]] {
        var out: [[StageRect]] = []
        for id in stage.on {
            let rects = (features[id]?.areas ?? []).filter(\.isValid).compactMap { visibleRect(for: $0, in: scene) }
            if !rects.isEmpty { out.append(rects) }
        }
        if let area = stage.area {
            out.append([rect(for: area, in: scene)])
        }
        if out.isEmpty {
            out.append([rect(for: StickerStage.default.area!, in: scene)])
        }
        return out
    }

    /// The part of `area` that is on screen, or nil when none of it is.
    static func visibleRect(for area: StickerStage.Area, in scene: Scene) -> StageRect? {
        let w = scene.world, width = w.maxX - w.minX, height = w.maxY - w.minY
        let r = StageRect(
            minX: max(w.minX + area.x[0] * width, scene.usable.minX), minY: max(w.minY + area.y[0] * height, scene.usable.minY),
            maxX: min(w.minX + area.x[1] * width, scene.usable.maxX), maxY: min(w.minY + area.y[1] * height, scene.usable.maxY))
        return r.minX <= r.maxX && r.minY <= r.maxY ? r : nil
    }

    /// The stage area in world points, kept to where a sticker can be seen:
    /// a window that shows only part of the art (portrait) narrows it, and
    /// when the two do not meet the usable band stands in on that axis.
    static func rect(for area: StickerStage.Area, in scene: Scene) -> StageRect {
        let area = area.isValid ? area : StickerStage.default.area!
        func span(_ fraction: [Double], _ min0: Double, _ size: Double, _ lo: Double, _ hi: Double) -> (Double, Double) {
            let a = min0 + fraction[0] * size, b = min0 + fraction[1] * size
            let from = max(a, lo), to = min(b, hi)
            return from <= to ? (from, to) : (lo, hi)
        }
        let w = scene.world
        let x = span(area.x, w.minX, w.maxX - w.minX, scene.usable.minX, scene.usable.maxX)
        let y = span(area.y, w.minY, w.maxY - w.minY, scene.usable.minY, scene.usable.maxY)
        return StageRect(minX: x.0, minY: y.0, maxX: x.1, maxY: y.1)
    }

    /// The best free spot in `rects`: the grid point farthest from anything
    /// already there (a little randomness among the roomiest so the same
    /// story does not always use the same spot), with the rect it is in;
    /// nil when nothing there is free.
    static func freeSpot<R: RandomNumberGenerator>(
        in rects: [StageRect], radius: Double, avoiding obstacles: [StageObstacle], random: inout R
    ) -> (point: StagePoint, rect: StageRect)? {
        let columns = 9, rows = 5
        var free: [(point: StagePoint, rect: StageRect, clearance: Double)] = []
        for area in rects {
            for column in 0..<columns {
                for row in 0..<rows {
                    let point = StagePoint(
                        x: area.minX + (area.maxX - area.minX) * Double(column) / Double(columns - 1),
                        y: area.minY + (area.maxY - area.minY) * Double(row) / Double(rows - 1))
                    let clearance = obstacles.map { (obstacle: StageObstacle) -> Double in
                        let dx = point.x - obstacle.center.x, dy = point.y - obstacle.center.y
                        return (dx * dx + dy * dy).squareRoot() - radius - obstacle.radius
                    }.min() ?? .infinity
                    if clearance >= 0 { free.append((point, area, clearance)) }
                }
            }
        }
        guard !free.isEmpty else { return nil }
        // Everything within a sticker's radius of the roomiest spot is as
        // good; an empty stage makes every spot as good.
        let best = free.map(\.clearance).max() ?? 0
        let roomy = free.filter { best.isInfinite || $0.clearance >= best - radius }
        let pick = roomy[Int.random(in: 0..<roomy.count, using: &random)]
        return (pick.point, pick.rect)
    }

    /// Any point in `rects` (the crowded case), each rect as likely as its
    /// size.
    static func randomSpot<R: RandomNumberGenerator>(
        in rects: [StageRect], random: inout R
    ) -> (point: StagePoint, rect: StageRect) {
        let sizes = rects.map { max(($0.maxX - $0.minX) * ($0.maxY - $0.minY), 1e-9) }
        var pick = Double.random(in: 0..<sizes.reduce(0, +), using: &random)
        var area = rects[rects.count - 1]
        for (rect, size) in zip(rects, sizes) {
            if pick < size {
                area = rect
                break
            }
            pick -= size
        }
        let point = StagePoint(
            x: Double.random(in: area.minX...area.maxX, using: &random),
            y: Double.random(in: area.minY...area.maxY, using: &random))
        return (point, area)
    }

    /// Relative size change per world height of vertical travel for a
    /// walker (going up the meadow is going away), and its limit.
    static let depthScalePerHeight = 1.2
    static let depthScaleLimit = 0.25

    /// A walker never takes longer than this to come in, however slow its
    /// legs and far its spot; nor less than `minWalk`.
    static let maxWalk: TimeInterval = 6
    static let minWalk: TimeInterval = 1.2

    static func path<R: RandomNumberGenerator>(
        for entrance: EntranceTrigger, stage: StickerStage, move: StageMove? = nil, target: StagePoint,
        area: StageRect, scene: Scene, policy: EffectPolicy, random: inout R
    ) -> EntrancePlan {
        let size = scene.size(of: entrance.stickerID)
        let width = max(size.width, 1), height = max(size.height, 1)
        let fromLeft = target.x < scene.visible.midX
        // Just out of sight, even at the bigger start size of a walker.
        let startX = fromLeft
            ? scene.visible.minX - width * (0.5 + depthScaleLimit) : scene.visible.maxX + width * (0.5 + depthScaleLimit)
        let dxSelf = (startX - target.x) / width
        switch (stage.entrance, policy.isCalm) {
        case (.hop, false):
            // From somewhere else on the same ground, so it walks up or
            // down the meadow as well as across.
            let startY = Double.random(in: area.minY...area.maxY, using: &random)
            let height = max(scene.world.maxY - scene.world.minY, 1)
            let depth = min(max((target.y - startY) / height * depthScalePerHeight, -depthScaleLimit), depthScaleLimit)
            let offset = (x: dxSelf, y: -(startY - target.y) / height)
            let distance = (offset.x * offset.x + offset.y * offset.y).squareRoot()
            if let move, let cycle = move.cycle, cycle > 0, move.stride > 0 {
                // At the pace of its legs: stride widths per loop.
                let duration = min(max(distance / (move.stride / cycle), minWalk), maxWalk)
                return EntrancePlan(
                    stickerID: entrance.stickerID, at: entrance.at, motion: .hop, target: target,
                    startOffset: offset, startScale: 1 + depth, duration: duration,
                    gait: move.hops ? .hops(cycle: cycle) : .walk, mirrored: move.mirrors(travellingRight: fromLeft),
                    move: move.id)
            }
            return EntrancePlan(
                stickerID: entrance.stickerID, at: entrance.at, motion: .hop, target: target,
                startOffset: offset, startScale: 1 + depth, duration: min(max(distance * 0.3, 1.2), 3.2))
        case (.fly, false):
            // From a little higher, gliding down to its spot.
            let startY = target.y + height * Double.random(in: 0.3...0.8, using: &random)
            let offset = (x: dxSelf, y: -(startY - target.y) / height)
            let distance = (offset.x * offset.x + offset.y * offset.y).squareRoot()
            return EntrancePlan(
                stickerID: entrance.stickerID, at: entrance.at, motion: .fly, target: target,
                startOffset: offset, duration: min(max(distance * 0.3, 1.6), 3.4),
                mirrored: move?.mirrors(travellingRight: fromLeft) ?? false, move: move?.id)
        case (.grow, false):
            if let move, move.cycle == nil, move.seconds > 0 {
                return EntrancePlan(
                    stickerID: entrance.stickerID, at: entrance.at, motion: .sprout, target: target,
                    duration: min(max(move.seconds, 0.6), 3), move: move.id)
            }
            return EntrancePlan(stickerID: entrance.stickerID, at: entrance.at, motion: .grow, target: target, duration: 0.8)
        case (_, true):
            return EntrancePlan(stickerID: entrance.stickerID, at: entrance.at, motion: .fade, target: target, duration: 0.6)
        }
    }
}
