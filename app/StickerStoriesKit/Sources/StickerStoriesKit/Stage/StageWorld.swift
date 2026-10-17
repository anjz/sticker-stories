import Foundation

/// What the window shows of the stage, in world points (the base art's
/// frame, origin bottom-left): the visible part of the art, the part of it
/// the device leaves clear (a phone's camera cutout, the home indicator),
/// and screen furniture to keep stickers out from under (the story's pill).
/// A window narrower than the art plays the story on all of it across and
/// shows `window` of it at a time, following the story (`StoryCamera`).
public struct StageScreen: Sendable {
    public var visible: StageRect
    public var clear: StageRect
    public var avoid: [StageRect]
    /// How much across the window shows when it is narrower than the
    /// stage; nil when it shows it all.
    public var window: Double?

    public init(visible: StageRect, clear: StageRect? = nil, avoid: [StageRect] = [], window: Double? = nil) {
        self.visible = visible
        self.clear = clear ?? visible
        self.avoid = avoid
        self.window = window
    }
}

/// The scene's space as the director plans in it (`docs/stage3d.md`): the
/// camera, the ground's land and water, the planes' footprints, the
/// perches and the open air — on the art drawn (base or wide).
public struct StageWorld: Sendable {
    public struct Ground: Sendable {
        public var place: String
        public var polygon: GroundPolygon
        public var water: Bool
        /// Shallow, clear water: nobody floats in it.
        public var shallow = false
    }

    /// A line of a place on a layer — a branch to perch on, the bark of a
    /// trunk to face — in space, at the layer's depth.
    public struct Perch: Sendable {
        public var place: String
        public var depth: Double
        public var points: [Vec3]
        public var facing: StageMove.Facing?
    }

    public struct Air: Sendable {
        public var place: String
        /// The area, in art points (`u`, `v`).
        public var area: [SceneSpace.Point]
        public var near: Double
        public var far: Double
    }

    public let space: SceneSpace
    /// The base art's width over its height.
    public let aspect: Double
    public let wide: Bool
    /// The base art's frame in world points.
    public let frame: StageSize
    public let grounds: [Ground]
    public let footprints: [GroundPolygon]
    public let perches: [Perch]
    public let airs: [Air]
    /// What the planes in front of the background hide, each at its depth
    /// (set by whoever has their images).
    public var covers: [Cover] = []

    /// A plane's painted part: its grid over `area` of the art drawn (art
    /// points, which run past 0…1 on the wide art).
    public struct Cover: Sendable {
        public var depth: Double
        public var grid: OpaqueGrid
        public var area: StageRect

        public init(depth: Double, grid: OpaqueGrid, area: StageRect) {
            self.depth = depth
            self.grid = grid
            self.area = area
        }
    }

    public init(space: SceneSpace, aspect: Double, wide: Bool, frame: StageSize) {
        self.space = space
        self.aspect = aspect
        self.wide = wide
        self.frame = frame
        let toGround = { (p: SceneSpace.Point) in Self.groundPoint(space, aspect, p) }
        var grounds: [Ground] = []
        var perches: [Perch] = []
        var airs: [Air] = []
        for (name, place) in space.places.sorted(by: { $0.key < $1.key }) {
            if let polygon = place.ground {
                grounds.append(Ground(
                    place: name, polygon: GroundPolygon(polygon.map(toGround)), water: place.water == true,
                    shallow: place.shallow == true))
            }
            for line in (wide ? place.wideLines : nil) ?? place.lines ?? [] {
                guard let depth = space.layerDepth(line.layer, wide: wide) else { continue }
                perches.append(Perch(
                    place: name, depth: depth,
                    points: line.points.map { Self.point(space, aspect, $0, atDepth: depth) }, facing: line.facing))
            }
            if let air = place.air, air.depth.count == 2 {
                airs.append(Air(place: name, area: air.area, near: air.depth[0], far: air.depth[1]))
            }
        }
        self.grounds = grounds
        self.perches = perches
        self.airs = airs
        footprints = space.layers.compactMap { layer in
            ((wide ? layer.wide?.footprint : nil) ?? layer.footprint).map { GroundPolygon($0.map(toGround)) }
        }
    }

    // MARK: The camera

    static func groundPoint(_ space: SceneSpace, _ aspect: Double, _ p: SceneSpace.Point) -> Vec2 {
        let z = space.groundDepth(atArtY: p.v)
        return Vec2((p.u - 0.5) * aspect * z, z)
    }

    static func point(_ space: SceneSpace, _ aspect: Double, _ p: SceneSpace.Point, atDepth z: Double) -> Vec3 {
        Vec3((p.u - 0.5) * aspect * z, space.eyeHeight + (p.v - space.horizon) * z, z)
    }

