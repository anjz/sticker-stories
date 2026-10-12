import Foundation

/// A plane of the scene between the background and the foreground — the
/// trees, the reeds at the pond (`docs/pack-format.md`, "Layers"): painted
/// on its own, so a story can put a sticker between planes at its depth
/// (`SceneSpace`). While the child edits the canvas it is drawn with the
/// background.
public struct SceneLayer: Codable, Equatable, Sendable {
    public var id: String
    public var image: String
    /// The plane on the wide art; present exactly when the pack has wide art.
    public var imageWide: String?

    public init(id: String, image: String, imageWide: String? = nil) {
        self.id = id
        self.image = image
        self.imageWide = imageWide
    }
}

/// The scene as a place with depth (`docs/pack-format.md`, "Space"): a
/// camera looking level at a ground, fitted to the art, so every point on
/// the art has a depth and every sticker a size there.
///
/// Units: x, y (height above the ground) and z (depth from the eye) are in
/// art heights at depth 1, the depth of the nearest foreground layer. A
/// sticker of size s is drawn s / z tall standing at depth z (never below
/// `floor`). Art points are fractions of the base art, origin bottom-left;
/// on the wide art they run past 0…1. The Go packager holds the same model
/// (`tools/internal/manifest/space.go`).
public struct SceneSpace: Codable, Equatable, Sendable {
    /// The art y of the eye line.
    public var horizon: Double
    /// The art y of the ground at depth 1.
    public var ground: Double
    /// The depth of the backdrop: where the ground ends.
    public var back: Double
    /// The depths stickers stand at.
    public var stand: Range
    /// The smallest height a sticker is drawn at, in art heights.
    public var floor: Double
    /// The scene's planes at their depths (a plane cut into pieces by masks).
    public var layers: [Layer]
    /// Features (the same ids) as parts of the space.
    public var places: [String: Place]
    /// Stickers' drawn heights at depth 1, in art heights.
    public var sizes: [String: Double]

    public struct Range: Codable, Equatable, Sendable {
        public var near: Double
        public var far: Double

        public init(near: Double, far: Double) {
            self.near = near
            self.far = far
        }
    }

    /// A point on the art, `[u, v]` in the file.
    public struct Point: Codable, Equatable, Sendable {
        public var u: Double
        public var v: Double

