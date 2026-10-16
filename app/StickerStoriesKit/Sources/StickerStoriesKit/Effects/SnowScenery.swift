import CoreGraphics

/// A plane of 8-bit values over an image, row 0 at the top (the way a
/// bitmap's rows run).
public struct BytePlane: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var values: [UInt8]

    public init(width: Int, height: Int, values: [UInt8]) {
        self.width = width
        self.height = height
        self.values = values
    }

    public subscript(x: Int, y: Int) -> UInt8 { values[y * width + x] }

    /// The value at fractions of the plane (`fx` from the left, `fy` from
    /// the top), nearest pixel, 0 outside.
    public func sample(_ fx: Double, _ fy: Double) -> UInt8 {
        let x = Int(fx * Double(width)), y = Int(fy * Double(height))
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return values[y * width + x]
    }

    /// The plane with every value passed through `transform`.
    public func mapped(_ transform: (UInt8) -> UInt8) -> BytePlane {
        BytePlane(width: width, height: height, values: values.map(transform))
    }

    /// White with the plane as its alpha: a mask's image (`SKCropNode`).
    public func maskImage() -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for (i, a) in values.enumerated() {  // premultiplied white is the alpha itself
            rgba[i * 4] = a
            rgba[i * 4 + 1] = a
            rgba[i * 4 + 2] = a
            rgba[i * 4 + 3] = a
        }
        let data = rgba.withUnsafeBufferPointer { CFDataCreate(nil, $0.baseAddress, $0.count) }
        guard let data, let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// An image's alpha, drawn at `width` × `height`.
    public static func alpha(of image: CGImage, width: Int, height: Int) -> BytePlane? {
        guard width > 0, height > 0 else { return nil }
        var values = [UInt8](repeating: 0, count: width * height)
        let drawn = values.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? BytePlane(width: width, height: height, values: values) : nil
    }
}

