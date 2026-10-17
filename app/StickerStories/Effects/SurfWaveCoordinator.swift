import CoreImage
import SpriteKit
import StickerStoriesKit

/// Draws `surf-wave` (`docs/effects.md`): for every running one on a
/// sticker that was in the water when it was cued, a wave behind it at its
/// waterline (the stage sinks a floating sticker so that its waterline is
/// where its feet were, `StickerNode.float`), with a low foam line in front
/// of its base. The shape is the Kit's (`SurfWave`), a pure function of the
/// timeline, so a seek or a replay shows the same wave; this only paints it,
/// every frame, from the runner's active effects.
///
/// The wave is drawn in the sticker's layer, in world space, just behind
/// the sticker in z (the foam line just in front): it follows the sticker's
/// placement — where it is and its size at its depth — but never its
/// rotation, its puppet's poses or a flip, so it stays level with the sea
/// while the surfer tilts. It always rolls left to right, like the painted
/// waves, so the sticker rides ahead of the break on its right.
@MainActor
final class SurfWaveCoordinator {
    /// Whether a sticker is in the water at a time: asked once per wave, at
    /// the time it is cued. Without an answer no wave rises.
    var inWater: (StickerNode, TimeInterval) -> Bool = { _, _ in false }

    private var waves: [EffectHandle: SurfWaveNode] = [:]
    /// Cued on a sticker on land: nothing is drawn for them.
    private var dry: Set<EffectHandle> = []

    func reconcile(_ active: [ActiveEffect], at time: TimeInterval, nodes: [UUID: StickerNode]) {
        var shown = Set<EffectHandle>()
        for effect in active where effect.name == .surfWave && !dry.contains(effect.handle) {
            guard let node = nodes[effect.target], let layer = node.parent,
                let frame = SurfWave.frame(of: effect, at: time)
            else { continue }
            if waves[effect.handle] == nil, !inWater(node, effect.startTime) {
                dry.insert(effect.handle)
                continue
            }
            shown.insert(effect.handle)
            let wave = waves[effect.handle] ?? SurfWaveNode()
            if wave.parent !== layer {
                wave.removeFromParent()
                layer.addChild(wave)
            }
            waves[effect.handle] = wave
            wave.show(frame, for: node)
        }
        for (handle, wave) in waves where !shown.contains(handle) {
            wave.removeFromParent()
            waves[handle] = nil
        }
        dry = dry.intersection(Set(active.map(\.handle)))
    }

    /// Takes every wave away at once (playback over — P4).
    func clearAll() {
        for wave in waves.values { wave.removeFromParent() }
        waves.removeAll()
        dry.removeAll()
    }
}

/// One wave on a sticker: the water, its painted streaks, the light in its
/// lip and the deeper water in its curl, the foam and the spray behind the
/// sticker's art; the foam line in front of it. Everything but the water's
/// outline is soft rounds (the `foam` texture), so nothing has a hard edge.
@MainActor
final class SurfWaveNode: SKNode {
    /// Relative to the sticker's z: behind its art and its glow (-0.5), in
    /// front of its shadows (-1); the foam line over the art, a puppet
    /// (0.5) and the near half of its ripples (0.55).
    static let behindZ: CGFloat = -0.7
    static let frontZ: CGFloat = 0.62

    private let behind = SKNode()
    private let front = SKNode()
    private let body = SKShapeNode()
    /// Softens the water's outline against the sky and the sea, like a
    /// wet watercolour edge (the foam over it stays crisp and puffy).
    private let soft = SKEffectNode()
    private var streaks: [SKSpriteNode] = []
    private var glow: [SKSpriteNode] = []
    private var shade: [SKSpriteNode] = []
    private var foam: [SKSpriteNode] = []
    private var spray: [SKSpriteNode] = []
    private var frontFoam: [SKSpriteNode] = []

    // The Beach scene's painted sea: a teal-blue body, more turquoise
    // towards the crest, melting into the water at its foot; white foam.
    private static let streakColor = UIColor(red: 0.95, green: 1, blue: 1, alpha: 1)
    private static let glowColor = UIColor(red: 0.62, green: 0.93, blue: 0.90, alpha: 1)
    private static let shadeColor = UIColor(red: 0.04, green: 0.36, blue: 0.56, alpha: 1)
    private static let sprayColor = UIColor(red: 0.90, green: 0.97, blue: 1, alpha: 1)