    /// Where a point shows on the art (fractions of the base art).
    public func project(_ p: Vec3) -> SceneSpace.Point {
        let z = max(p.z, 0.05)
        return .init(0.5 + p.x / (aspect * z), space.horizon + (p.y - space.eyeHeight) / z)
    }

    /// Where a point shows, in world points.
    public func screen(_ p: Vec3) -> StagePoint {
        let a = project(p)
        return StagePoint(x: a.u * frame.width, y: a.v * frame.height)
    }

    /// The spot on the ground seen at art point `p`.
    public func groundPoint(_ p: SceneSpace.Point) -> Vec2 { Self.groundPoint(space, aspect, p) }

    /// The ground spot under a point of the screen (world points).
    public func groundPoint(screen p: StagePoint) -> Vec2 {
        groundPoint(.init(p.x / max(frame.width, 1), p.y / max(frame.height, 1)))
    }

    /// The point at depth `z` seen at art point `p`.
    public func point(_ p: SceneSpace.Point, atDepth z: Double) -> Vec3 { Self.point(space, aspect, p, atDepth: z) }

    /// How tall a sticker of `size` is drawn at depth `z`, in world points.
    public func drawnHeight(size: Double, atDepth z: Double) -> Double {
        space.drawnHeight(size: size, atDepth: max(z, 0.05)) * frame.height
    }

    /// The sticker's drawing on screen (world points) with its feet at `p`:
    /// `ratio` is its width over its height.
    public func drawing(at p: Vec3, size: Double, ratio: Double) -> StageRect {
        let feet = screen(p)
        let h = drawnHeight(size: size, atDepth: p.z), w = h * ratio
        return StageRect(minX: feet.x - w / 2, minY: feet.y, maxX: feet.x + w / 2, maxY: feet.y + h)
    }

    /// The depth a scene plane stands at on the art drawn.
    public func planeDepth(_ plane: String) -> Double? { space.planeDepth(plane, wide: wide) }

    /// The ground's x across the screen's clear part at depth `z`.
    public func clearX(atDepth z: Double, screen: StageScreen) -> ClosedRange<Double> {
        let lo = (screen.clear.minX / max(frame.width, 1) - 0.5) * aspect * z
        let hi = (screen.clear.maxX / max(frame.width, 1) - 0.5) * aspect * z
        return lo...max(hi, lo)
    }

    // MARK: Standing

    /// The water at `p`, if any.
    public func water(at p: Vec2) -> String? {
        grounds.first { $0.water && $0.polygon.contains(p) }?.place
    }

    /// Whether a sticker that belongs in `belongs` (places: the pond for a
    /// frog) can stand at `p`: on land, or in water it belongs in, and on
    /// no plane's footprint.
    public func canStand(at p: Vec2, belongsIn belongs: Set<String>) -> Bool {
        if footprints.contains(where: { $0.contains(p) }) { return false }
        if let water = water(at: p) { return belongs.contains(water) }
        return grounds.contains { !$0.water && $0.polygon.contains(p) }
    }

    /// Whether such a sticker can walk across `p` on its way: any ground
    /// in front of the backdrop — not only the places it may stop in — but
    /// no water it does not belong in and no plane's footprint.
    public func canPass(at p: Vec2, belongsIn belongs: Set<String>) -> Bool {
        if footprints.contains(where: { $0.contains(p) }) { return false }
        if let water = water(at: p) { return belongs.contains(water) }
        return p.z > 0.05 && p.z <= space.back
    }

    /// How deep a sticker floats at `p`, as a fraction of its drawing's
    /// height under the water: the `waterline` of its way that belongs in
    /// the water there (a duckling swimming), eased in over `ramp` from the
    /// water's edge so it sinks in as it swims in and rises as it climbs
    /// out; 0 on land, up in the air, in water it does not float in, or in
    /// shallow water (a rock pool), where it sits on the bottom, seen whole.
    public func afloat(at p: Vec3, moves: [StageMove], ramp: Double) -> Double {
        guard p.y < 0.01, let ground = grounds.first(where: { $0.water && $0.polygon.contains(p.ground) }), !ground.shallow,
            let line = moves.first(where: { $0.waterline > 0 && $0.on.contains(ground.place) })?.waterline
        else { return 0 }
        let k = min(ground.polygon.distance(to: p.ground) / max(ramp, 1e-6), 1)
        return line * k * k * (3 - 2 * k)
    }

    /// How far out into open water a sticker afloat rests or is sent: at
    /// least this share of the way out from the waterline (`outInWater`),
    /// never hugging the shore. A wave rises only that far out too.
    public static let openWater = 1.0 / 3