/// Where snow settles on the scene (`docs/effects.md`, `snow`), worked out
/// once per pack when its art loads. Each result is a **snow field**: an
/// opaque RGB image whose red is how early a pixel takes snow (255 first,
/// 1 last, 0 never), green how white it gets, and blue how much of the
/// cool shade it takes. A cover from 0 to 1 shows every pixel whose
/// earliness is above `1 - cover`, so the snow is a pure function of the
/// cover (`CanvasEffectsRunner.snowCover`) — seeks stay right — and it
/// grows patchily, the tops of things first, then fills in.
public enum SnowScenery {
    /// Snow fields are row by row from the top, 4 bytes a pixel (red,
    /// green, blue, 255).
    public struct Field: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var pixels: [UInt8]

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
            pixels = [UInt8](repeating: 0, count: width * height * 4)
            for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        }

        /// How early (0...1, 0 never) the pixel at (`x`, `y` from the top)
        /// takes snow.
        public func earliness(_ x: Int, _ y: Int) -> Double { Double(pixels[(y * width + x) * 4]) / 255 }
        public func opacity(_ x: Int, _ y: Int) -> Double { Double(pixels[(y * width + x) * 4 + 1]) / 255 }

        /// Keeps the snowier of what is there and (earliness, opacity, shade).
        mutating func put(_ x: Int, _ y: Int, earliness: Double, opacity: Double, shade: Double) {
            let i = (y * width + x) * 4
            let e = UInt8((min(max(earliness, 0), 1) * 255).rounded())
            guard e > pixels[i] else { return }
            pixels[i] = e
            pixels[i + 1] = UInt8((min(max(opacity, 0), 1) * 255).rounded())
            pixels[i + 2] = UInt8((min(max(shade, 0), 1) * 255).rounded())
        }

        /// The field as an image (for a texture).
        public func image() -> CGImage? {
            let data = pixels.withUnsafeBufferPointer { CFDataCreate(nil, $0.baseAddress, $0.count) }
            guard let data, let provider = CGDataProvider(data: data) else { return nil }
            return CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    /// A cap's thickness, in art heights: a few points on any screen.
    public static let capThickness = 0.009

    /// The snow cap along the upward-facing edges of a plane with alpha (a
    /// scene layer, the foreground): every opaque pixel with open air
    /// above it, and the few below it, following the shape; on a slope it
    /// thins as the slope steepens (the thickness is vertical), and none
    /// sits on a sheer side. Bumpy along its length, and patchy as it
    /// first settles. `thickness` is in the plane's pixels. A shape cut by
    /// the plane's top edge (a trunk running out of the picture) gets none
    /// there.
    public static func caps(of alpha: BytePlane, thickness: Double, seed: UInt64 = 0xCA95) -> Field {
        var field = Field(width: alpha.width, height: alpha.height)
        guard thickness > 0 else { return field }
        let opaque = { (x: Int, y: Int) in alpha[x, y] >= 128 }
        for x in 0..<alpha.width {
            let fx = Double(x) / thickness
            let depth = thickness * (0.6 + 0.4 * noise(fx / 3, 0.5, seed: seed))
            let patch = 0.5 + 0.5 * noise(fx / 7, 3.5, seed: seed &+ 1)
            var below = Int.max  // pixels below the last open air
            for y in 0..<alpha.height {
                guard opaque(x, y) else {
                    below = .max
                    continue
                }
                if below == .max {
                    // Open air above (two pixels: not a seam in the paint).
                    if y >= 2, !opaque(x, y - 1), !opaque(x, y - 2) { below = 0 }
                } else {
                    below += 1
                }
                guard below != .max, Double(below) < depth else { continue }
                let d = Double(below) / depth
                field.put(
                    x, y, earliness: (1 - 0.7 * d) * patch, opacity: 0.96 * min(1, (1 - d) * 3),
                    shade: 0.15 + 0.6 * d)
            }
        }
        return field
    }

    /// One flake lying in the snow: where (fractions of the art frame,
    /// origin bottom-left), how big (a fraction of the frame's height) and
    /// the cover it appears at.
    public struct Flake: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var size: Double
        public var threshold: Double
    }

    /// The snow on the ground of a background: the whole ground seen in
    /// it, up to its far edge, in perspective — its patches and flakes
    /// smaller and closer together towards the horizon, the far snow a
    /// little thinner and bluer — never on water, never in the sky; and a
    /// cap along the top of the painted scenery wherever it meets the sky
    /// (the treeline, a ridge).
    ///
    /// - Parameters:
    ///   - width, height: the field's size; it covers the art frame.
    ///   - frame: the art frame's left edge and width, in fractions of the
    ///     base art (the wide art runs past 0…1).
    ///   - aspect: the base art's width over its height.
    ///   - space: the scene's space; without one the ground is all that is
    ///     not sky, its horizon the lowest point of the sky.
    ///   - sky: the background's sky mask (alpha, 255 sky), any size.
    public static func ground(
        width: Int, height: Int, frame: (minX: Double, width: Double), aspect: Double,
        space: SceneSpace?, sky: BytePlane?, seed: UInt64 = 0x5E77
    ) -> (field: Field, flakes: [Flake]) {
        var field = Field(width: width, height: height)
        guard width > 0, height > 0 else { return (field, []) }
        let geometry = Geometry(space: space, sky: sky)
        // A cap on the scenery where it meets the sky, column by column.
        let cap = capThickness * Double(height)
        for x in 0..<width {
            let fx = (Double(x) + 0.5) / Double(width)
            let depth = cap * (0.6 + 0.4 * noise(Double(x) / cap / 3, 7.5, seed: seed))
            var below = Int.max
            var underSky = false
            for y in 0..<height {
                let fy = (Double(y) + 0.5) / Double(height)
                if geometry.isSky(fx, fy) {
                    below = .max
                    underSky = true
                    continue
                }
                if underSky {
                    below = 0
                } else if below != .max {
                    below += 1
                }
                underSky = false
                guard below != .max, Double(below) < depth else { continue }
                let d = Double(below) / depth
                field.put(x, y, earliness: 0.9 * (1 - 0.6 * d), opacity: 0.9 * min(1, (1 - d) * 3), shade: 0.2 + 0.5 * d)
            }
        }
        // The ground.
        for y in 0..<height {
            let v = 1 - (Double(y) + 0.5) / Double(height)
            guard let z = geometry.depth(atArtY: v) else { continue }
            let far = geometry.farEdge.map { min(1, max(0, ($0 - v) / 0.02)) } ?? 1
            let distance = min(1, (z - 1) / max(geometry.farDepth - 1, 1e-6))
            for x in 0..<width {
                let u = frame.minX + frame.width * (Double(x) + 0.5) / Double(width)
                guard !geometry.isSky((Double(x) + 0.5) / Double(width), 1 - v), !geometry.isWater(u, v) else { continue }
                // Patches laid on the ground itself, so they shrink with distance.
                let gx = (u - 0.5) * aspect * z, gz = z
                let n =
                    0.55 * noise(gx * 3.2, gz * 3.2, seed: seed &+ 2) + 0.3 * noise(gx * 8, gz * 8, seed: seed &+ 3)
                    + 0.15 * noise(gx * 20, gz * 20, seed: seed &+ 4)
                // A little of the grass shows through even a full cover.
                let thin = 0.82 + 0.18 * noise(gx * 14, gz * 14, seed: seed &+ 5)
                field.put(
                    x, y, earliness: 0.12 + 0.86 * n, opacity: (0.95 - 0.12 * distance) * thin * max(far, 0.3),
                    shade: 0.08 + 0.3 * distance)
            }
        }
        // Flakes strewn evenly over the ground in depth: on the screen they
        // crowd and shrink towards the horizon.
        var flakes: [Flake] = []
        var random = seed
        for _ in 0..<900 where flakes.count < 300 {
            let z = 1 + (geometry.farDepth - 1) * unit(&random)
            let v = geometry.horizon - geometry.eye / z
            let fx = unit(&random)
            let u = frame.minX + frame.width * fx
            guard v >= 0, geometry.depth(atArtY: v) != nil, !geometry.isSky(fx, 1 - v), !geometry.isWater(u, v) else {
                continue
            }
            flakes.append(Flake(x: fx, y: v, size: 0.03 / z.squareRoot() * (0.6 + 0.4 * unit(&random)), threshold: 0.03 + 0.9 * unit(&random)))
        }
        return (field, flakes)
    }

    /// The ground's shape on the art.
    struct Geometry {
        let space: SceneSpace?
        let sky: BytePlane?
        /// The eye line and the eye's height over the ground, in art heights.
        let horizon: Double
        let eye: Double
        /// Art y of the ground's far edge, with a space.
        let farEdge: Double?
        /// The depth the ground runs to.
        let farDepth: Double
        let water: [GroundPolygon]

        init(space: SceneSpace?, sky: BytePlane?) {
            self.space = space
            self.sky = sky
            if let space {
                horizon = space.horizon
                eye = space.eyeHeight
                farEdge = space.groundArtY(atDepth: space.back)
                farDepth = space.back
                water = space.places.values.compactMap { place in
                    guard place.water == true, let ground = place.ground else { return nil }
                    return GroundPolygon(ground.map { Vec2($0.u, $0.v) })
                }
            } else {
                // The sky's lowest point stands in for the horizon; with
                // no sky mask either, the middle of the picture
                // (docs/pack-format.md, "Art safe area").
                var lowest = sky == nil ? 0.5 : 1.0
                if let sky {
                    for y in stride(from: sky.height - 1, through: 0, by: -1) {
                        if (0..<sky.width).contains(where: { sky[$0, y] >= 128 }) {
                            lowest = 1 - Double(y + 1) / Double(sky.height)
                            break
                        }
                    }
                }
                horizon = max(lowest, 0.05)
                eye = horizon
                farEdge = nil
                farDepth = 12
                water = []
            }
        }

        /// Fractions of the art frame, `fy` from the top.
        func isSky(_ fx: Double, _ fy: Double) -> Bool { (sky?.sample(fx, fy) ?? 0) >= 128 }

        func isWater(_ u: Double, _ v: Double) -> Bool { water.contains { $0.contains(Vec2(u, v)) } }

        /// The depth of the ground seen at art y `v`, or nil where there is
        /// no ground (past its far edge).
        func depth(atArtY v: Double) -> Double? {
            if let farEdge, v > farEdge { return nil }
            guard v < horizon else { return nil }
            return min(max(eye / (horizon - v), 1), farDepth)
        }
    }

    /// Smooth value noise, 0...1.
    static func noise(_ x: Double, _ y: Double, seed: UInt64) -> Double {
        let x0 = x.rounded(.down), y0 = y.rounded(.down)
        let tx = x - x0, ty = y - y0
        let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
        func lattice(_ i: Double, _ j: Double) -> Double {
            var h = seed &+ UInt64(bitPattern: Int64(i)) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(bitPattern: Int64(j)) &* 0xC2B2_AE3D_27D4_EB4F
            return unit(&h)
        }
        let a = lattice(x0, y0), b = lattice(x0 + 1, y0), c = lattice(x0, y0 + 1), d = lattice(x0 + 1, y0 + 1)
        return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy
    }

    /// A double in 0..<1 from a SplitMix64 state, advanced.
    static func unit(_ state: inout UInt64) -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }
}