        public init(_ u: Double, _ v: Double) {
            self.u = u
            self.v = v
        }

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            u = try c.decode(Double.self)
            v = try c.decode(Double.self)
            if !c.isAtEnd {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "a point is [u, v]")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(u)
            try c.encode(v)
        }
    }

    /// A scene plane, or a piece of one, at one depth.
    public struct Layer: Codable, Equatable, Sendable {
        public var id: String
        /// The plane it shows: `foreground` (when absent) or a `SceneLayer` id.
        public var art: String?
        public var depth: Double
        /// The part of the plane that is this piece; absent on the rest of it.
        public var mask: [Point]?
        /// The ground it stands on, where nothing walks (feet positions).
        public var footprint: [Point]?
        /// The same piece on the wide art, when it is painted elsewhere there.
        public var wide: Rendition?

        public init(
            id: String, art: String? = nil, depth: Double, mask: [Point]? = nil,
            footprint: [Point]? = nil, wide: Rendition? = nil
        ) {
            self.id = id
            self.art = art
            self.depth = depth
            self.mask = mask
            self.footprint = footprint
            self.wide = wide
        }

        public static let foreground = "foreground"

        /// The scene plane it shows.
        public var plane: String { art ?? Self.foreground }
    }

    public struct Rendition: Codable, Equatable, Sendable {
        public var depth: Double
        public var mask: [Point]?
        public var footprint: [Point]?

        public init(depth: Double, mask: [Point]? = nil, footprint: [Point]? = nil) {
            self.depth = depth
            self.mask = mask
            self.footprint = footprint
        }
    }

    /// A feature in space: ground to stand on (feet positions), open air to
    /// fly in, or lines on a layer (a branch to perch on, the bark of a
    /// trunk).
    public struct Place: Codable, Equatable, Sendable {
        public var ground: [Point]?
        public var water: Bool?
        public var air: Air?
        public var lines: [Line]?
        public var wideLines: [Line]?

        public init(
            ground: [Point]? = nil, water: Bool? = nil, air: Air? = nil,
            lines: [Line]? = nil, wideLines: [Line]? = nil
        ) {
            self.ground = ground
            self.water = water
            self.air = air
            self.lines = lines
            self.wideLines = wideLines
        }
    }

    public struct Air: Codable, Equatable, Sendable {
        public var area: [Point]
        /// Near and far.
        public var depth: [Double]

        public init(area: [Point], depth: [Double]) {
            self.area = area
            self.depth = depth
        }
    }

    /// Where feet (a perch) or a front (bark) go on a layer, at its depth.
    public struct Line: Codable, Equatable, Sendable {
        public var layer: String
        public var points: [Point]
        public var facing: StageMove.Facing?

        public init(layer: String, points: [Point], facing: StageMove.Facing? = nil) {
            self.layer = layer
            self.points = points
            self.facing = facing
        }
    }

    public init(
        horizon: Double, ground: Double, back: Double, stand: Range, floor: Double = 0,
        layers: [Layer], places: [String: Place] = [:], sizes: [String: Double]
    ) {
        self.horizon = horizon
        self.ground = ground
        self.back = back
        self.stand = stand
        self.floor = floor
        self.layers = layers
        self.places = places
        self.sizes = sizes
    }

    private enum CodingKeys: String, CodingKey {
        case horizon, ground, back, stand, floor, layers, places, sizes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        horizon = try c.decode(Double.self, forKey: .horizon)
        ground = try c.decode(Double.self, forKey: .ground)
        back = try c.decode(Double.self, forKey: .back)
        stand = try c.decode(Range.self, forKey: .stand)
        floor = try c.decodeIfPresent(Double.self, forKey: .floor) ?? 0
        layers = try c.decode([Layer].self, forKey: .layers)
        places = try c.decodeIfPresent([String: Place].self, forKey: .places) ?? [:]
        sizes = try c.decode([String: Double].self, forKey: .sizes)
    }

    // MARK: The camera

    /// The eye's height above the ground.
    public var eyeHeight: Double { horizon - ground }

    /// The depth of the ground seen at art y `v` (below the horizon).
    public func groundDepth(atArtY v: Double) -> Double { eyeHeight / (horizon - v) }

    /// The art y where the ground is at depth `z`.
    public func groundArtY(atDepth z: Double) -> Double { horizon - eyeHeight / z }

    /// A sticker of size `size`'s height on the art at depth `z`: smaller
    /// further away, never below the floor (nor above its own size at depth
    /// 1 when that is smaller than the floor).
    public func drawnHeight(size: Double, atDepth z: Double) -> Double {
        max(size / z, min(floor, size))
    }

    /// How big a sticker is while the child edits the canvas: its drawing
    /// `height` (art heights) halfway between where it would be at the back
    /// and at the front of where stickers stand, and the `scales` a pinch
    /// takes it between — from its back size to its front size.
    public struct EditSize: Equatable, Sendable {
        public var height: Double
        public var scales: ClosedRange<Double>
    }

    /// A sticker's `EditSize`, or nil when the space gives it no size.
    public func editSize(of stickerID: String) -> EditSize? {
        guard let size = sizes[stickerID], size > 0 else { return nil }
        let front = drawnHeight(size: size, atDepth: stand.near)
        let back = drawnHeight(size: size, atDepth: stand.far)
        let middle = (front + back) / 2
        return EditSize(height: middle, scales: (back / middle)...(front / middle))
    }

    // MARK: Depth on the stage

    /// Whether feet at art y `v` stand on the ground (in front of the
    /// backdrop), rather than up in a tree or the sky.
    public func isGround(artY v: Double) -> Bool {
        v < horizon && groundDepth(atArtY: v) <= back + 1e-9
    }

    /// The depth of whatever stands at art point `feet`: the ground's there,
    /// or, up off the ground, the depth of the place it is at (`elevated`).
    public func depth(atFeet feet: Point, wide: Bool = false) -> Double {
        isGround(artY: feet.v) ? max(groundDepth(atArtY: feet.v), 0.05) : elevated(at: feet, wide: wide)
    }

    /// The depth of something up off the ground at art point `feet`: just
    /// in front of the layer of the nearest branch or bark it is at (a line
    /// of a place, within `reach`), else in the open air it is in (the
    /// middle of its depths), else in the first open air, else at the front
    /// of where stickers stand.
    public func elevated(at feet: Point, wide: Bool = false, reach: Double = 0.08) -> Double {
        var best: (distance: Double, depth: Double)?
        for (_, place) in places.sorted(by: { $0.key < $1.key }) {
            let lines = (wide ? place.wideLines : nil) ?? place.lines ?? []
            for line in lines {
                guard let depth = layerDepth(line.layer, wide: wide) else { continue }
                let d = Self.distance(feet, toPolyline: line.points)
                if d <= reach, d < (best?.distance ?? .infinity) { best = (d, depth - Self.inFront) }
            }
        }
        if let best { return best.depth }
        let airs = places.sorted(by: { $0.key < $1.key }).compactMap(\.value.air).filter { $0.depth.count == 2 }
        if let air = airs.first(where: { Self.contains($0.area, feet) }) ?? airs.first {
            return (air.depth[0] + air.depth[1]) / 2
        }
        return stand.near
    }

    /// The depth of the space's layer `id` on the art drawn.
    public func layerDepth(_ id: String, wide: Bool = false) -> Double? {
        layers.first { $0.id == id }.map { wide ? ($0.wide?.depth ?? $0.depth) : $0.depth }
    }

    /// The depth a scene plane is drawn at: its nearest piece's.
    public func planeDepth(_ plane: String, wide: Bool = false) -> Double? {
        layers.filter { $0.plane == plane }.map { wide ? ($0.wide?.depth ?? $0.depth) : $0.depth }.min()
    }

    /// The depth `along` the way from `a` to `b` (0…1), as the screen moves
    /// there: evenly in 1 / depth, the way a point on the ground rises up
    /// the picture.
    public static func mix(_ a: Double, _ b: Double, along k: Double) -> Double {
        1 / (1 / a + (1 / b - 1 / a) * min(max(k, 0), 1))
    }

    /// How much nearer than what it is with (or the tree it perches on) a
    /// sticker is, so it is drawn in front of it.
    public static let inFront = 0.02

    static func distance(_ p: Point, toPolyline points: [Point]) -> Double {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return hypot(p.u - first.u, p.v - first.v) }
        var best = Double.infinity
        for (a, b) in zip(points, points.dropFirst()) {
            let dx = b.u - a.u, dy = b.v - a.v
            let t = dx == 0 && dy == 0 ? 0 : min(max(((p.u - a.u) * dx + (p.v - a.v) * dy) / (dx * dx + dy * dy), 0), 1)
            best = min(best, hypot(p.u - (a.u + t * dx), p.v - (a.v + t * dy)))
        }
        return best
    }

    static func contains(_ polygon: [Point], _ p: Point) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.v > p.v) != (b.v > p.v), p.u < (b.u - a.u) * (p.v - a.v) / (b.v - a.v) + a.u { inside.toggle() }
            j = i
        }
        return inside
    }

    // MARK: Validation (rule 20)

    /// Every problem with the space. `planes` are the pack's scene layer
    /// ids, `stickers` its sticker ids and `features` its feature ids.
    public func issues(planes: Set<String>, stickers: Set<String>, features: Set<String>) -> [String] {
        var issues: [String] = []
        func fail(_ message: String) { issues.append("space: " + message) }
        if !(horizon > 0 && horizon < 1) { fail("horizon \(horizon) must be inside the art (0…1)") }
        if self.ground >= horizon { fail("ground \(self.ground) must be below the horizon \(horizon)") }
        if !(stand.near > 0 && stand.far > stand.near) { fail("stand \(stand.near)…\(stand.far) needs 0 < near < far") }
        if back < stand.far { fail("back \(back) must be at least stand.far \(stand.far)") }
        if !(floor >= 0 && floor < 1) { fail("floor \(floor) must be a fraction of the art's height (0 up to 1)") }

        func inArt(_ field: String, _ points: [Point], least: Int) -> Bool {
            if points.count < least {
                fail("\(field) needs at least \(least) points")
                return false
            }
            if let p = points.first(where: { !(-0.5...1.5).contains($0.u) || !(0...1).contains($0.v) }) {
                fail("\(field): point [\(p.u), \(p.v)] must be within x −0.5…1.5, y 0…1")
                return false
            }
            return true
        }
        func onGround(_ field: String, _ points: [Point]) {
            guard inArt(field, points, least: 3) else { return }
            if let p = points.first(where: { $0.v >= horizon }) {
                fail("\(field): point [\(p.u), \(p.v)] is not below the horizon (feet are on the ground)")
            } else if horizon > self.ground, let p = points.first(where: { groundDepth(atArtY: $0.v) > back }) {
                fail("\(field): point [\(p.u), \(p.v)] is past the backdrop (\(back))")
            }
        }
        func depth(_ field: String, _ z: Double) {
            if !(z > 0 && z <= back) { fail("\(field): depth \(z) must be in (0, back]") }
        }

        var layerIDs = Set<String>()
        var rest: [String: Int] = [:]
        var shown = Set<String>()
        for (index, layer) in layers.enumerated() {
            let field = "layers[\(index)] \"\(layer.id)\""
            if !PackManifest.isWellFormedID(layer.id) || !layerIDs.insert(layer.id).inserted {
                fail("\(field): needs a unique lowercase a-z0-9 id")
            }
            if layer.plane != Layer.foreground && !planes.contains(layer.plane) {
                fail("\(field): art \"\(layer.plane)\" is not one of the pack's layers")
            }
            shown.insert(layer.plane)
            depth(field, layer.depth)
            if let mask = layer.mask {
                _ = inArt(field + " mask", mask, least: 3)
            } else {
                rest[layer.plane, default: 0] += 1
                if layer.wide?.mask != nil { fail("\(field): the rest of a plane has no mask, wide or not") }
            }
            if let footprint = layer.footprint { onGround(field + " footprint", footprint) }
            if let wide = layer.wide {
                depth(field + " wide", wide.depth)
                if layer.mask != nil, let mask = wide.mask { _ = inArt(field + " wide mask", mask, least: 3) }
                if let footprint = wide.footprint { onGround(field + " wide footprint", footprint) }
            }
        }
        for (plane, count) in rest.sorted(by: { $0.key < $1.key }) where count > 1 {
            fail("layers: \(count) layers show all of \(plane); cut it with masks, one may be the rest")
        }
        for plane in planes.sorted() + [Layer.foreground] where !shown.contains(plane) {
            fail("layers: nothing puts \(plane) at a depth")
        }

        for (id, place) in places.sorted(by: { $0.key < $1.key }) {
            let field = "places.\(id)"
            if !features.contains(id) { fail("\(field): not a feature of the pack") }
            var kinds = 0
            if let points = place.ground {
                kinds += 1
                onGround(field + " ground", points)
            } else if place.water == true {
                fail("\(field): water needs ground")
            }
            if let air = place.air {
                kinds += 1
                _ = inArt(field + " air area", air.area, least: 3)
                if air.depth.count != 2 || !(air.depth[0] > 0 && air.depth[1] >= air.depth[0] && air.depth[1] <= back) {
                    fail("\(field) air: depth \(air.depth) must be near…far within (0, back]")
                }
            }
            if place.lines != nil {
                kinds += 1
            } else if place.wideLines != nil {
                fail("\(field): wideLines need lines")
            }
            for line in (place.lines ?? []) + (place.wideLines ?? []) {
                if !layerIDs.contains(line.layer) {
                    fail("\(field): a line on \"\(line.layer)\", which is not one of the space's layers")
                }
                _ = inArt(field + " line", line.points, least: 2)
            }
            if kinds != 1 { fail("\(field): needs exactly one of ground, air or lines") }
        }

        for (id, size) in sizes.sorted(by: { $0.key < $1.key }) {
            if !stickers.contains(id) { fail("sizes.\(id): not a sticker of the pack") }
            if !(size > 0 && size <= 5) { fail("sizes.\(id): \(size) must be above 0 and at most 5") }
        }
        for id in stickers.sorted() where sizes[id] == nil {
            fail("sizes: sticker \"\(id)\" has no size")
        }
        return issues
    }
}