    /// How far out into its water `p` is, as the viewer sees it: 0 at the
    /// waterline in front, 1 at the water's far edge, up the art at that
    /// spot. Nil out of the water.
    public func outInWater(_ p: Vec2) -> Double? {
        guard let name = water(at: p), let ground = grounds.first(where: { $0.place == name }) else { return nil }
        let a = project(p.onGround)
        // The water's band up the art at this spot.
        var near = a.v, far = a.v
        let step = 0.002
        while near - step > 0, ground.polygon.contains(groundPoint(.init(a.u, near - step))) { near -= step }
        while far + step < space.horizon, ground.polygon.contains(groundPoint(.init(a.u, far + step))) { far += step }
        guard far - near > 1e-9 else { return 0 }
        return (a.v - near) / (far - near)
    }

    /// Whether `p` is out in open water (`openWater`): where a sticker
    /// afloat rests, and where a wave can rise.
    public func inOpenWater(_ p: Vec2) -> Bool {
        (outInWater(p) ?? 0) >= Self.openWater
    }

    /// Whether a walker that belongs in `belongs` crosses, going straight
    /// from `p` to `q`, water it does not belong in or a plane's footprint.
    public func crossesBlocked(from p: Vec2, to q: Vec2, belongsIn belongs: Set<String>) -> Bool {
        footprints.contains { $0.crosses(from: p, to: q) }
            || grounds.contains { $0.water && !belongs.contains($0.place) && $0.polygon.crosses(from: p, to: q) }
    }

    /// The ground place at `p` (the water first: it lies in the meadow).
    public func place(at p: Vec2) -> String? {
        water(at: p) ?? grounds.first { !$0.water && $0.polygon.contains(p) }?.place
    }

    /// The spot nearest `p` where such a sticker can stand, searched in
    /// rings round it (nearer the viewer first at each distance); nil when
    /// there is none within `reach`.
    public func nearestStand(
        to p: Vec2, belongsIn belongs: Set<String>, reach: Double = 2, accept: (Vec2) -> Bool = { _ in true }
    ) -> Vec2? {
        if canStand(at: p, belongsIn: belongs), accept(p) { return p }
        let step = 0.03
        var r = step
        while r <= reach {
            let count = max(8, Int(2 * Double.pi * r / step))
            let ring = (0..<count).map { i -> Vec2 in
                let a = 2 * Double.pi * Double(i) / Double(count)
                return Vec2(p.x + r * cos(a), p.z + r * sin(a))
            }.sorted { $0.z < $1.z }
            if let spot = ring.first(where: { canStand(at: $0, belongsIn: belongs) && accept($0) }) { return spot }
            r += step
        }
        return nil
    }

    // MARK: What hides what

    /// How much of a drawing (world points) the drawings of the stickers
    /// in front of it hide: the share of it behind any of them. A
    /// drawing's box is roomier than its outline, so each one in front
    /// counts by its box less an eighth at every side.
    public static func hidden(_ r: StageRect, behind front: [StageRect]) -> Double {
        let boxes = front.map { f -> StageRect in
            let dx = (f.maxX - f.minX) / 8, dy = (f.maxY - f.minY) / 8
            return StageRect(minX: f.minX + dx, minY: f.minY + dy, maxX: f.maxX - dx, maxY: f.maxY - dy)
        }.filter { $0.maxX > r.minX && $0.minX < r.maxX && $0.maxY > r.minY && $0.minY < r.maxY }
        guard !boxes.isEmpty, r.maxX > r.minX, r.maxY > r.minY else { return 0 }
        let n = 8
        var behind = 0
        for i in 0..<n {
            for j in 0..<n {
                let x = r.minX + (r.maxX - r.minX) * (Double(i) + 0.5) / Double(n)
                let y = r.minY + (r.maxY - r.minY) * (Double(j) + 0.5) / Double(n)
                if boxes.contains(where: { $0.minX <= x && x <= $0.maxX && $0.minY <= y && y <= $0.maxY }) { behind += 1 }
            }
        }
        return Double(behind) / Double(n * n)
    }

    /// How much of a drawing (world points) standing at depth `z` the
    /// planes in front of it hide: the share of it behind any of them.
    public func hidden(_ r: StageRect, atDepth z: Double) -> Double {
        let nearer = covers.filter { $0.depth < z - 1e-6 }
        guard !nearer.isEmpty, r.maxX > r.minX, r.maxY > r.minY else { return 0 }
        let n = 8
        var behind = 0
        for i in 0..<n {
            for j in 0..<n {
                let u = (r.minX + (r.maxX - r.minX) * (Double(i) + 0.5) / Double(n)) / max(frame.width, 1)
                let v = (r.minY + (r.maxY - r.minY) * (Double(j) + 0.5) / Double(n)) / max(frame.height, 1)
                if nearer.contains(where: { c in
                    c.grid.isOpaque(
                        atU: (u - c.area.minX) / max(c.area.maxX - c.area.minX, 1e-9),
                        v: (v - c.area.minY) / max(c.area.maxY - c.area.minY, 1e-9))
                }) {
                    behind += 1
                }
            }
        }
        return Double(behind) / Double(n * n)
    }
}