    override init() {
        super.init()
        behind.zPosition = Self.behindZ
        front.zPosition = Self.frontZ
        addChild(behind)
        addChild(front)
        body.fillTexture = Self.bodyTexture
        body.fillColor = .white
        body.strokeColor = .clear
        body.lineWidth = 0
        soft.filter = CIFilter(name: "CIGaussianBlur")
        soft.shouldEnableEffects = true
        soft.addChild(body)
        behind.addChild(soft)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Paints `frame` at `node`'s waterline, in its layer's space, rolling
    /// left to right. Only the sticker's placement counts (where the story
    /// has it and its size at its depth, `effectBase`): not its rotation,
    /// effects, puppet poses or flip.
    func show(_ frame: SurfWave.Frame, for node: StickerNode) {
        let base = node.effectBase ?? node.placement
        let scale = CGFloat(base.scale)
        let unit = node.unscaledSize, c = node.content
        let width = c.width * unit.width * scale, height = c.height * unit.height * scale
        guard height > 0 else { return }
        let shape = SurfWave.shape(frame, aspect: Double(width / height))
        zPosition = node.zPosition
        alpha = CGFloat(shape.opacity) * node.alpha
        isHidden = shape.body.isEmpty && shape.foam.isEmpty && shape.frontFoam.isEmpty
        // Its waterline: its drawing's feet, where the stage has it.
        let mirror: CGFloat = node.facing < 0 ? -1 : 1
        position = CGPoint(
            x: CGFloat(base.x) + (c.midX - 0.5) * unit.width * scale * mirror,
            y: CGFloat(base.y) + (c.minY - 0.5) * unit.height * scale)
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: CGFloat(x) * height, y: CGFloat(y) * height)
        }

        let water = CGFloat(shape.bodyOpacity)
        body.path = Self.path(shape.body.map { point($0.x, $0.y) }, closed: true)
        body.alpha = water
        // A blur of a few points, in proportion to the wave on screen.
        soft.filter?.setValue(max(1.5, 0.025 * height), forKey: kCIInputRadiusKey)
        place(shape.streaks, in: &streaks, on: behind, z: 0.01, color: Self.streakColor, fade: water, point: point, height: height)
        place(shape.glow, in: &glow, on: behind, z: 0.015, color: Self.glowColor, fade: water, point: point, height: height)
        place(shape.shade, in: &shade, on: behind, z: 0.02, color: Self.shadeColor, fade: water, point: point, height: height)
        place(shape.foam, in: &foam, on: behind, z: 0.03, color: .white, point: point, height: height)
        place(shape.spray, in: &spray, on: behind, z: 0.04, color: Self.sprayColor, point: point, height: height)
        place(shape.frontFoam, in: &frontFoam, on: front, z: 0, color: .white, point: point, height: height)
    }

    /// Shows `blobs` with the sprites of `pool`, making more as needed and
    /// hiding the rest.
    private func place(
        _ blobs: [SurfWave.Blob], in pool: inout [SKSpriteNode], on parent: SKNode, z: CGFloat, color: UIColor,
        fade: CGFloat = 1, point: (Double, Double) -> CGPoint, height: CGFloat
    ) {
        while pool.count < blobs.count {
            let sprite = SKSpriteNode(texture: EffectTextures.texture(named: "foam"))
            sprite.color = color
            sprite.colorBlendFactor = 1
            sprite.zPosition = z
            parent.addChild(sprite)
            pool.append(sprite)
        }
        for (index, sprite) in pool.enumerated() {
            guard index < blobs.count else {
                sprite.isHidden = true
                continue
            }
            let blob = blobs[index]
            sprite.isHidden = false
            sprite.position = point(blob.x, blob.y)
            let d = CGFloat(blob.radius * 2) * height
            sprite.size = CGSize(width: d * CGFloat(blob.stretch), height: d)
            sprite.alpha = CGFloat(blob.alpha) * fade
        }
    }

    private static func path(_ points: [CGPoint], closed: Bool) -> CGPath? {
        guard points.count > 1 else { return nil }
        let path = CGMutablePath()
        path.addLines(between: points)
        if closed { path.closeSubpath() }
        return path
    }

    /// The water's colour from its foot (bottom, translucent so it melts
    /// into the sea) to its crest (top, a light turquoise): one smooth
    /// blend, eased between its stops and finely dithered so no step
    /// shows. An `SKShapeNode` stretches its fill texture over the shape's
    /// frame. Fixed: drawn once.
    private static let bodyTexture: SKTexture = {
        let width = 8, height = 512
        let stops: [(Double, [Double])] = [
            (0, [0.56, 0.91, 0.89, 1]), (0.45, [0.14, 0.71, 0.80, 1]), (0.8, [0.07, 0.53, 0.73, 0.92]),
            (1, [0.07, 0.50, 0.72, 0]),
        ]
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let v = (Double(y) + 0.5) / Double(height)  // 0 at the top (the crest)
            var c = stops[stops.count - 1].1
            for k in 1..<stops.count where v <= stops[k].0 {
                let (v0, a) = stops[k - 1], (v1, b) = stops[k]
                let f = SurfWave.smooth(0, 1, (v - v0) / (v1 - v0))
                c = zip(a, b).map { $0 + ($1 - $0) * f }
                break
            }
            for x in 0..<width {
                let dither = (SurfWave.random(x, y) - 0.5) / 255
                let i = (y * width + x) * 4
                let alpha = c[3]
                for channel in 0..<3 {
                    bytes[i + channel] = UInt8((min(max(c[channel] + dither, 0), 1) * alpha * 255).rounded())
                }
                bytes[i + 3] = UInt8((alpha * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return SKTexture() }
        return SKTexture(cgImage: image)
    }()
}
