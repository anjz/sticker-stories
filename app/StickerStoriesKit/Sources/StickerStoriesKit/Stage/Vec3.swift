import Foundation

/// A point or a direction in the scene's space (`SceneSpace`): `x` across,
/// `y` up from the ground, `z` the depth from the eye, in art heights at
/// depth 1.
public struct Vec3: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, k: Double) -> Vec3 { Vec3(a.x * k, a.y * k, a.z * k) }

    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    /// The point on the ground under it, and its place on the ground plane.
    public var ground: Vec2 { Vec2(x, z) }

    public func lerp(to b: Vec3, _ k: Double) -> Vec3 { self + (b - self) * k }
}

/// A point on the ground plane: `x` across, `z` the depth.
public struct Vec2: Equatable, Hashable, Sendable {
    public var x: Double
    public var z: Double

    public init(_ x: Double, _ z: Double) {
        self.x = x
        self.z = z
    }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.z + b.z) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.z - b.z) }
    public static func * (a: Vec2, k: Double) -> Vec2 { Vec2(a.x * k, a.z * k) }

    public var length: Double { (x * x + z * z).squareRoot() }
    public func distance(to b: Vec2) -> Double { (self - b).length }
    /// On the ground (height 0).
    public var onGround: Vec3 { Vec3(x, 0, z) }
}

/// A polygon on the ground plane.
public struct GroundPolygon: Equatable, Sendable {
    public var points: [Vec2]

    public init(_ points: [Vec2]) {
        self.points = points
    }

    public func contains(_ p: Vec2) -> Bool {
        var inside = false
        var j = points.count - 1
        for i in points.indices {
            let a = points[i], b = points[j]
            if (a.z > p.z) != (b.z > p.z), p.x < (b.x - a.x) * (p.z - a.z) / (b.z - a.z) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Whether the straight way from `p` to `q` goes into the polygon:
    /// through one of its edges, or lying in it. Exact, so it catches a
    /// sharp corner thinner than any sampling step; only touching an edge
    /// does not count.
    public func crosses(from p: Vec2, to q: Vec2) -> Bool {
        if cutsEdge(from: p, to: q) { return true }
        let middle = p + (q - p) * 0.5
        return contains(middle) && distance(to: middle) > 1e-9
    }

    /// Whether the straight way from `p` to `q` goes through one of its
    /// edges (in or out); only touching one does not count.
    public func cutsEdge(from p: Vec2, to q: Vec2) -> Bool {
        func side(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double { (b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x) }
        let eps = 1e-9
        for (i, a) in points.enumerated() {
            let b = points[(i + 1) % points.count]
            let d1 = side(p, q, a), d2 = side(p, q, b), d3 = side(a, b, p), d4 = side(a, b, q)
            if ((d1 > eps && d2 < -eps) || (d1 < -eps && d2 > eps)) && ((d3 > eps && d4 < -eps) || (d3 < -eps && d4 > eps)) {
                return true
            }
        }
        return false
    }

    /// How far `p` is from the polygon's edge.
    public func distance(to p: Vec2) -> Double {
        var best = Double.infinity
        for (i, a) in points.enumerated() {
            let b = points[(i + 1) % points.count]
            let d = b - a
            let t = d.length == 0 ? 0 : min(max(((p.x - a.x) * d.x + (p.z - a.z) * d.z) / (d.x * d.x + d.z * d.z), 0), 1)
            best = min(best, (a + d * t).distance(to: p))
        }
        return best
    }

    public var bounds: (min: Vec2, max: Vec2) {
        let xs = points.map(\.x), zs = points.map(\.z)
        return (Vec2(xs.min() ?? 0, zs.min() ?? 0), Vec2(xs.max() ?? 0, zs.max() ?? 0))
    }
}
